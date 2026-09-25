/// Phase 1 tests for the `http` mote core types.

use lib::types {BEq, Headers, Request, Response, Show, Uri}

#[test]
def test_request_get_fields : Bool :=
  let u : Uri := Uri.uri "https" Option.none "example.com" Option.none "/" Option.none Option.none in
  let r : Request := Request.get u in
  match r {
    { method, uri, headers, version, body, .. } =>
      method == Method.GET
        && Uri.host uri == "example.com"
        && Headers.is_empty headers
        && version == HttpVersion.http1_1
        && Body.is_empty body
  }

#[test]
def test_response_ok_text : Bool :=
  let r : Response := Response.ok_text "hi" in
  match r {
    { status, headers, version, body } =>
      status == Status.ok
        && Headers.is_empty headers
        && version == HttpVersion.http1_1
        && Body.is_text body "hi"
  }

#[test]
def test_method_eq : Bool :=
  Method.GET == Method.GET
    && Bool.not (Method.GET == Method.POST)
    && Method.POST == Method.POST

#[test]
def test_method_show : Bool :=
  Show.show Method.GET == "GET"
    && Show.show Method.DELETE == "DELETE"
    && Show.show Method.PATCH == "PATCH"

#[test]
def test_http_version_show : Bool :=
  Show.show HttpVersion.http1_1 == "HTTP/1.1"
    && Show.show HttpVersion.http1_0 == "HTTP/1.0"

#[test]
def test_status_constants : Bool :=
  Status.ok == 200u16
    && Status.not_found == 404u16
    && Status.internal_server_error == 500u16

def expect_some (got : Option String) (want : String) : Bool :=
  match got {
    Option.some v => v == want,
    Option.none => false
  }

#[test]
def test_headers_case_insensitive : Bool :=
  let h0 : Headers := Headers.empty in
  let h1 : Headers := Headers.set "Content-Type" "text/html" h0 in
  let h2 : Headers := Headers.add "X-Custom" "yes" h1 in
  expect_some (Headers.get "content-type" h2) "text/html"

#[test]
def test_headers_set_replaces : Bool :=
  let h0 : Headers := Headers.set "X" "1" Headers.empty in
  let h1 : Headers := Headers.set "x" "2" h0 in
  expect_some (Headers.get "X" h1) "2"

/// A removed key is gone whichever spelling looked it up.
#[test]
def test_headers_remove : Bool :=
  let h0 : Headers := Headers.set "Content-Type" "text/plain" Headers.empty in
  let h1 : Headers := Headers.remove "content-type" h0 in
  match Headers.get "Content-Type" h1 {
    Option.none => true,
    Option.some _ => false
  }

/// Removing a key that is not there leaves the rest alone rather than failing.
#[test]
def test_headers_remove_absent_keeps_others : Bool :=
  let h0 : Headers := Headers.set "X" "1" Headers.empty in
  let h1 : Headers := Headers.remove "Y" h0 in
  expect_some (Headers.get "X" h1) "1"

/// Removal takes every value, so a duplicate cannot survive it.
#[test]
def test_headers_remove_drops_duplicates : Bool :=
  let h0 : Headers := Headers.add "X" "2" (Headers.set "X" "1" Headers.empty) in
  let h1 : Headers := Headers.remove "X" h0 in
  Headers.is_empty h1
