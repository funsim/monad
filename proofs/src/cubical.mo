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

// The face lattice (Stage 4). Cofibrations are INTERVAL terms: `∧`/`∨`
// reuse `imeet`/`ijoin`, `0`/`1` reuse `i0`/`i1`, and the only new
// formers are the two generators `face_eq0`/`face_eq1` -- the
// constraints `i = 0` / `i = 1` -- and the truth predicate `is_one`,
// which is a former of TYPES and lands in `Sort 1` (the `l = 1`
// discipline again). Partial elements need no new syntax and no `Sub`:
// a partial element of `A` on cofibration `φ` is an ordinary function
// `is_one φ -> A`, Agda's trick -- `fn (u : is_one φ) => a` is a
// `Term.lam` the ordinary pi rule already checks.
//
// `face_eq0`/`face_eq1` deliberately have no elimination into `Bool`:
// the endpoint laws fold (`whnf_face`), the contradiction law folds,
// and everything else stays stuck -- CCHM POSTULATES `isOne1 = 0`
// (there is no cube point that is BOTH endpoints), and a reducer that
// folded `ijoin (face_eq0 u) (face_eq1 u)` to `i1` would make the
// interval two-point by conversion. The whole-term decision procedure
// `face_decide` (lang/src/typecheck/faces.mo) answers `some false`
// there without ever answering `some true`.
#[cubical "face_eq0"] def face_eq0 (i : I) : I
#[cubical "face_eq1"] def face_eq1 (i : I) : I
#[cubical "is_one"] def is_one (i : I) : Type

// Kan composition (Stage 5). `hcomp A φ u u0 : A` composes the open box
// whose sides are the system `u : I -> is_one φ -> A` over the
// cofibration `φ`, starting from the base `u0 : A`.
//
// Its BOUNDARY law is CCHM's and is NOT `u0`: on `φ` the composite is the
// system's TOP, `hcomp A φ u u0 ≡ u i1`, while `u0` is the system's
// bottom (`u i0 = u0` on `φ`). The asymmetry matters, so it is written
// here where someone reaching for the rule would look. Of the two
// decided cases exactly one is reducible:
//
//   * `φ` refuted (the empty subobject): the system constrains nothing
//     and the composite is the base, `hcomp A i0 u u0 ≡ u0`
//     (`whnf_hcomp`, lang/src/typecheck/whnf.mo, deciding via the
//     whole-term `face_decide`, lang/src/typecheck/faces.mo).
//   * `φ` satisfied: the honest answer is `u i1`, which needs a witness
//     of `is_one i1` -- and this syntax has no canonical term for one,
//     because `is_one` stays rigid (see its note above) and nothing in
//     the checker fabricates a proof. So it stays STUCK. Reducing to
//     `u0` here instead would be unsound, so the rule is absent rather
//     than wrong, deliberately, in the style of Stage 4's three absent
//     face rules. Where a canonical `is_one i1` would have to come from
//     is Stage 6 (`Glue`).
//
// `A` is an explicit argument, unlike `PathP`'s line: `hcomp`'s result is
// `A` itself, so an implicit `A` could not be recovered from the system
// (`type_check_hcomp`, lang/src/typecheck/infer.mo). The signature is the
// `Type`-valued instance of the general rule, the same `l = 1`
// discipline `PathP`/`transp` above carry, and it is not read for the
// saturated case -- `type_check_hcomp` derives the result from the
// arguments and the expected type. CCHM derives `comp` from `hcomp` and
// `transp`; that library step is deferred with `paths.mo`, for the reason
// recorded there (measured sig vacuity makes a source-level `comp` a
// declaration no one can check).
#[cubical "hcomp"] def hcomp (A : Type) (phi : I) (u : I -> is_one phi -> A) (u0 : A) : A
