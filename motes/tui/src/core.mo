// Terminal UI Library - Core Types
//
// This module defines the fundamental types for the tui library:
// - Rect: A rectangular area of the terminal
// - Cell: A single character cell with styling
// - TextStyle: Text styling (colors plus attribute flags)
// - Screen: A 2D grid of cells representing the terminal buffer
// - Event: Terminal input events (keyboard, mouse, resize)
// - Key: Keyboard input
// - MouseEvent: Mouse input
// - MouseButton: Mouse buttons

// `Color` and the SGR-code builders come from `std::ansi`. They used to be
// copied in here, because this module's style type was also called `Style` and
// `std::ansi`'s attribute-only `type Style` defeated it once both were loaded:
// in the flattened whole-program namespace a `{ ... }` struct literal resolved
// against the UNION of the two types' constructors and was rejected. Calling
// this one `TextStyle` removes the collision outright, and with it the reason
// for the copy.
use std::ansi { Color, color_fg_code, color_bg_code }

/// A rectangular area of the terminal
pub struct Rect {
    x: I64,
    y: I64,
    width: I64,
    height: I64
}

def Rect.beq (a b : Rect) : Bool :=
    a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height

instance BEq Rect {
    def beq (a b : Rect) : Bool := Rect.beq a b
}

/// A composable text style: colors plus attribute flags. Unlike
/// `ansi.Modifier` (which represents a single fg/bg/style/reset code), a
/// `TextStyle` can express e.g. bold *and* a foreground color at the same time.
pub struct TextStyle {
    fg: Option Color := none,
    bg: Option Color := none,
    bold: Bool := false,
    dim: Bool := false,
    italic: Bool := false,
    underline: Bool := false,
    strikethrough: Bool := false
}

/// The style with no colors or attributes set.
//
// Fields are listed explicitly (not `{ }`) to work around a compiler bug:
// a struct literal that omits any field with a default value currently
// panics the checker (`raise_core.rs`, "Free(Atom(_)) is missing from
// atom_paths") instead of substituting the default.
pub def style_default : TextStyle :=
    { fg := none, bg := none, bold := false, dim := false, italic := false, underline := false, strikethrough := false }

/// Layer `top` on top of `base`: colors in `top` win when set, otherwise
/// `base`'s colors are kept; attribute flags are OR'd together.
pub def style_merge (base : TextStyle) (top : TextStyle) : TextStyle :=
    {
        fg := option_or top.fg base.fg,
        bg := option_or top.bg base.bg,
        bold := base.bold || top.bold,
        dim := base.dim || top.dim,
        italic := base.italic || top.italic,
        underline := base.underline || top.underline,
        strikethrough := base.strikethrough || top.strikethrough
    }

/// `preferred` if set, else `fallback`.
def option_or (preferred : Option A) (fallback : Option A) : Option A :=
    match preferred {
        some _ => preferred,
        none => fallback
    }

def option_map (f : A -> B) (opt : Option A) : Option B :=
    match opt {
        some x => Option.some (f x),
        none => Option.none
    }

def bool_code (flag : Bool) (code : String) : Option String :=
    if flag then Option.some code else Option.none

/// Append `next`'s SGR code onto `acc`, `;`-separated, skipping `none`.
def append_code (acc : String) (next : Option String) : String :=
    match next {
        none => acc,
        some code => if acc == "" then code else acc ++ ";" ++ code
    }

/// Renders a `TextStyle` as a single combined ANSI SGR escape sequence, e.g.
/// bold + red fg => `"\u{1b}[31;1m"` -- colors first, then the attribute
/// flags, in the order the codes are appended below. Returns `""` when
/// nothing is set, which means a caller EMITTING this to a terminal has to
/// send its own reset; see `render.mo`'s `apply_one`.
pub def style_to_ansi (s : TextStyle) : String :=
    let c0 := append_code "" (option_map color_fg_code s.fg) in
    let c1 := append_code c0 (option_map color_bg_code s.bg) in
    let c2 := append_code c1 (bool_code s.bold "1") in
    let c3 := append_code c2 (bool_code s.dim "2") in
    let c4 := append_code c3 (bool_code s.italic "3") in
    let c5 := append_code c4 (bool_code s.underline "4") in
    let codes := append_code c5 (bool_code s.strikethrough "9") in
    if codes == "" then "" else "\u{1b}[" ++ codes ++ "m"

