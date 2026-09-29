// Pins on the CHECKER half of the cubical name-binding (Stage 1 step 3,
// plans/type-system/univalence.md): a resolved reference to a
// `#[cubical "..."]`-marked name must come back from `type_check` as the
// `Term.cubical` it stands for, not as the free variable the source
// spelling suggests.
//
// TERM-SHAPED, not accept/reject, and the reason is the hazard itself:
// the marked declarations carry real declared signatures
// (`ineg : I -> I`), so `ineg i0` is ACCEPTED by the ordinary
// signature-driven path too -- an accept/reject pin passes with the
// rewrite missing, which is precisely the failure mode
// (`try_type_check_def_call` typing the call fine and the rewrite
// silently never happening) that putting the cubical probe FIRST in
// `type_check_app` exists to prevent. Reading `tt.term` is the only
// observation that discriminates. `type_check`'s `TypedTerm` is `pub`
// and its `.term` field is readable, so no export widening is needed.
//
// The scope is built by the REAL parse + scope-build pipeline
// (`try_parse_decls` + `build_scope_from_decls`) over the exact
// seven-declaration source of `proofs/src/cubical.mo`, because what is
// under test includes the marker's survival from source text to
// `ScopeData.cubical_prims`. The same string is pinned from the scope
// side in `lang/src/tests/cubical_bind_tests.mo`; if the declaration
// list ever changes, both copies change with it.

use lang::module {try_parse_decls}
use lang::scope {build_scope_from_decls}
use lang::typecheck::cubical {peels_to_bare_interval}
use lang::typecheck::infer {empty_local_types, empty_locals, type_check}
use lang::types {
  CubicalPrim, ModulePath, Scope, ScopeData, Term,
  cub_i0, cub_i1, cub_ineg, cub_interval, cub_pathp, cubical_prim_eq,
  sentinel, sort_n,
}

def checker_synthetic_path : ModulePath :=
    ModulePath.mp (List.cons (Identifier.id "proofs_checker") List.empty)

/// The seven Stage 1+2 declarations, spelled exactly as they are in
/// `proofs/src/cubical.mo`.
def cubical_decls_source : String :=
    String.concat "#[cubical \"interval\"] def I : Type\n"
    (String.concat "#[cubical \"i0\"] def i0 : I\n"
    (String.concat "#[cubical \"i1\"] def i1 : I\n"
    (String.concat "#[cubical \"ineg\"] def ineg (i : I) : I\n"
    (String.concat "#[cubical \"imeet\"] def imeet (i : I) (j : I) : I\n"
    (String.concat "#[cubical \"ijoin\"] def ijoin (i : I) (j : I) : I\n"
    "#[cubical \"pathp\"] def PathP (A : I -> Type) (a : A i0) (b : A i1) : Type")))))

/// The scope the checker sees when `proofs/src/cubical.mo` is loaded.
/// A parse failure yields an empty scope, which makes every pin below
/// fail rather than silently pass against a scope with nothing bound.
def cubical_scope : Scope :=
    let sd : ScopeData :=
        match try_parse_decls cubical_decls_source {
            Option.some decl_list => build_scope_from_decls checker_synthetic_path decl_list,
            Option.none => build_scope_from_decls checker_synthetic_path List.empty,
        } in
    {
        module_id := checker_synthetic_path,
        scope := sd,
        parent := Option.none,
    }

/// The same declarations WITHOUT any `#[cubical]` markers -- the
/// negative control's scope. These are ordinary body-less defs with
/// ordinary declared signatures, which is what a user's own
/// same-named defs are.
def unmarked_scope : Scope :=
    let source : String :=
        String.concat "def I : Type\n"
        (String.concat "def i0 : I\n"
        (String.concat "def i1 : I\n"
        (String.concat "def ineg (i : I) : I\n"
        (String.concat "def imeet (i : I) (j : I) : I\n"
        "def ijoin (i : I) (j : I) : I")))) in
    let sd : ScopeData :=
        match try_parse_decls source {
            Option.some decl_list => build_scope_from_decls checker_synthetic_path decl_list,
            Option.none => build_scope_from_decls checker_synthetic_path List.empty,
        } in
    {
        module_id := checker_synthetic_path,
        scope := sd,
        parent := Option.none,
    }

/// A free (global) reference by name -- `sentinel` is what marks a var as
/// unbound-and-resolved-by-name, the same helper idiom
/// `lang/src/tests/whnf_tests.mo` uses.
def free_var (nm : String) : Term := Term.var sentinel (DebugName.named (Identifier.id nm))

