/// Parse -> pretty-print -> re-parse round-trip tests for the `use`/`open`
/// brace syntax. Moved here from `slow_tests/parser_file_tests.mo`: these
/// parse tiny inline snippets (sub-millisecond each), not real files, so
/// they don't belong in the directory reserved for expensive whole-file
/// parses -- they were just sitting outside the fast pre-commit sweep for
/// no reason.

use lang::types {Decl, ParseDecl}
use lib::parser {open_parser, use_parser}
use lib::parser::lower_parse {lower_parse_decl, lower_ctx_bare}
use parsec::core {ParseResult}
use lib::pretty {show_decl}

open ParseResult {fail, success}

#[partial]
def parse_decl_succeeds (r : ParseResult ParseDecl) : Bool :=
    match r {
        success _ _ => true,
        fail _ => false
    }

#[test]
def test_roundtrip_use_glob : Bool :=
    match use_parser "use init::io {*}" {
        success _ out => parse_decl_succeeds (use_parser (show_decl (lower_parse_decl lower_ctx_bare out))),
        fail _ => false
    }

#[test]
def test_roundtrip_use_nested : Bool :=
    match use_parser "use init::io {file {read}}" {
        success _ out => parse_decl_succeeds (use_parser (show_decl (lower_parse_decl lower_ctx_bare out))),
        fail _ => false
    }

#[test]
def test_roundtrip_use_nested_rename : Bool :=
    match use_parser "use init::io {file as f {read}}" {
        success _ out => parse_decl_succeeds (use_parser (show_decl (lower_parse_decl lower_ctx_bare out))),
        fail _ => false
    }

/// A DOTTED brace item (`{List.length}`) names ONE dotted declaration, not
/// a sub-module -- `use_brace_item_name_dotted` keeps the item whole, so
/// it must survive parse -> print -> re-parse unchanged.
#[test]
def test_roundtrip_use_dotted_item : Bool :=
    match use_parser "use std::list {List.length}" {
        success _ out => parse_decl_succeeds (use_parser (show_decl (lower_parse_decl lower_ctx_bare out))),
        fail _ => false
    }

/// The same, renamed (`{List.length as len}`) -- the `as` arm goes through
/// its own parser entry point, so it needs its own round trip.
#[test]
def test_roundtrip_use_dotted_item_rename : Bool :=
    match use_parser "use std::list {List.length as len}" {
        success _ out => parse_decl_succeeds (use_parser (show_decl (lower_parse_decl lower_ctx_bare out))),
        fail _ => false
    }

/// The sub-module arm still wins over the dotted-name arm when what follows
/// the identifier is a brace list: `file {read}` is a sub-module filter,
/// `List.length` is a name. Both must keep parsing (alt ordering in
/// `use_brace_item`).
#[test]
def test_roundtrip_use_dotted_and_sub_together : Bool :=
    match use_parser "use init::io {file {read}, String.length}" {
        success _ out => parse_decl_succeeds (use_parser (show_decl (lower_parse_decl lower_ctx_bare out))),
        fail _ => false
    }

#[test]
def test_roundtrip_open_filtered : Bool :=

    match open_parser "open io {println}" {
        success _ out => parse_decl_succeeds (open_parser (show_decl (lower_parse_decl lower_ctx_bare out))),
        fail _ => false
    }

#[test]
def test_roundtrip_scoped_open : Bool :=
    match open_parser "open io {println} in def main : IO Unit := println \"hi\"" {
        success _ out => parse_decl_succeeds (open_parser (show_decl (lower_parse_decl lower_ctx_bare out))),
        fail _ => false
    }
