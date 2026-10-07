// Monad transformers -- the stack-building layer over any `Monad`.
//
// Opt-in like `init.foldable` (not re-exported from `lib.mo`). `StateT` is
// the first and so far only one; `IdentityT`, `OptionT`, `ResultT`,
// `ReaderT`, and `WriterT` are the intended rest, each to follow the same
// shape: a `Functor`/`Applicative`/`Monad` instance over any underlying
// monad, plus `run`/`lift` and the effect operations.
//
// Every instance here is `[Monad M]`-constrained: resolving e.g.
// `Monad (StateT S M)` at a concrete call site recursively resolves
// `Monad M` underneath it, so stacks resolve one level at a time down
// to a base monad (`Id`, `IO`, ...). Because instance resolution is a
// run-time step in Monad, `transformers_tests.mo` has to EXECUTE every
// instance -- `check` alone cannot see a missing one. (The `bind` half of
// the `StateT` instance is currently unexercised: the lowering bug its own
// note describes.)

// Future transformers (WriterT) will need Monoid/Semigroup from foldable.
// use lib::foldable {Monoid, Semigroup}

/// State transformer: `StateT S M A = S -> M (Pair S A)` threads a state
/// `S` through the underlying monad `M`.
///
/// A single-constructor `type` rather than a `struct`, deliberately: a
/// parameterized `struct`'s constructor does not generalize its type
/// parameters on the Rust host (construction at `StateT.mk` fails with
/// ``type mismatch: `StateT` vs. `((StateT ?) ?) ?` `` while pattern
/// matching works), and no parameterized struct exists anywhere in the
/// corpus to prove otherwise. The single-constructor `type` is the shape
/// `examples/state_monad.mo` already uses; construction (`StateT.mk`),
/// matching, and everything else are spelled identically.
pub type StateT (S : Type) (M : Type -> Type) (A : Type) {
    mk (run : S -> M (Pair S A))
}

/// Run a `StateT` computation from an initial state, giving the final
/// state paired with the result.
pub def StateT.run (m : StateT S M A) (s : S) : M (Pair S A) :=
    match m {
        StateT.mk r => r s
    }

/// Evaluate the stateful computation, returning only the result.
pub def StateT.eval [Monad M] {S : Type} {A : Type} (m : StateT S M A) (s : S) : M A :=
    match m {
        StateT.mk r => Monad.bind (r s) (fn p =>
            match p {
                Pair.pair _ a => Monad.pure a
            })
    }

/// Execute the stateful computation, returning only the final state.
pub def StateT.exec [Monad M] {S : Type} {A : Type} (m : StateT S M A) (s : S) : M S :=
    match m {
        StateT.mk r => Monad.bind (r s) (fn p =>
            match p {
                Pair.pair st _ => Monad.pure st
            })
    }

/// Lift an underlying computation, leaving the state untouched.
pub def StateT.lift [Monad M] {S : Type} {A : Type} (m : M A) : StateT S M A :=
    StateT.mk (fn s => Monad.bind m (fn a => Monad.pure (Pair.pair s a)))

/// Internal: unwrap a `Pair S A` and run the continuation in the new state.
def StateT.bind_step [Monad M] {S : Type} {A : Type} {B : Type} (f : A -> StateT S M B) (p : Pair S A) : M (Pair S B) :=
    match p {
        Pair.pair s2 a => StateT.run (f a) s2
    }

/// Internal: the state-threading bind step. Extracted so the instance
/// body stays single-line (the parser doesn't accept multi-line lambdas
/// inside instance bodies).
def StateT.bind_go [Monad M] {S : Type} {A : Type} {B : Type} (ma : StateT S M A) (f : A -> StateT S M B) (s : S) : M (Pair S B) :=
    Monad.bind (StateT.run ma s) (StateT.bind_step f)

pub instance [Monad M] Monad (StateT S M) {
    def pure (a : A) : StateT S M A :=
        StateT.mk (fn s => Monad.pure (Pair.pair s a))
    def bind (ma : StateT S M A) (f : A -> StateT S M B) : StateT S M B :=
        StateT.mk (StateT.bind_go ma f)
}
