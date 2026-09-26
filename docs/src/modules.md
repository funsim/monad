# Modules and Imports

Monad organizes code into modules, allowing you to structure, reuse, and
namespace your code.

## Basic Module Structure

Each `.mo` file is a module. The module name is derived from its path relative
to a search-path root: `std/concurrent/fiber.mo` is the module
`std.concurrent.fiber`.

## Importing Modules

Use `use` to bring a module into scope, listing exactly the names you want in
`{...}`:

```monad
use io {IO}
use std::path {Path}

def p : Option Path := none
def io_unit : Option (IO Unit) := none
```

### `::` separates module path segments

A `use` path uses `::` between its segments, the way Rust does. `::` is only
for `use`: `open` paths name a namespace rather than a file, and dotted
definition names (`String.length`), member access (`x.field`) and constructor
paths (`List.cons`) all keep `.`. The separator is what tells a module path
apart from a name path on sight.

`::` is the only spelling a `use` path accepts — the corpus migration is
complete, so a dotted `use std.list` is a parse error rather than a synonym.
Both parsers enforce it (`use_path_sep` in `lang/src/parser.mo`,
`use_path_expression` in `core/src/parser.rs`). The three-way rule in full:

| Form | Separator | Example |
| --- | --- | --- |
| `use` path (names a file) | `::` | `use std::list {intercalate}` |
| `open` path (names a namespace) | `.` | `open List {map}` |
| term reference, decl name, field access | `.` | `List.cons`, `x.field`, `String.length` |

Inside a mote, `lib` names that mote's own library root — Rust's `crate`:

```monad,ignore
use lib::parser::core {ParseResult}   // this mote's own src/parser/core.mo
```

That block is tagged `ignore` because `lib` only means something *inside* a
mote, and the examples here are checked standing alone. `lib` is
root-relative within its mote, so it reads the same from any file in it.

An empty `{}` still loads the module — for qualified access, and for its
instances — without binding any bare names:

```monad
use io {}
open IO {println}

def main (args : List String) : IO Unit := println "Hello"
```

`{*}` imports everything explicitly. A bare `use io` with no braces at all still
parses, but the compiler warns that it is deprecated.

## Opening Modules

`open` makes a module's definitions available without their prefix:

```monad
use io {IO}
open IO {println}

def main (args : List String) : IO Unit := println "Hello"
```

Without the `open`, write the full path — which always works:

```monad
use io {IO}

def main (args : List String) : IO Unit := IO.println "Hello"
```

## What the Prelude Opens

The prelude is loaded into every file and opens these, which is why their
constructors are available bare:

```monad,ignore
open Unit {unit}
open Bool {and, false, not, or, true}
open Result {err, ok}
open Option {none, some}
open True {trivial}
```

## The Standard Library

The library is split in two, and the split is a rule, not a convention:

- **`init/`** — pure, portable core. Code that must work in any environment,
  including wasm and embedded targets. No OS-specific natives.
- **`std/`** — OS-specific implementations and genuine side effects.

`IO` itself (the type and its `Monad` instance) lives in `init/io.mo`;
`IO.println` and file access live in `std/io.mo`, because they touch the
operating system.

### What is available without importing

Twelve modules are loaded ambiently: the prelude, plus `id`, `io`, `number`,
`math`, `string`, `list`, the `init` hub, `std.path`, `std.io`, `std.process`,
and the `std` hub. Everything else must be imported.

`prelude` is loaded for you, so there is nothing to `use` it for — but it is
not off limits: `use prelude {…}` resolves like any other module
(`init/src/prelude.mo`, with its own resolution case because the name has no
directory of its own to match), which is what a file that wants a prelude name
it cannot otherwise reach would do.

### The re-export hubs do not cover everything

`use init {...}` resolves to `init/lib.mo`, which re-exports only `id`, `io`,
`number`, `math`, `string`, and `list`. `use std {...}` resolves to
`std/lib.mo`, which re-exports only `std.path`, `std.io`, and `std.process`.

Everything else needs an explicit qualified import. This catches people out, so
here is the full list:

| Module | Ambient? | Contents |
|--------|----------|----------|
| `init` | yes | Re-export hub; `From` class |
| `init.list` | yes | `List.get` |
| `init.string` | yes | String operations |
| `init.math` / `init.number` | yes | All fixed-width numeric ops and instances |
| `init.id` | yes | The `Id` identity monad |
| `init.foldable` | **no** | `Semigroup`, `Monoid`, `Foldable`, `Traversable` |
| `init.optics` | **no** | `Lens`, `Prism`, `view`, `set`, `over` |
| `init.meta` | **no** | Reflection types used by `#[derive]` |
| `io` | yes | The `IO` type and its `Monad` instance |
| `std` | yes | Re-export hub |
| `std.io` | yes | `IO.println`, file I/O, `get_env`, `current_time` |
| `std.path` | yes | The validated `Path` type |
| `std.process` | yes | `exec_cmd`, `process_id` |
| `std.list` | **no** | `length`, `filter`, `any`, `all`, `sum`, `dedup_by`, … |
| `std.map` | **no** | `Map` class, `HashMap`, `BTreeMap` |
| `std.base` | **no** | `Ordering`, `Ord`, `Default`, `Enum`, `Bounded` |
| `std.show` / `std.debug` | **no** | The `Show` and `Debug` classes |
| `std.derive` | **no** | The `#[derive]` backends |
| `std.test` | **no** | `Test.assert` |
| `std.bench` | **no** | Timing helpers |
| `std.ansi` | **no** | Terminal colours |
| `std.sha256` | **no** | SHA-256, in pure Monad |
| `std.concurrent.fiber` / `.combine` | **no** | Fibers and combinators |

See [The Standard Library](./stdlib.md) for what is in each.

## How Modules Are Found

Resolution is **mote-based**, with the directory conventions kept underneath as
the script-mode fallback. For a module path `a::b`, the compiler tries, in
order:

| Candidate | Notes |
|-----------|-------|
| `init/src/prelude.mo` | only for the exact name `prelude` |
| `init/src/lib.mo` | only for the exact name `init` |
| `std/src/lib.mo` | only for the exact name `std` |
| `{dir of the importing file}/a/b.mo` | relative to the file doing the `use` |
| `a/b.mo` | relative to the working directory |
| `a/src/b.mo`, `a/src/lib.mo` | the head segment names a mote: `use example::greet` → `example/src/greet.mo` |
| `init/src/a/b.mo` | |
| `std/src/a/b.mo` | |
| `lang/src/a/b.mo` | |

First hit wins. `init` and `std` need their own cases because their module
*names* no longer match their *file* names — both resolve to a `lib.mo`
re-export hub.

Every one of those is anchored at the working directory or at the importing
file, so all of them miss for a mote in its **own** repository, standing
somewhere that is not a compiler checkout. That is what the rest of the search
is for, and this half is what makes the word *mote* load-bearing rather than
decorative. In order, and only after every candidate above has missed:

1. **The `motes/` convention.** Every `motes/*/src/{stem}.mo` is probed, which
   is how a bare `use greet` finds `motes/example/src/greet.mo` without naming
   its mote; then `motes/{head}/src/{rest}.mo` for the qualified spelling.
2. **The importing file's own manifest.** `mote.toml`'s declared dependency
   paths answer the lookup, so `use std::list` resolves to the dependency's
   real `src/list.mo` rather than to a directory that happens to be named like
   it. This is the step that makes resolution key off the **mote**, not the
   working directory, and it covers both the file's own mote root
   (`{importing file's mote root}/a/b.mo`) and its declared
   `[dependencies.X] path` entries.
3. **An installed toolchain root.** `$MONAD_ROOT` if it is set, else
   `$MONAD_HOME` (default `~/.monad`) — read through `active` and
   `downloads/<tag>/` — which is the directory `monadup install` leaves the
   binary and the mote sources in. This is the tier that lets a mote in its
   own repository build with nothing declared at all, and it is why
   `init`, `std`, `llvm` and `runtime` ship as an install asset rather than
   only as this repository.

The first three candidates are spelled relative to the checkout root, so from a
directory that is not the root they miss — which is why they *also* consult the
manifest, and why `monad check src/main.mo` from inside `cli/` now loads its own
`init`/`std` and reports nothing. Run the compiler from the checkout root and
nothing changes, because the first candidate always hits there.

