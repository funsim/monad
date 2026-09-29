// The parse-error vector, and the only fixture here whose offsets differ between the two
// negotiated position encodings.
//
// THIS COMMENT IS DELIBERATELY ASCII, and the code line below is the only line in this
// file carrying non-ASCII bytes -- so the offending byte's offset is unambiguous and the
// hand-computed table in fixtures/lsp/README.md can be checked by eye.
//
// The em dash (U+2014) is THREE bytes in utf-8 and ONE code unit in utf-16. It sits on
// the offending line BEFORE the byte the parser gives up at, so the two encodings
// disagree about that byte's column by exactly two. A diagnostic whose position lands on
// a line boundary would agree under both encodings and test nothing, which is why the
// vector is a parse error -- positioned by the offset the parser stopped at, mid-line --
// rather than a type error, whose range is a declaration's whole-line span.
//
// U+00AB is not a byte the parser accepts anywhere, so the parse stops on the first one
// and the single diagnostic's range is that byte's own extent.
def zz_replay_keep : I64 := 1
def zz_replay_broken : String := "a—b" ++ «
