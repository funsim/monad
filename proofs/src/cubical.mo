// The cubical interval and its operations, declared as primitive
// structure (`plans/type-system/univalence.md`, Stage 1).
//
// Each declaration here is BODY-LESS and carries a `#[cubical "..."]`
// MARKER. The marker, never the bare spelling, is what binds:
// `build_scope_def` (`lang/src/scope.mo`) reads it and enters the def's
// name into `ScopeData.cubical_prims`, and the checker
// (`lang/src/typecheck/infer.mo`) rewrites a resolved reference to that
// name into the `Term.cubical` it stands for -- `I`/`i0`/`i1` where the
// reference is bare (`type_check_free_var`), `ineg i0` etc. once
// applied (`type_check_app`'s cubical probe). A user's own `def I :
// Type`, without the marker, is an ordinary def and is not stolen.
//
// The declared signatures are not documentation-only even now: they
// carry name resolution, and they type the UNDER-APPLIED case
// (`imeet i` as a value is an `I -> I`). What they cannot yet do is
// carry dependent meaning -- that is R2 (`pi`/`lam` gaining named
// binders). `PathP`'s signature is the case in point: the general line
// `(A : I -> Sort l) -> A i0 -> A i1 -> Sort l` cannot state its `l`
// until level binders are first-class, so what is declared here is the
// `l = 1` instance -- a line into `Type`. The checker does not read
// this signature for the saturated case anyway (the cubical probe in
// `type_check_app` fires first, and `type_check_pathp` derives the
// result level from the line's own inferred type, which is the honest
// rule); the signature carries name resolution and types the
// under-applied `PathP A`.
//
// The interval carries the De Morgan algebra of CCHM / Cubical Agda
// over cartesian cubes: `ineg` is an involution, `imeet`/`ijoin` are
// idempotent, commutative, associative and mutually absorbing, with
// `i0`/`i1` as units. The reducer enforces the pointwise identities
// (`whnf_cubical`, lang/src/typecheck/whnf.mo); interval conversion
// between dimensions is syntactic identity, which cartesian cubes give
// for free and `Similar.similar` already answers.
//
// Non-goal, recorded here so it lives where someone would look: `I` is
// NEVER an inductive. Registering a two-constructor
// `type I { i0, i1 }` instead would make `match` on a dimension
// admissible, and one case split on a dimension destroys univalence.

#[cubical "interval"] def I : Type
#[cubical "i0"] def i0 : I
#[cubical "i1"] def i1 : I
#[cubical "ineg"] def ineg (i : I) : I
#[cubical "imeet"] def imeet (i : I) (j : I) : I
#[cubical "ijoin"] def ijoin (i : I) (j : I) : I

// The path former (Stage 2). The signature is the `l = 1` instance of
// the general rule -- see the header note above. A path ABSTRACTION is
// not a cubical term: `fn i => body` against a `PathP` is an ordinary
// `Term.lam` with an `I`-typed binder (`check_path_lam`), and a path
// APPLICATION is an ordinary application whose callee's type is a
// `PathP` (`extract_pi_ret`), which is why there is no `cub_path`
// primitive beside this one.
#[cubical "pathp"] def PathP (A : I -> Type) (a : A i0) (b : A i1) : Type

// Transport along a line of types (Stage 3). The same `l = 1` instance
// discipline as `PathP` above, and for the stronger reason: the general
// `transp : (A : I -> Sort l) (a : A i0) -> A i1` needs a level binder
// to state. The checker derives nothing from this signature for the
// saturated case -- `type_check_transp` fires first, reads the result
// type off the checked line, and the constant-family reduction
// (`whnf_transp`) needs no signature at all; the signature carries name
// resolution and types the under-applied `transp A`. Chosen over CCHM's
// `comp` deliberately: `transp` takes no cofibration, so Stage 3 lands
// before the face lattice exists (Stage 4).
#[cubical "transp"] def transp (A : I -> Type) (a : A i0) : A i1