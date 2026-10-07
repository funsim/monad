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
// pre-existing `MatchTraversalMismatch` in the lowering pass, re-reproduced
// on this branch's head:
//
//   lower init/src/transformers_tests.mo: MatchTraversalMismatch {
//     expected: [Identifier("pair")], found: [Identifier("Monad")] }
//
// The type checker and `lower_core_ir.rs` disagree on match traversal order
// once `Monad.bind`'s instance resolution for `StateT S Id` is followed by a
// `Pair.pair` pattern match in the same file. It is `StateT`-specific rather
// than the `Monad.bind` + `Pair.pair` combination as such: a probe doing
// `Monad.bind` on `Id` followed by the identical `Pair.pair` match compiles
// and passes. Until that lowering bug is fixed, the `bind` half of the
// `Monad (StateT S M)` instance has NO executing test -- and by this
// module's own header rule, `check` alone cannot see a missing instance, so
// the gap is real. Restore this test then:
//
// #[test]
// def test_statet_bind : Bool :=
//     let m : StateT I64 Id I64 := Monad.pure 10 in
//     let n : StateT I64 Id I64 := Monad.bind m (fn a => Monad.pure (a + 1)) in
//     match Id.run (StateT.run n 100) {
//         Pair.pair s a => (s == 100) && (a == 11)
//     }