/// Does checking `t` in `succeed and produce a checked term that is
/// exactly the primitive `p` applied to no arguments?
def checks_as_bare_prim (s : Scope) (t : Term) (p : CubicalPrim) : Bool :=
    match type_check t Term.hole s empty_local_types empty_locals {
        ok tt =>
            match tt.term {
                // Two-step match: a variant constructor with a single
                // struct payload has no field names at the constructor
                // level, so the payload match is its own `match`
                // (verified -- the directly nested form does not parse).
                Term.cubical c =>
                    match c {
                        { prim := q, args := as } => cubical_prim_eq q p && List.is_empty as,
                    },
                _ => false,
            },
        err _ => false,
    }

/// Does checking `t` in `s` succeed and produce a checked term that is
/// `p` applied to exactly one checked argument, itself the bare
/// primitive `arg`?
def checks_as_prim_applied_to (s : Scope) (t : Term) (p : CubicalPrim) (arg : CubicalPrim) : Bool :=
    match type_check t Term.hole s empty_local_types empty_locals {
        ok tt =>
            match tt.term {
                Term.cubical c =>
                    match c {
                        { prim := q, args := as } =>
                            cubical_prim_eq q p
                                && match as {
                                    List.cons a rest =>
                                        List.is_empty rest
                                            && match a {
                                                Term.cubical c2 =>
                                                    match c2 {
                                                        { prim := q2, args := as2 } =>
                                                            cubical_prim_eq q2 arg && List.is_empty as2,
                                                    },
                                                _ => false,
                                            },
                                    List.empty => false,
                                },
                    },
                _ => false,
            },
        err _ => false,
    }

/// Does checking `t` in `s` succeed and produce a checked term that is
/// `p` applied to exactly two checked arguments, themselves the bare
/// primitives `arg1` then `arg2` -- pinning spine ORDER, since a
/// substitution that peels arguments in the wrong direction silently
/// swaps them.
def checks_as_prim_applied_to_two (s : Scope) (t : Term) (p : CubicalPrim)
    (arg1 : CubicalPrim) (arg2 : CubicalPrim) : Bool :=
    match type_check t Term.hole s empty_local_types empty_locals {
        ok tt =>
            match tt.term {
                Term.cubical c =>
                    match c {
                        { prim := q, args := as } =>
                            cubical_prim_eq q p
                                && match as {
                                    List.cons a1 rest1 =>
                                        match rest1 {
                                            List.cons a2 rest2 =>
                                                List.is_empty rest2
                                                    && arg_is_bare_prim a1 arg1
                                                    && arg_is_bare_prim a2 arg2,
                                            List.empty => false,
                                        },
                                    List.empty => false,
                                },
                    },
                _ => false,
            },
        err _ => false,
    }

/// Is `t` the cubical term of the bare primitive `p`?
def arg_is_bare_prim (t : Term) (p : CubicalPrim) : Bool :=
    match t {
        Term.cubical c =>
            match c {
                { prim := q, args := as } => cubical_prim_eq q p && List.is_empty as,
            },
        _ => false,
    }

/// Does checking `t` in `s` succeed WITHOUT rewriting the head into a
/// cubical term? The under-applied and unmarked cases must both land
/// here: the rewrite owns saturated calls on MARKED names only.
def checks_without_cubical_rewrite (s : Scope) (t : Term) : Bool :=
    match type_check t Term.hole s empty_local_types empty_locals {
        ok tt =>
            match tt.term {
                Term.cubical _ => false,
                _ => true,
            },
        err _ => false,
    }

/// Does checking `t` against `expected` in `s` fail? The REJECTION pins:
/// a cubical call with an argument that is not a dimension must not
/// check, whichever path types it. The expected type is a parameter
/// because the Stage 2 rules -- path abstraction especially -- only
/// exist relative to a `PathP` expected type.
def check_fails_against (s : Scope) (t : Term) (expected : Term) : Bool :=
    match type_check t expected s empty_local_types empty_locals {
        err _ => true,
        ok _ => false,
    }

/// Does checking `t` against `expected` in `s` fail, carrying a local
/// TYPE list? The sym-direction reject needs a local `p` in scope --
/// through the empty-list variant it would fail for the WRONG reason
/// (an unbound variable), not because the endpoints disagree.
def check_fails_against_with (s : Scope) (local_types : List Term) (t : Term)
    (expected : Term) : Bool :=
    match type_check t expected s local_types empty_locals {
        err _ => true,
        ok _ => false,
    }

