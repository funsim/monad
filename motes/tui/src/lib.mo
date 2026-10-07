// The tui mote's library root -- bare `use tui` resolves here.
//
// Four modules, in the order a frame moves through them: `core` (the value
// types -- a `Rect`, a styled `Cell`, a `Screen` of cells, and the input
// events), `layout` (splitting a `Rect` by `LayoutSize`), `widget` (the
// widget tree and its smart constructors) and `render` (tree -> `Screen` ->
// `CellDelta`s -> one ANSI string).
//
// One type group per module, which is the rule `build/src/lib.mo` set. The
// functions are reached by naming the module (`use tui::render {render}`);
// this file's job is to make `use tui` resolve. No `{*}` globs: a glob here
// would pull four namespaces into every importer's scope.

pub use lib::core {Rect, TextStyle, Cell, LayoutSize, MouseButton, Key, MouseEvent, Event, Screen, CellDelta}
pub use lib::layout {}
pub use lib::widget {BorderStyle, LeafWidget, SizedWidget, DecoratorKind, Widget}
pub use lib::render {BorderChars}
