/// Phase 8 tests — HTTP middleware composition.
///
/// Tests verify that middleware wraps handlers correctly: CORS headers are
/// added, Content-Type is inferred, and auth checks reject unauthorized
/// requests.

use io {IO}
use http::types {Request, Response}
use lib::middleware {}
use http::strings {}

// ── test infrastructure ─────────────────────────────────────────────────

/// Build a GET request with optional Authorization header.
def mk_req (path : String) (auth : Option String) : Request :=
  let hs := match auth {
    Option.none => Headers.empty,
    Option.some cred => Headers.set "Authorization" cred Headers.empty
  } in
  { method := Method.GET, uri := Uri.uri "" Option.none "" Option.none path Option.none Option.none, headers := hs, version := HttpVersion.http1_1, body := Body.empty }

/// Handler that returns 200 "ok".
def ok_handler (_ : Request) : IO Response :=
  return (Response.ok_text "ok")

/// Check status + body.
def resp_ok (res : Response) (want_status : U16) (want_body : String) : Bool :=
  Bool.and (U16.beq res.status want_status) (String.beq (String.from_list (Body.to_bytes_pure res.body)) want_body)

/// Check that a header exists with the expected value.
def has_header (res : Response) (key : String) (want : String) : Bool :=
  match Headers.get key res.headers {
    Option.some v => String.beq v want,
    Option.none => false
  }

// ── tests ──────────────────────────────────────────────────────────────

/// CORS middleware adds Access-Control-Allow-Origin: *.
#[test]
def test_middleware_cors : IO Bool := do {
  let res <- Middleware.cors ok_handler (mk_req "/test" Option.none);
  return (Bool.and (resp_ok res Status.ok "ok") (has_header res "Access-Control-Allow-Origin" "*"))
}

/// Content-Type middleware infers text/plain for text body.
#[test]
def test_middleware_content_type : IO Bool := do {
  let res <- Middleware.content_type ok_handler (mk_req "/test" Option.none);
  return (Bool.and (resp_ok res Status.ok "ok") (has_header res "Content-Type" "text/plain; charset=utf-8"))
}

/// Recover middleware is a no-op (passes through to handler).
#[test]
def test_middleware_recover : IO Bool := do {
  let res <- Middleware.recover ok_handler (mk_req "/test" Option.none);
  return (resp_ok res Status.ok "ok")
}

/// Auth basic: missing Authorization header → 401.
#[test]
def test_middleware_auth_basic_missing : IO Bool := do {
  let res <- Middleware.auth_basic (fn _ => true) ok_handler (mk_req "/test" Option.none);
  return (resp_ok res Status.unauthorized "Unauthorized")
}

/// Auth basic: valid credential → 200. The header is base64 (RFC 7617);
/// `YWRtaW46c2VjcmV0` is "admin:secret", so this also pins that the
/// predicate sees the DECODED text and not the encoded form.
#[test]
def test_middleware_auth_basic_valid : IO Bool := do {
  let res <- Middleware.auth_basic (fn cred => String.beq cred "admin:secret") ok_handler (mk_req "/test" (Option.some "Basic YWRtaW46c2VjcmV0"));
  return (resp_ok res Status.ok "ok")
}

/// Auth basic: a credential that decodes, but not to the expected one → 403.
/// `d3Jvbmc6d3Jvbmc=` is "wrong:wrong" (the `=` also exercises padding).
#[test]
def test_middleware_auth_basic_invalid : IO Bool := do {
  let res <- Middleware.auth_basic (fn cred => String.beq cred "admin:secret") ok_handler (mk_req "/test" (Option.some "Basic d3Jvbmc6d3Jvbmc="));
  return (resp_ok res Status.forbidden "Forbidden")
}

/// Auth basic: a credential that is not valid base64 at all → 401, never
/// the predicate (which must not be shown text no encoder could produce).
#[test]
def test_middleware_auth_basic_malformed : IO Bool := do {
  let res <- Middleware.auth_basic (fn _ => true) ok_handler (mk_req "/test" (Option.some "Basic admin:secret"));
  return (resp_ok res Status.unauthorized "Unauthorized")
}

/// Auth bearer: missing Authorization header → 401.
#[test]
def test_middleware_auth_bearer_missing : IO Bool := do {
  let res <- Middleware.auth_bearer (fn _ => true) ok_handler (mk_req "/test" Option.none);
  return (resp_ok res Status.unauthorized "Unauthorized")
}

/// Auth bearer: valid token → 200.
#[test]
def test_middleware_auth_bearer_valid : IO Bool := do {
  let res <- Middleware.auth_bearer (fn tok => String.beq tok "abc123") ok_handler (mk_req "/test" (Option.some "Bearer abc123"));
  return (resp_ok res Status.ok "ok")
}

/// Auth bearer: invalid token → 401.
#[test]
def test_middleware_auth_bearer_invalid : IO Bool := do {
  let res <- Middleware.auth_bearer (fn tok => String.beq tok "abc123") ok_handler (mk_req "/test" (Option.some "Bearer wrong"));
  return (resp_ok res Status.unauthorized "Unauthorized")
}

/// Composition: CORS wrapping content_type wrapping handler.
#[test]
def test_middleware_compose_cors_content_type : IO Bool := do {
  let wrapped := Middleware.cors (Middleware.content_type ok_handler);
  let res <- wrapped (mk_req "/test" Option.none);
  return (Bool.and
    (resp_ok res Status.ok "ok")
    (Bool.and (has_header res "Access-Control-Allow-Origin" "*") (has_header res "Content-Type" "text/plain; charset=utf-8")))
}