If none of the three tiers answers and the module was one of the ambient few
(`prelude`, `init`, `std`), the compiler says so on one line and names the way
out — `monadup install`, `$MONAD_ROOT`/`$MONAD_HOME`, or a `path` dependency —
rather than only listing the modules it could not resolve.

`check` and `test` each take the same three modes: explicit paths,
`--workspace`/`-w` (every mote in the enclosing workspace), or bare — the mote
containing the working directory. A bare `check` or `test` outside any mote
says there is nothing to do and exits non-zero; it does not print usage and
report success. `compile` takes an explicit path or a mote directory, and a
bare `monad compile` prints its usage rather than compiling the mote you are
standing in:

```bash
monad check --workspace
monad test src/main.mo
monad compile cli/src/main.mo
```

A file with no `mote.toml` above it is a **script module**: it declares the
mote it belongs to inline, with a file-level `#![mote { … }]` annotation whose
`deps` are validated the way a manifest's are.

```monad
#![mote { name := "structs", deps := [init, std] }]
```

Three keys are accepted: `name`, `deps` and `libs` (the last mirroring a
manifest's `[link] libs`). Anything else is an `unknown_mote_key_error` — an
inline annotation never silently swallows a misspelled key.

There is still no search-path *flag*; that belongs to the
[bootstrap host](./bootstrap-host.md#packages-motes). Resolution itself does
have an install root, though — tier 3 above — because a mote in its own
repository has no checkout to read `init`/`std` out of: the directory
`$MONAD_ROOT` names, else `$MONAD_HOME/downloads/<tag>` for the tag in
`$MONAD_HOME/active` (`$MONAD_HOME` defaulting to `$HOME/.monad`). `monadup`
lays a nightly out in exactly that shape; see
[Compiling and testing](./compiling.md) for the install walkthrough.

That root is the *last* tier for modules, not the first, so the candidate table
above can shadow it: a `std/` directory that happens to sit in your working
directory — the compiler's own checkout, most obviously — answers `use std::map`
before an installed root is ever consulted. The C runtime is resolved in the
opposite order (`resolve_runtime_src`, `lang/src/module.mo`), where a declared
`[dependencies.runtime] path` and the installed root both outrank the
working-directory walk. Neither order is an accident: a module path is looked up
by the file doing the `use`, which is what makes the checkout win there, while
the runtime is one file a build either has or does not.

## Visibility

Declarations have three visibility levels:

```monad
pub def exported : I64 := 1        // visible everywhere
priv def internal : I64 := 2       // visible only in this file
def package_private : I64 := 3     // the default
```

The default is package-private. `pub use module {*}` re-exports an import, which
is how the `init` and `std` hubs work.

## Unused Imports

The compiler warns when a name listed in a `use`/`open` is never referenced:

```text
warning: unused import `Path` from `std.path`
```

The [bootstrap host](./bootstrap-host.md#editor-and-agent-tooling) can rewrite
the declarations for you — `monad-rs organize-imports --write` computes the
minimal name list, converts bare `use`/`open` to the explicit form, and deletes
imports that contribute nothing. There is no equivalent in the self-hosted
compiler.

## Complete Example

```monad
use io {IO}
open IO {println}

def say_hello (s : String) : IO Unit := println s

def main (args : List String) : IO Unit :=
    args
        |> List.last
        |> (Option.get_or_default "no arguments")
        |> say_hello
```

## Summary

- Each `.mo` file is a module; a `use` path uses `::` between segments
- `use Module {names}` loads a module; `open Module {names}` drops the prefix
- `{*}` imports everything; bare `use`/`open` is deprecated
- `init/` is pure and portable, `std/` is OS-specific
- Only 12 modules are ambient — most of `std/` needs an explicit import
- Resolution is mote-based: a mote's own root first, the directory cascade only as the script-mode fallback
- `check`/`test` each take explicit paths, `--workspace`, or the mote you are standing in; `compile` takes a file or a mote directory
- A script module names its mote with a leading `#![mote { name := …, deps := […] }]`
- `pub`/`priv`/package-private control visibility

Next, we'll explore **the IO monad** for effectful programming.
