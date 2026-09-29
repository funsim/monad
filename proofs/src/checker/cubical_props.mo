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
// six-declaration source of `proofs/src/cubical.mo`, because what is
// under test includes the marker's survival from source text to
// `ScopeData.cubical_prims`. The same string is pinned from the scope
// side in `lang/src/tests/cubical_bind_tests.mo`; if the declaration
// list ever changes, both copies change with it.

use lang::module {try_parse_decls}
use lang::scope {build_scope_from_decls}
use lang::typecheck::infer {empty_local_types, empty_locals, type_check}
use lang::types {
  CubicalPrim, ModulePath, Scope, ScopeData, Term,
  cubical_prim_eq, sentinel, sort_n,
}

def checker_synthetic_path : ModulePath :=
    ModulePath.mp (List.cons (Identifier.id "proofs_checker") List.empty)

/// The six Stage 1 declarations, spelled exactly as they are in
/// `proofs/src/cubical.mo`.
def cubical_decls_source : String :=
    String.concat "#[cubical \"interval\"] def I : Type\n"
    (String.concat "#[cubical \"i0\"] def i0 : I\n"
    (String.concat "#[cubical \"i1\"] def i1 : I\n"
    (String.concat "#[cubical \"ineg\"] def ineg (i : I) : I\n"
    (String.concat "#[cubical \"imeet\"] def imeet (i : I) (j : I) : I\n"
    "#[cubical \"ijoin\"] def ijoin (i : I) (j : I) : I"))))

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

/// Does checking `t` in `s` fail? The REJECTION pins: a cubical call
/// with an argument that is not a dimension must not check, whichever
/// path types it.
def check_fails_in (s : Scope) (t : Term) : Bool :=
    match type_check t Term.hole s empty_local_types empty_locals {
        err _ => true,
        ok _ => false,
    }

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