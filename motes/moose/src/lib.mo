// The moose mote's library root -- bare `use moose` resolves here.
//
// Deliberately EMPTY for now, for the reason motes/http/src/lib.mo gives
// at length. This mote is one module (`client.mo`, the HTTP/1.1 client) and
// it declares nothing `pub`, so a surface here would be a list of
// package-private names -- a warning today, an error later -- and it would
// decide the mote's API before anyone has.
//
// What the file buys is that the mote has a target: `use moose` resolves.