/// Compares `Option Color` fields by hand rather than via the generic
/// `[BEq A] BEq (Option A)` instance: that generic instance doesn't dispatch
/// to a custom `A`'s `BEq` instance correctly at runtime (a pre-existing
/// evaluator limitation — see the equivalent note in `lang/json.mo`).
def option_color_beq (a b : Option Color) : Bool :=
    match a {
        some ca => match b {
            some cb => Color.beq ca cb,
            none => false
        },
        none => match b {
            none => true,
            some _ => false
        }
    }

def TextStyle.beq (a b : TextStyle) : Bool :=
    option_color_beq a.fg b.fg
    && option_color_beq a.bg b.bg
    && a.bold == b.bold
    && a.dim == b.dim
    && a.italic == b.italic
    && a.underline == b.underline
    && a.strikethrough == b.strikethrough

instance BEq TextStyle {
    def beq (a b : TextStyle) : Bool := TextStyle.beq a b
}

/// A single character cell with styling
pub struct Cell {
    char: String,
    style: TextStyle
}

def Cell.beq (a b : Cell) : Bool :=
    a.char == b.char && TextStyle.beq a.style b.style

instance BEq Cell {
    def beq (a b : Cell) : Bool := Cell.beq a b
}

/// Layout size constraints for flexible sizing
pub type LayoutSize {
    /// Fixed size in units
    fixed (n : I64),
    /// Fill available space, optionally with a weight
    fill (weight : I64),
    /// Minimum size
    min (n : I64),
    /// Maximum size
    max (n : I64)
}

def LayoutSize.beq (a b : LayoutSize) : Bool :=
    match a {
        fixed na => match b { fixed nb => na == nb, _ => false },
        fill wa => match b { fill wb => wa == wb, _ => false },
        min na => match b { min nb => na == nb, _ => false },
        max na => match b { max nb => na == nb, _ => false }
    }

instance BEq LayoutSize {
    def beq (a b : LayoutSize) : Bool := LayoutSize.beq a b
}

/// Mouse buttons
pub type MouseButton {
    left,
    right,
    middle,
    scroll_up,
    scroll_down
}

def MouseButton.beq (a b : MouseButton) : Bool :=
    match a {
        left => match b { left => true, _ => false },
        right => match b { right => true, _ => false },
        middle => match b { middle => true, _ => false },
        scroll_up => match b { scroll_up => true, _ => false },
        scroll_down => match b { scroll_down => true, _ => false }
    }

instance BEq MouseButton {
    def beq (a b : MouseButton) : Bool := MouseButton.beq a b
}

/// Keyboard keys
pub type Key {
    /// A regular character key
    char (c : String),
    /// Enter/Return key
    enter,
    /// Tab key
    tab,
    /// Backspace key
    backspace,
    /// Escape key
    escape,
    /// Arrow keys
    up,
    down,
    left,
    right,
    /// Navigation keys
    home,
    end,
    page_up,
    page_down,
    /// Edit keys
    delete,
    insert,
    /// Function keys (F1-F12). Spelled out rather than `f`: a one-letter
    /// constructor in a whole-program namespace shadows same-named locals
    /// everywhere, and this one used to break `init/src/io.mo`'s
    /// `Monad IO`.bind (`match a { io a => f a }`) into a constructor
    /// application -- silently stopping every `do` block in any program
    /// that loaded this module. Fixed in the compiler
    /// (`try_compile_constructor_app_db`, pinned by
    /// `slow_tests/src/codegen_ctor_shadows_param_tests.mo`), so the name
    /// is now a choice rather than a workaround -- but it keeps this mote
    /// usable on a toolchain that predates the fix.
    function_key (n : I64),
    /// Control + character
    ctrl (c : String),
    /// Alt + character
    alt (c : String)
}

def Key.beq (a b : Key) : Bool :=
    match a {
        char ca => match b { char cb => ca == cb, _ => false },
        enter => match b { enter => true, _ => false },
        tab => match b { tab => true, _ => false },
        backspace => match b { backspace => true, _ => false },
        escape => match b { escape => true, _ => false },
        up => match b { up => true, _ => false },
        down => match b { down => true, _ => false },
        left => match b { left => true, _ => false },
        right => match b { right => true, _ => false },
        home => match b { home => true, _ => false },
        end => match b { end => true, _ => false },
        page_up => match b { page_up => true, _ => false },
        page_down => match b { page_down => true, _ => false },
        delete => match b { delete => true, _ => false },
        insert => match b { insert => true, _ => false },
        function_key na => match b { function_key nb => na == nb, _ => false },
        ctrl ca => match b { ctrl cb => ca == cb, _ => false },
        alt ca => match b { alt cb => ca == cb, _ => false }
    }

instance BEq Key {
    def beq (a b : Key) : Bool := Key.beq a b
}

