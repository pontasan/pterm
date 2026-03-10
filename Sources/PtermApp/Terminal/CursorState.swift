import Foundation

/// DECSCUSR cursor shapes.
enum CursorShape {
    case block
    case underline
    case bar
}

/// Cursor position and state in the terminal.
struct CursorState {
    /// Row position (0-based from top of active screen)
    var row: Int = 0

    /// Column position (0-based)
    var col: Int = 0

    /// Whether the cursor is visible
    var visible: Bool = true

    /// Cursor shape (DECSCUSR)
    var shape: CursorShape = .block

    /// Whether the cursor blinks (DECSCUSR)
    var blinking: Bool = true

    /// Current attributes applied to new characters
    var attributes: CellAttributes = .default

    /// Origin mode: if true, cursor positioning is relative to scroll region
    var originMode: Bool = false

    /// Auto-wrap mode (DECAWM): wrap to next line when reaching right margin
    var autoWrapMode: Bool = true

    /// Whether the cursor has passed the right margin and the next printable
    /// character should trigger a wrap. This is the "pending wrap" state.
    var pendingWrap: Bool = false

    /// Saved cursor state (for DECSC/DECRC)
    struct SavedState {
        var row: Int
        var col: Int
        var attributes: CellAttributes
        var originMode: Bool
        var autoWrapMode: Bool
        var shape: CursorShape
        var blinking: Bool
    }

    var savedState: SavedState?

    /// Save current cursor state (DECSC)
    mutating func save() {
        savedState = SavedState(
            row: row,
            col: col,
            attributes: attributes,
            originMode: originMode,
            autoWrapMode: autoWrapMode,
            shape: shape,
            blinking: blinking
        )
    }

    /// Restore saved cursor state (DECRC)
    mutating func restore() {
        guard let saved = savedState else { return }
        row = saved.row
        col = saved.col
        attributes = saved.attributes
        originMode = saved.originMode
        autoWrapMode = saved.autoWrapMode
        shape = saved.shape
        blinking = saved.blinking
        pendingWrap = false
    }

    /// Clamp cursor position within given bounds
    mutating func clamp(rows: Int, cols: Int) {
        row = max(0, min(row, rows - 1))
        col = max(0, min(col, cols - 1))
        pendingWrap = false
    }
}
