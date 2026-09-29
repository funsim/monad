// The outline and navigation vector: one declaration of every kind the symbol picker
// has a word for, so `documentSymbol` has to answer with all of them, each at a range
// that points at its own declaration.
//
// Pure ASCII on purpose. The encodings differ only for non-ASCII columns, which is
// `nonascii.mo`'s job, and keeping this file ASCII means every position in it is the
// same number in bytes and in code units -- so a cursor here has one spelling and the
// assertions about it cannot be wrong for the interesting reason.
//
// The last two defs are the SHADOWING pin. `\zz_replay_shadowed => zz_replay_shadowed`
// binds a local with the same name as the top-level def above it, and go-to-definition
// on that local's use answers the TOP-LEVEL def: a documented gap (see
// `lang/src/navigation.mo`'s "Locals are not resolved"), inherited from the Rust server
// this one replaces. It is asserted, not wished for, so that implementing the
// cursor-to-binding walk flips a test rather than passing unnoticed.

struct ZzReplayShape {
    width : I64,
    height : I64,
}

type ZzReplayColor {
    zz_replay_red,
    zz_replay_green,
}

class ZzReplayName A {
    def zz_replay_name : A -> String
}

instance ZzReplayName ZzReplayColor {
    def zz_replay_name (c : ZzReplayColor) : String :=
        match c {
            zz_replay_red => "red",
            zz_replay_green => "green",
        }
}

def zz_replay_width (s : ZzReplayShape) : I64 := s.width

def zz_replay_area (s : ZzReplayShape) : I64 := zz_replay_width s

def zz_replay_shadowed : I64 := 7

def zz_replay_shadow_use : (I64 -> I64) :=
    \zz_replay_shadowed => zz_replay_shadowed
