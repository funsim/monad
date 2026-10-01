// IO module -- the pure, portable `IO` monad wrapper itself. All
// OS-specific native operations (println, file I/O, ...) live in
// std/io.mo instead -- see AGENTS.md's "init vs std" section.

// TODO make into indexed monad
type IO A {
 io A
}

/// The public API for creating an `IO` value.
///
/// `io` -- the constructor -- is deliberately not ambient and must not be
/// named anywhere but this file: build with `IO.pure`, and reach a value's
/// contents with `Monad.bind` (`let x <- e;` in a `do` block), which is
/// what the instance below does. Nothing outside this file needs either
/// spelling, so the constructor stays free to become a native once the
/// self-hosted codegen supports one.
def IO.pure (a : A) : IO A :=
    IO.io a

instance Monad IO {
  def pure (a : A) : IO A :=
    IO.pure a
  def bind (a : IO A) (f : A -> IO B) : IO B :=
    match a {
      io a => f a
    }
}

// TODO support constraints
// def IO.fprintln [ToString A] (a: A) : IO Unit :=
//   IO.println (ToString.to_string a)