/// Does checking `t` in `s` fail with NO expected type? The Stage 1
/// rejects are all formation-independent -- the rewrite either happens
/// or the call is ill-typed outright.
def check_fails_in (s : Scope) (t : Term) : Bool :=
    check_fails_against s t Term.hole

// ─── the rewrite itself ───────────────────────────────────────────────

#[test]
def test_bare_interval_reference_is_the_cubical_term : Bool :=
    // `I` referenced bare: arity-0, so the reference IS the term --
    // `type_check_free_var`'s cubical arm, not the declared-signature
    // fallback.
    checks_as_bare_prim cubical_scope (free_var "I") CubicalPrim.interval

#[test]
def test_bare_endpoint_references_are_the_cubical_terms : Bool :=
    checks_as_bare_prim cubical_scope (free_var "i0") CubicalPrim.i0
        && checks_as_bare_prim cubical_scope (free_var "i1") CubicalPrim.i1

#[test]
def test_saturated_call_rewrites_to_cubical : Bool :=
    // `ineg i0`: the cubical probe in `type_check_app` owns the call,
    // and the argument is itself rewritten (it is checked by the same
    // checker, recursively) before being stored in `args`.
    checks_as_prim_applied_to
        cubical_scope (Term.app (free_var "ineg") (free_var "i0")) CubicalPrim.ineg CubicalPrim.i0

#[test]
def test_two_argument_call_rewrites_to_cubical : Bool :=
    // `imeet i0 i1` -- nested application spine; `flatten_call_spine`
    // must collect both arguments in order.
    let spine : Term := Term.app (Term.app (free_var "imeet") (free_var "i0")) (free_var "i1") in
    checks_as_prim_applied_to_two cubical_scope spine CubicalPrim.imeet CubicalPrim.i0 CubicalPrim.i1

// ─── what must NOT be rewritten ────────────────────────────────────────

#[test]
def test_under_applied_call_is_not_rewritten : Bool :=
    // `imeet i0` -- one argument short of the arity. The probe declines,
    // the declared-signature path types it, and the term stays an
    // application whose type is the residual `I -> I`. Checking must
    // still SUCCEED: the declared signatures exist to carry exactly
    // this case.
    checks_without_cubical_rewrite cubical_scope (Term.app (free_var "imeet") (free_var "i0"))

#[test]
def test_unmarked_name_is_not_rewritten : Bool :=
    // Same names, no markers: the binding is keyed off the MARKER, never
    // the bare spelling, so these stay ordinary defs.
    checks_without_cubical_rewrite unmarked_scope (Term.app (free_var "ineg") (free_var "i0"))
        && checks_without_cubical_rewrite unmarked_scope (free_var "I")

// ─── rejection ──────────────────────────────────────────────────────────

#[test]
def test_cubical_call_rejects_non_interval_argument : Bool :=
    // `ineg Type` -- a sort is not a dimension. Both the cubical probe
    // (argument checked against `I`) and the declared-signature path
    // reject it; the pin holds the line either way, and is the one
    // genuinely negative claim this file makes about the rewrite.
    check_fails_in cubical_scope (Term.app (free_var "ineg") (sort_n 1))

// ─── Stage 2: PathP formation ───────────────────────────────────────────
//
// The formation rule is pinned TERM-SHAPED as well as by rejection:
// the rewritten call must come back as the cubical `pathp` primitive
// carrying the checked LINE (a `Term.lam`), not stay an app spine on
// the free `PathP` -- the declared-signature path would ACCEPT the
// call too, so acceptance alone does not discriminate.

/// The line every formation pin uses: `fn i => I`, the constant line
/// into `Type`. The binder annotation is a hole on purpose -- the
/// formation rule INFERS the line, and a hole domain is exactly the
/// shape `path_line_dom_ok` accepts.
def const_line : Term :=
    Term.lam (DebugName.named (Identifier.id "i")) Term.hole (free_var "I")

/// The saturated source spine `PathP line left right`, with the
/// endpoints in their SOURCE spelling so the pins exercise the rewrite
/// on the way through, exactly as a real call site would.
def pathp_call (line : Term) (left : String) (right : String) : Term :=
    Term.app (Term.app (Term.app (free_var "PathP") line) (free_var left))
        (free_var right)