/// Mouse events
pub type MouseEvent {
    /// Mouse button pressed at position
    press (button : MouseButton) (row : I64) (col : I64),
    /// Mouse button released at position
    release (button : MouseButton) (row : I64) (col : I64),
    /// Mouse drag (button held down and moved)
    drag (button : MouseButton) (row : I64) (col : I64),
    /// Mouse wheel scroll up
    scroll_up (row : I64) (col : I64),
    /// Mouse wheel scroll down
    scroll_down (row : I64) (col : I64)
}

def MouseEvent.beq (a b : MouseEvent) : Bool :=
    match a {
        press ba ra ca => match b {
            press bb rb cb => MouseButton.beq ba bb && ra == rb && ca == cb,
            _ => false
        },
        release ba ra ca => match b {
            release bb rb cb => MouseButton.beq ba bb && ra == rb && ca == cb,
            _ => false
        },
        drag ba ra ca => match b {
            drag bb rb cb => MouseButton.beq ba bb && ra == rb && ca == cb,
            _ => false
        },
        scroll_up ra ca => match b {
            scroll_up rb cb => ra == rb && ca == cb,
            _ => false
        },
        scroll_down ra ca => match b {
            scroll_down rb cb => ra == rb && ca == cb,
            _ => false
        }
    }

instance BEq MouseEvent {
    def beq (a b : MouseEvent) : Bool := MouseEvent.beq a b
}

/// Terminal events
pub type Event {
    /// Key press event
    key (k : Key),
    /// Mouse event
    mouse (m : MouseEvent),
    /// Terminal resize event
    resize (rows : I64) (cols : I64),
    /// Tick event (frame update)
    tick
}

def Event.beq (a b : Event) : Bool :=
    match a {
        key ka => match b { key kb => Key.beq ka kb, _ => false },
        mouse ma => match b { mouse mb => MouseEvent.beq ma mb, _ => false },
        resize ra ca => match b { resize rb cb => ra == rb && ca == cb, _ => false },
        tick => match b { tick => true, _ => false }
    }

instance BEq Event {
    def beq (a b : Event) : Bool := Event.beq a b
}

/// The screen buffer — a 2D grid of cells represented as a list of rows
pub struct Screen {
    rows: I64,
    cols: I64,
    row_cells: List (List Cell)
}

/// Hand-rolled (not generic `BEq (List A)`) for the same reason as
/// `option_color_beq` above — dispatch to a custom element type's `BEq`
/// instance through the generic `List`/`Option` instances is unreliable.
def cell_list_beq (a b : List Cell) : Bool :=
    match a {
        empty => match b { empty => true, _ => false },
        cons ha ta => match b {
            cons hb tb => Cell.beq ha hb && cell_list_beq ta tb,
            _ => false
        }
    }

def row_list_beq (a b : List (List Cell)) : Bool :=
    match a {
        empty => match b { empty => true, _ => false },
        cons ha ta => match b {
            cons hb tb => cell_list_beq ha hb && row_list_beq ta tb,
            _ => false
        }
    }

def Screen.beq (a b : Screen) : Bool :=
    a.rows == b.rows && a.cols == b.cols && row_list_beq a.row_cells b.row_cells

instance BEq Screen {
    def beq (a b : Screen) : Bool := Screen.beq a b
}

/// A delta representing a change to a single cell
pub type CellDelta {
    /// Position of the cell to change
    set (row : I64) (col : I64) (cell : Cell),
    /// Clear a cell (set to default/empty)
    clear (row : I64) (col : I64)
}

def CellDelta.beq (a b : CellDelta) : Bool :=
    match a {
        set ra ca cella => match b {
            set rb cb cellb => ra == rb && ca == cb && Cell.beq cella cellb,
            _ => false
        },
        clear ra ca => match b {
            clear rb cb => ra == rb && ca == cb,
            _ => false
        }
    }

instance BEq CellDelta {
    def beq (a b : CellDelta) : Bool := CellDelta.beq a b
}

// ==================== Helper Functions ====================

/// Create a list by replicating a value n times
#[terminating]
def List.replicate (n : I64) (value : A) : List A :=
    if n < 1
    then List.empty
    else List.cons value (List.replicate (n - 1) value)

/// Create a list of lists (2D) by replicating a value for rows x cols
#[terminating]
def screen_cells (rows : I64) (cols : I64) (value : Cell) : List (List Cell) :=
    if rows < 1
    then List.empty
    else List.cons (List.replicate cols value) (screen_cells (rows - 1) cols value)

/// Create an empty screen of given dimensions
pub def empty_screen (rows : I64) (cols : I64) : Screen :=
    let default_cell := mk_cell " " in
    { rows := rows, cols := cols, row_cells := screen_cells rows cols default_cell }

