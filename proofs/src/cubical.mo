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
// binders), and it is why `PathP`'s signature is absent here: a line of
// types is not stateable until named binders exist.
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