/// Does checking `t` against `expected` in `s` succeed and come back as
/// the cubical `pathp` primitive applied to exactly the checked line,
/// `left`, `right` -- with result type a sort, as a former of types must
/// produce?
def checks_as_pathp (s : Scope) (t : Term) (expected : Term)
    (left : CubicalPrim) (right : CubicalPrim) : Bool :=
    match type_check t expected s empty_local_types empty_locals {
        ok tt =>
            match tt.typ {
                Term.sort _ =>
                    match tt.term {
                        Term.cubical c =>
                            match c {
                                { prim := q, args := as } =>
                                    cubical_prim_eq q CubicalPrim.pathp
                                        && match as {
                                            // Exactly three args, pinned by the
                                            // peeling below reaching `List.empty` --
                                            // the arity table rejects any other
                                            // count at formation, so this match
                                            // is a shape read, not an arity check.
                                            List.cons ln rest =>
                                                match ln {
                                                    Term.lam _dbg _dom _body =>
                                                        match rest {
                                                            List.cons lft rest2 =>
                                                                match rest2 {
                                                                    List.cons rgt rest3 =>
                                                                        List.is_empty rest3
                                                                            && arg_is_bare_prim lft left
                                                                            && arg_is_bare_prim rgt right,
                                                                    List.empty => false,
                                                                },
                                                            List.empty => false,
                                                        },
                                                    _ => false,
                                                },
                                            List.empty => false,
                                        },
                            },
                        _ => false,
                    },
                _ => false,
            },
        err _ => false,
    }

#[test]
def test_pathp_formation_checks_and_rewrites : Bool :=
    // `PathP (fn i => I) i0 i1` checks against `Type 1`: the line is a
    // function out of the interval into a sort, both endpoints are
    // dimensions, and the checked term is the cubical primitive.
    checks_as_pathp cubical_scope (pathp_call const_line "i0" "i1") (sort_n 1)
        CubicalPrim.i0 CubicalPrim.i1

#[test]
def test_pathp_rejects_a_line_not_out_of_the_interval : Bool :=
    // `fn (i : Type) => I`: a dimension binder is the only domain the
    // line rule accepts -- a sort domain is not the interval.
    check_fails_in cubical_scope
        (pathp_call
            (Term.lam (DebugName.named (Identifier.id "i")) (sort_n 1) (free_var "I"))
            "i0" "i1")

#[test]
def test_pathp_rejects_a_line_not_into_a_sort : Bool :=
    // `fn i => i0`: the line lands in the interval, and the result sort
    // is read off the line's codomain -- there is none to read.
    check_fails_in cubical_scope
        (pathp_call
            (Term.lam (DebugName.named (Identifier.id "i")) Term.hole (free_var "i0"))
            "i0" "i1")

#[test]
def test_pathp_rejects_an_endpoint_not_in_the_line : Bool :=
    // `PathP (fn i => I) (fn j => i0) i1`: the left endpoint is a
    // function, but the line's codomain at `i0` is the interval -- the
    // endpoints are checked AGAINST `A i0`/`A i1`, not merely collected.
    check_fails_in cubical_scope
        (Term.app (Term.app (Term.app (free_var "PathP") const_line)
            (Term.lam (DebugName.named (Identifier.id "j")) Term.hole (free_var "i0")))
            (free_var "i1"))

// ─── Stage 2: path abstraction (check_path_lam) ──────────────────────────

/// Does checking `t` against `expected` in `s` succeed and come back as
/// a lambda whose BINDER is the bare interval? The binder type is the
/// pin: the written annotation may be a hole, but the rule binds a
/// dimension, and the checked term records that. The local TYPE list is
/// a parameter because the boundary pins need a local `p` in scope.
def checks_with_interval_binder (s : Scope) (local_types : List Term)
    (t : Term) (expected : Term) : Bool :=
    match type_check t expected s local_types empty_locals {
        ok tt =>
            match tt.term {
                Term.lam _dbg binder_typ _body => peels_to_bare_interval binder_typ,
                _ => false,
            },
        err _ => false,
    }

#[test]
def test_path_abstraction_checks_with_an_interval_binder : Bool :=
    // `fn i => i0` against `PathP (fn i => I) i0 i0`: both boundaries
    // agree with the constantly-`i0` body, so the abstraction is
    // accepted -- and the checked binder is the interval itself, not
    // the hole the source wrote.
    checks_with_interval_binder cubical_scope empty_local_types
        (Term.lam (DebugName.named (Identifier.id "i")) Term.hole (free_var "i0"))
        (cub_pathp const_line (cub_i0) (cub_i0))

#[test]
def test_path_abstraction_rejects_a_wrong_i1_boundary : Bool :=
    // Same body against `PathP (fn i => I) i0 i1`: the body is
    // constantly `i0`, so at `i1` it disagrees with the type's right
    // endpoint.
    check_fails_against cubical_scope
        (Term.lam (DebugName.named (Identifier.id "i")) Term.hole (free_var "i0"))
        (cub_pathp const_line (cub_i0) (cub_i1))

