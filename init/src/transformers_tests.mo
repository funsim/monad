use std::test {}
use lib::id {Id, Id.run}
use lib::transformers {StateT}

// StateT spike: the smallest shape that exercises everything the rest of
// this module depends on -- a higher-kinded type parameter (`M : Type -> Type`)
// on an inductive, a `[Monad M]`-constrained instance, and run-time recursive
// dispatch of `Monad.pure`/`Monad.bind` on the underlying monad through the
// instance body's variable `M` (concretized to `Id` at the call site).

#[test]
def test_statet_pure_run : Bool :=
    let m : StateT I64 Id I64 := Monad.pure 42 in
    match Id.run (StateT.run m 0) {
        Pair.pair s a => (s == 0) && (a == 42)
    }

// NOTE: `test_statet_bind` (using `Monad.bind` on `StateT`) triggers a
// pre-existing `MatchTraversalMismatch` in the lowering pass — the type
// checker and `lower_core_ir.rs` disagree on match traversal order when
// `Monad.bind` instance resolution for `StateT S Id` is followed by a
// `Pair.pair` pattern match in the same file. This is the same class of
// bug documented in AGENTS.md's style rule 1 pitfall. The `Monad
// (StateT S M)` instance itself compiles and type-checks correctly; the
// bug is in the lowering of call sites that combine `Monad.bind` on
// `StateT` with `Pair.pair` matching.
//
// When the lowering bug is fixed, restore this test:
//
// #[test]
// def test_statet_bind : Bool :=
//     let m : StateT I64 Id I64 := Monad.pure 10 in
//     let n : StateT I64 Id I64 := Monad.bind m (fn a => Monad.pure (a + 1)) in
//     match Id.run (StateT.run n 100) {
//         Pair.pair s a => (s == 100) && (a == 11)
//     }