/// Create a cell with the given character and default style
pub def mk_cell (char : String) : Cell :=
    { char := char, style := style_default }

/// Replace the element at `index` (0-indexed); unchanged if out of range.
/// Index-first to match `List.get`.
def List.set_at {A : Type} (index : I64) (value : A) (l : List A) : List A :=
    match l {
        empty => List.empty,
        cons head tail =>
            if index == 0
            then List.cons value tail
            else List.cons head (List.set_at (index - 1) value tail)
    }

/// Get the cell at a specific position
pub def screen_get_cell (screen : Screen) (row : I64) (col : I64) : Option Cell :=
    if row < 0 || Bool.not (row < screen.rows) || col < 0 || Bool.not (col < screen.cols)
    then Option.none
    else
        match List.get row screen.row_cells {
            some cells => List.get col cells,
            none => Option.none
        }

/// Set the cell at a specific position
pub def screen_set_cell (screen : Screen) (row : I64) (col : I64) (cell : Cell) : Screen :=
    if row < 0 || Bool.not (row < screen.rows) || col < 0 || Bool.not (col < screen.cols)
    then screen
    else
        let current_row := Option.get_or_default List.empty (List.get row screen.row_cells) in
        let new_row := List.set_at col cell current_row in
        let new_rows := List.set_at row new_row screen.row_cells in
        { screen with row_cells := new_rows }

/// Check if two rectangles intersect
pub def rect_intersects (a : Rect) (b : Rect) : Bool :=
    a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y

/// Check if a rectangle contains a point
pub def rect_contains (r : Rect) (x : I64) (y : I64) : Bool :=
    Bool.not (x < r.x) && x < r.x + r.width && Bool.not (y < r.y) && y < r.y + r.height

/// Clamp a value between min and max
def clamp (value : I64) (min : I64) (max : I64) : I64 :=
    if value < min then min else if value > max then max else value

/// Create a rectangle from position and size
pub def mk_rect (x : I64) (y : I64) (w : I64) (h : I64) : Rect :=
    { x := x, y := y, width := w, height := h }

/// Create a screen of given dimensions
pub def mk_screen (rows : I64) (cols : I64) : Screen :=
    empty_screen rows cols

// ==================== Tests ====================

#[test]
def test_rect_intersects_true : Bool :=
    rect_intersects (mk_rect 0 0 10 10) (mk_rect 5 5 10 10)

#[test]
def test_rect_intersects_false : Bool :=
    Bool.not (rect_intersects (mk_rect 0 0 10 10) (mk_rect 20 20 5 5))

#[test]
def test_rect_contains_inside : Bool :=
    rect_contains (mk_rect 0 0 10 10) 5 5

#[test]
def test_rect_contains_edge_excluded : Bool :=
    Bool.not (rect_contains (mk_rect 0 0 10 10) 10 10)

#[test]
def test_clamp_within_range : Bool :=
    clamp 5 0 10 == 5

#[test]
def test_clamp_below_min : Bool :=
    clamp (0 - 5) 0 10 == 0

#[test]
def test_clamp_above_max : Bool :=
    clamp 15 0 10 == 10

#[test]
def test_mk_screen_in_range_cell_is_space : Bool :=
    match screen_get_cell (mk_screen 3 4) 0 0 {
        some cell => cell.char == " ",
        none => false
    }

#[test]
def test_screen_get_cell_row_out_of_range_is_none : Bool :=
    match screen_get_cell (mk_screen 3 4) 3 0 {
        some _ => false,
        none => true
    }

#[test]
def test_screen_get_cell_negative_index_is_none : Bool :=
    match screen_get_cell (mk_screen 3 4) (0 - 1) 0 {
        some _ => false,
        none => true
    }

#[test]
def test_screen_set_get_roundtrip : Bool :=
    let screen := screen_set_cell (mk_screen 2 2) 0 1 (mk_cell "x") in
    match screen_get_cell screen 0 1 {
        some cell => cell.char == "x",
        none => false
    }

#[test]
def test_screen_set_cell_does_not_affect_other_cells : Bool :=
    let screen := screen_set_cell (mk_screen 2 2) 0 1 (mk_cell "x") in
    match screen_get_cell screen 0 0 {
        some cell => cell.char == " ",
        none => false
    }

#[test]
def test_style_merge_fg_override_wins : Bool :=
    let base : TextStyle := { style_default with bold := true } in
    let top : TextStyle := { style_default with fg := some Color.red, dim := true } in
    let merged : TextStyle := style_merge base top in
    match merged.fg {
        some c => c == Color.red,
        none => false
    }

