// The moon mote's library root -- bare `use moon` resolves here.
//
// Deliberately EMPTY for now, for the reason motes/http/src/lib.mo gives
// at length: `router`, `middleware` and `server` declare nothing `pub`, so
// a surface here would be a list of names that only work by package-
// private crossing -- a warning today, an error later -- and it would
// settle which names are the mote's API before anyone has.
//
// What the file buys is what the gate needs: the mote has a target, so
// `use moon` resolves and the workspace has no non-compliant member.
