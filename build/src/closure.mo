/// The input hash: a mote, everything it declares, and the compiler.
///
/// This is the cache key. Every input that can change a result has to be
/// in it, and the ones that cannot must stay out -- a key that moves when
/// nothing meaningful moved costs a rebuild, but a key that DOESN'T move
/// when something did serves a stale answer, which is the failure a build
/// cache must not have.

use io {IO}
use std::list {contains_by, intercalate}
use std::sha256 {}
use lang::mote {discover}
use lib::hash {DigestTool, probe_digest_tool, tree_digest_with}
use lib::identity {compiler_digest_with}

/// The declared dependency directories of the mote at `dir`, paired with
/// its own name, or `none` when `dir` is not inside a mote.
///
/// Entries whose `path` was absent are skipped: `MoteManifest.dep_dirs`
/// stores `""` for a dependency that is DECLARED but not LOCATED
/// (lang/src/mote.mo says why that is legal), and there is nothing to
/// digest at an empty path.
#[partial]
def Build.mote_facts (dir : String) : IO (Option (Pair String (List String))) := do {
    let m <- Mote.discover dir;
    match m {
        Option.none => return Option.none,
        Option.some manifest =>
            return (Option.some (Pair.pair manifest.name (Build.located_dirs manifest.dep_dirs)))
    }
}

#[partial]
def Build.located_dirs (entries : List (Pair String String)) : List String :=
    match entries {
        List.empty => List.empty,
        List.cons e rest => List.append (Build.located_dir e) (Build.located_dirs rest)
    }

def Build.located_dir (e : Pair String String) : List String :=
    match e { Pair.pair _name d => if String.is_empty d then List.empty else [d] }

/// One line per mote: its NAME and its tree digest.
///
/// The name and not the directory, deliberately. The digest has to be
/// path-independent (see `Build.digest_script`), and putting the path
/// back in here would undo that -- two worktrees of the same commit
/// would key differently and could never share an entry.
def Build.closure_line (name : String) (digest : String) : String :=
    String.concat name (String.concat " " digest)

/// Digest a mote and its transitive declared dependencies.
///
/// **Cycles are real here, not hypothetical.** `init/mote.toml` declares
/// `std` as a DEV-dependency while `std/mote.toml` declares `init`, and
/// `MoteManifest` merges the two dependency tables into one `deps`/
/// `dep_dirs` pair (lang/src/mote.mo explains why it merges them), so
/// `init -> std -> init` is a genuine cycle in the graph this walks. The
/// visited set is load-bearing; without it this does not terminate.
///
/// Order is visit order, which is deterministic for a given root: the
/// frontier is extended from `dep_dirs`, which comes from
/// `BTreeMap.to_list` and is therefore sorted by mote name. Same root and
/// same manifests give the same order, which is all a key needs.
#[partial]
pub def Build.closure_digest_with (tool : DigestTool) (dir : String) : IO (Result String String) := do {
    let r <- Build.closure_walk tool [dir] List.empty List.empty;
    match r {
        err m => return (err m),
        ok parts => return (ok (Sha256.hash (List.intercalate "\n" parts)))
    }
}

#[partial]
def Build.closure_walk (tool : DigestTool) (pending : List String) (seen : List String) (acc : List String) : IO (Result String (List String)) :=
    match pending {
        List.empty => return (ok acc),
        List.cons d rest => Build.closure_consider tool d rest seen acc
    }

/// Identity is the mote NAME, not the directory string.
///
/// This is not a style preference, it is the difference between
/// terminating and not. `MoteManifest.dep_dirs` joins a dependency's
/// relative `path` onto the IMPORTER's own directory
/// (`raw_path_join mote_dir path`, lang/src/mote.mo:398), so walking a
/// cycle produces `<r>/a/../b`, then `<r>/a/../b/../a`, then
/// `<r>/a/../b/../a/../b` -- every hop a textually DIFFERENT string for
/// the same two motes. A visited set keyed on the path therefore never
/// matches and the walk recurses until the stack goes.
///
/// Found by `test_closure_terminates_on_a_cycle`, which overflowed the
/// interpreter's stack on the first run. The visited set was present and
/// looked sufficient; it was keyed on the wrong thing.
///
/// A mote name is unique within a closure by construction: two
/// directories claiming the same name is the version conflict
/// package-system's diamond rule already rejects. A directory outside any
/// mote keys on its path instead, which is safe because it contributes no
/// edges to follow.
def Build.closure_key (d : String) (facts : Option (Pair String (List String))) : String :=
    match facts {
        Option.some p => Build.facts_name p,
        Option.none => d,
    }

def Build.facts_name (p : Pair String (List String)) : String :=
    match p { Pair.pair name _deps => name }

def Build.facts_deps (p : Pair String (List String)) : List String :=
    match p { Pair.pair _name deps => deps }

#[partial]
def Build.closure_consider (tool : DigestTool) (d : String) (rest : List String) (seen : List String) (acc : List String) : IO (Result String (List String)) := do {
    let facts <- Build.mote_facts d;
    let key : String := Build.closure_key d facts;
    if List.contains_by String.beq key seen
    then Build.closure_walk tool rest seen acc
    else Build.closure_visit tool d rest seen acc key facts
}

#[partial]
def Build.closure_visit (tool : DigestTool) (d : String) (rest : List String) (seen : List String) (acc : List String) (key : String) (facts : Option (Pair String (List String))) : IO (Result String (List String)) := do {
    let dg <- Build.tree_digest_with tool d;
    match dg {
        err m => return (err m),
        ok h => match facts {
            // Not a mote: digest the tree, contribute it anonymously, and
            // walk no further. This is the bare-file case -- a script
            // module's directory has no manifest to read deps from.
            Option.none =>
                Build.closure_walk tool rest (List.cons key seen)
                    (List.append acc [Build.closure_line "" h]),
            Option.some p =>
                Build.closure_walk tool (List.append rest (Build.facts_deps p))
                    (List.cons key seen)
                    (List.append acc [Build.closure_line (Build.facts_name p) h])
        }
    }
}

/// The full input hash for a build: the source closure, the compiler that
/// would compile it, the profile, and the target triple.
///
/// `profile` distinguishes a debug build from a release one; `triple` is
/// here from the start even though only one value is reachable today
/// (phase 4 varies it), because adding it later would invalidate every
/// entry written before it -- cheaper to include a constant now than to
/// migrate a store.
///
/// An `err` from either digest propagates, and the caller's contract is
/// to DISABLE the cache on it rather than substitute a weaker key.
#[partial]
pub def Build.input_hash (dir : String) (profile : String) (triple : String) : IO (Result String String) := do {
    let t <- Build.probe_digest_tool;
    match t {
        err m => return (err m),
        ok tool => Build.input_hash_with tool dir profile triple
    }
}

#[partial]
pub def Build.input_hash_with (tool : DigestTool) (dir : String) (profile : String) (triple : String) : IO (Result String String) := do {
    let closure <- Build.closure_digest_with tool dir;
    match closure {
        err m => return (err m),
        ok c => do {
            let comp <- Build.compiler_digest_with tool;
            match comp {
                err m => return (err m),
                ok k => return (ok (Sha256.hash (List.intercalate "\n" [c, k, profile, triple])))
            }
        }
    }
}