#[test]
def test_style_merge_bools_are_ored : Bool :=
    let base : TextStyle := { style_default with bold := true } in
    let top : TextStyle := { style_default with dim := true } in
    let merged : TextStyle := style_merge base top in
    merged.bold && merged.dim

#[test]
def test_style_merge_keeps_base_fg_when_top_unset : Bool :=
    let base : TextStyle := { style_default with fg := some Color.green } in
    let merged : TextStyle := style_merge base style_default in
    match merged.fg {
        some c => c == Color.green,
        none => false
    }

#[test]
def test_style_to_ansi_empty_style_is_empty_string : Bool :=
    style_to_ansi style_default == ""

#[test]
def test_style_to_ansi_bold_red_combines_one_sequence : Bool :=
    // The `: TextStyle` annotation is load-bearing: a struct-update
    // `{ x with f := v }` whose result flows into `style_to_ansi` + a String
    // `==` fails to infer its type and lowers as `UnresolvedAtom`. An
    // annotation, a match scrutinee, or `style_merge` consumption all avoid
    // it.
    let s : TextStyle := { style_default with fg := some Color.red, bold := true } in
    style_to_ansi s == "\u{1b}[31;1m"

// ==================== Phase 1b regression tests ====================
// BEq smoke tests for the hand-rolled instances (the `#[derive BEq]`
// migration is still blocked by compiler bugs, so these guard the
// hand-rolled `instance BEq T` declarations instead). The nested-concrete-field
// cases (Cell nesting TextStyle, MouseEvent nesting MouseButton, Event
// nesting Key, CellDelta nesting Cell) exercise dispatch through a
// concrete named type's own `BEq` instance.

#[test]
def test_beq_rect : Bool :=
    mk_rect 0 0 10 10 == mk_rect 0 0 10 10
    && Bool.not (mk_rect 0 0 10 10 == mk_rect 0 0 10 11)

#[test]
def test_beq_cell_nested_style : Bool :=
    let base := mk_cell "x" in
    let bold_on : TextStyle := { style_default with bold := true } in
    let bold_off : TextStyle := { style_default with bold := false } in
    let c1 : Cell := { base with style := bold_on } in
    let c2 : Cell := { base with style := bold_on } in
    let c3 : Cell := { base with style := bold_off } in
    c1 == c2 && Bool.not (c1 == c3)

#[test]
def test_beq_layout_size : Bool :=
    LayoutSize.fixed 3 == LayoutSize.fixed 3
    && Bool.not (LayoutSize.fixed 3 == LayoutSize.fill 3)

#[test]
def test_beq_mouse_button : Bool :=
    MouseButton.left == MouseButton.left
    && Bool.not (MouseButton.left == MouseButton.right)

#[test]
def test_beq_key : Bool :=
    Key.char "a" == Key.char "a"
    && Bool.not (Key.char "a" == Key.char "b")
    && Key.enter == Key.enter

#[test]
def test_beq_mouse_event : Bool :=
    MouseEvent.press MouseButton.left 0 0 == MouseEvent.press MouseButton.left 0 0
    && Bool.not (MouseEvent.press MouseButton.left 0 0 == MouseEvent.press MouseButton.right 0 0)

#[test]
def test_beq_event : Bool :=
    Event.key (Key.char "a") == Event.key (Key.char "a")
    && Bool.not (Event.key (Key.char "a") == Event.key (Key.char "b"))
    && Event.tick == Event.tick

#[test]
def test_beq_cell_delta : Bool :=
    CellDelta.set 0 0 (mk_cell "x") == CellDelta.set 0 0 (mk_cell "x")
    && Bool.not (CellDelta.set 0 0 (mk_cell "x") == CellDelta.set 0 0 (mk_cell "y"))
    && CellDelta.clear 0 0 == CellDelta.clear 0 0

#[test]
def test_beq_style_handrolled : Bool :=
    let bold_on : TextStyle := { style_default with bold := true } in
    let red_fg : TextStyle := { style_default with fg := some Color.red } in
    let green_fg : TextStyle := { style_default with fg := some Color.green } in
    style_default == style_default
    && Bool.not (bold_on == style_default)
    && red_fg == red_fg
    && Bool.not (red_fg == green_fg)

#[test]
def test_beq_screen_handrolled : Bool :=
    mk_screen 2 2 == mk_screen 2 2
    && Bool.not (mk_screen 2 2 == mk_screen 2 3)
    && Bool.not (screen_set_cell (mk_screen 2 2) 0 0 (mk_cell "x") == mk_screen 2 2)