#[test]
def test_path_abstraction_rejects_a_wrong_i0_boundary : Bool :=
    // `fn i => i1` against the same type: the LEFT boundary is the one
    // that disagrees this time -- both directions of the rule are
    // pinned, not just the first one the walk hits.
    check_fails_against cubical_scope
        (Term.lam (DebugName.named (Identifier.id "i")) Term.hole (free_var "i1"))
        (cub_pathp const_line (cub_i0) (cub_i1))

#[test]
def test_path_abstraction_rejects_a_non_interval_binder : Bool :=
    // `fn (i : Type) => i0`: the annotation must check AS the bare
    // interval; a sort is not a dimension, even though both boundaries
    // would otherwise agree.
    check_fails_against cubical_scope
        (Term.lam (DebugName.named (Identifier.id "i")) (sort_n 1) (free_var "i0"))
        (cub_pathp const_line (cub_i0) (cub_i0))

// ─── Stage 2: path application and the stuck-endpoint mitigation ──────────

/// The expected type of a local `p : PathP (fn i => I) i0 i1`, as a raw
/// term: the elimination rule peels it, nothing checks it.
def path_typ : Term := cub_pathp const_line (cub_i0) (cub_i1)

/// A de Bruijn local at `idx` named `nm`: `type_check_var` resolves by
/// index through the local TYPE list, so the pins can carry the type in
/// `local_types` without hand-building a `LocalScope`.
def local_at (idx : I64) (nm : String) : Term :=
    Term.var idx (DebugName.named (Identifier.id nm))

#[test]
def test_path_applied_at_an_endpoint_returns_the_boundary : Bool :=
    // `p i0` for a stuck local `p`: whnf cannot reduce a path
    // application whose head is a variable -- the incompleteness the
    // elimination arm exists to patch -- so the checked term must come
    // back as the LEFT endpoint the path's own type carries.
    match type_check (Term.app (local_at 0 "p") (free_var "i0")) Term.hole
        cubical_scope (List.cons path_typ empty_local_types) empty_locals {
        ok tt => arg_is_bare_prim tt.term CubicalPrim.i0,
        err _ => false,
    }

#[test]
def test_path_applied_at_a_stuck_dimension_stays_an_application : Bool :=
    // `p q` for a stuck local dimension `q : I`: not an endpoint, so
    // the mitigation declines and the checked term is the application
    // itself -- the rule rewrites ONLY at the boundary.
    let local_types : List Term :=
        List.cons cub_interval (List.cons path_typ empty_local_types) in
    match type_check (Term.app (local_at 1 "p") (local_at 0 "q")) Term.hole
        cubical_scope local_types empty_locals {
        ok tt =>
            match tt.term {
                Term.app _f _a => true,
                _ => false,
            },
        err _ => false,
    }

// ─── Stage 2: boundary normalization (the term-level `sym`) ──────────────
//
// `fn i => p (ineg i)` against `PathP (fn i => I) i1 i0` is `sym p` with
// the constant line: the endpoints SWAP. The substituted boundaries are
// `p (ineg i0)` and `p (ineg i1)` -- stuck applications whose dimensions
// whnf folds to the opposite endpoint, and which still do not reduce --
// so the check succeeds only because `normalize_path_boundary` rewrites
// each to the boundary value `p`'s own type carries. This is the one
// pin on the normalizer + stuck rewriter pair, and the direction pin
// below it is what keeps the rewrite honest about WHICH endpoint.

/// `fn i => p (ineg i)` with `p` one binder out: the body is a path
/// application at the negated dimension.
def sym_body : Term :=
    Term.lam (DebugName.named (Identifier.id "i")) Term.hole
        (Term.app (local_at 1 "p")
            (cub_ineg (local_at 0 "i")))

#[test]
def test_sym_boundaries_check_through_the_stuck_rewriter : Bool :=
    checks_with_interval_binder cubical_scope (List.cons path_typ empty_local_types)
        sym_body (cub_pathp const_line (cub_i1) (cub_i0))

#[test]
def test_sym_rejects_when_the_endpoints_do_not_swap : Bool :=
    // The SAME body against the UNswapped type: if the boundary
    // comparison were vacuous -- or the rewriter answered the wrong
    // endpoint -- this would check. It must not: at `i0` the body
    // normalizes to `p`'s RIGHT endpoint, and the type's left is `i0`.
    check_fails_against_with cubical_scope (List.cons path_typ empty_local_types)
        sym_body (cub_pathp const_line (cub_i0) (cub_i1))