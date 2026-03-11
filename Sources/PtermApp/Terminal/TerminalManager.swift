import Foundation

/// Manages multiple terminal sessions.
///
/// Provides thread-safe add/remove operations and tracks the active terminal.
/// The integrated view observes this manager to display thumbnails.
final class TerminalManager {
    private var config: PtermConfig

    /// All active terminal controllers, in display order.
    private(set) var terminals: [TerminalController] = []

    /// Callback when the terminal list changes (add/remove).
    var onListChanged: (() -> Void)?

    /// Default terminal grid dimensions (full-size, used for PTY).
    /// These remain constant regardless of whether the terminal is
    /// displayed as a thumbnail or occupying the full window.
    private(set) var fullRows: Int
    private(set) var fullCols: Int

    init(rows: Int, cols: Int, config: PtermConfig) {
        self.fullRows = rows
        self.fullCols = cols
        self.config = config
    }

    func updateConfiguration(_ config: PtermConfig) {
        self.config = config
    }

    /// Update the full-size dimensions and resize all terminals.
    ///
    /// Per spec, all terminals maintain the same grid dimensions as when
    /// occupying the full window. This ensures no PTY resize or reflow
    /// occurs when switching between integrated and focused views.
    func updateFullSize(rows: Int, cols: Int) {
        guard rows != fullRows || cols != fullCols else { return }
        self.fullRows = rows
        self.fullCols = cols
        for terminal in terminals {
            terminal.resize(rows: rows, cols: cols)
        }
    }

    /// Create and add a new terminal session. Returns the new controller.
    @discardableResult
    func addTerminal(initialDirectory: String? = nil,
                     customTitle: String? = nil,
                     workspaceName: String = "Uncategorized",
                     textEncoding: TerminalTextEncoding? = nil,
                     fontName: String,
                     fontSize: Double,
                     id: UUID = UUID(),
                     configure: ((TerminalController) -> Void)? = nil) throws -> TerminalController {
        let scrollbackPath = config.sessionScrollBufferPersistence
            ? Self.scrollbackPath(for: id).path
            : nil
        let controller = TerminalController(
            rows: fullRows,
            cols: fullCols,
            termEnv: config.term,
            textEncoding: textEncoding ?? config.textEncoding,
            scrollbackInitialCapacity: config.memoryInitial,
            scrollbackMaxCapacity: config.memoryMax,
            fontName: fontName,
            fontSize: fontSize,
            initialDirectory: initialDirectory,
            customTitle: customTitle,
            workspaceName: workspaceName,
            id: id,
            scrollbackPersistencePath: scrollbackPath
        )

        // Auto-remove when the terminal exits
        controller.onExit = { [weak self, weak controller] in
            guard let self = self, let controller = controller else { return }
            DispatchQueue.main.async {
                self.removeTerminal(controller)
            }
        }

        configure?(controller)
        terminals.append(controller)
        try controller.start()
        onListChanged?()
        return controller
    }

    /// Remove a terminal session and stop its process.
    func removeTerminal(_ controller: TerminalController, preserveScrollback: Bool = false) {
        controller.stop()
        if !preserveScrollback {
            controller.discardPersistentScrollback()
        }
        terminals.removeAll { $0 === controller }
        onListChanged?()
    }

    /// Stop all terminals.
    func stopAll(preserveScrollback: Bool = false, waitForExit: Bool = false) {
        for t in terminals {
            if !preserveScrollback {
                t.discardPersistentScrollback()
            }
            t.onExit = nil
            t.stop(waitForExit: waitForExit)
        }
        terminals.removeAll()
    }

    /// Reorder a terminal within the global terminals array.
    func moveTerminal(_ controller: TerminalController, toIndex: Int) {
        guard let fromIndex = terminals.firstIndex(where: { $0 === controller }),
              toIndex != fromIndex else { return }
        terminals.remove(at: fromIndex)
        let clampedIndex = min(toIndex, terminals.count)
        terminals.insert(controller, at: clampedIndex)
        onListChanged?()
    }

    /// Reorder a terminal to a specific position within a workspace.
    /// The `wsIndex` is the desired position among terminals of the target workspace.
    func reorderTerminal(_ controller: TerminalController, toWorkspace workspace: String, atIndex wsIndex: Int) {
        guard let fromIndex = terminals.firstIndex(where: { $0 === controller }) else { return }
        terminals.remove(at: fromIndex)

        // Find terminals in the target workspace (after removal)
        let wsTerminals = terminals.filter { $0.sessionSnapshot.workspaceName == workspace }

        let globalIndex: Int
        if wsIndex >= wsTerminals.count {
            // Insert after the last terminal of the workspace
            if let last = wsTerminals.last, let lastIdx = terminals.firstIndex(where: { $0 === last }) {
                globalIndex = lastIdx + 1
            } else {
                // Workspace is empty; find insertion point based on workspace ordering
                globalIndex = terminals.count
            }
        } else {
            // Insert before the terminal at wsIndex
            let anchor = wsTerminals[wsIndex]
            globalIndex = terminals.firstIndex(where: { $0 === anchor }) ?? terminals.count
        }

        terminals.insert(controller, at: min(globalIndex, terminals.count))
        onListChanged?()
    }

    /// Number of active terminals.
    var count: Int { terminals.count }

    /// Compute grid layout dimensions for N terminals.
    /// Returns (columns, rows) for the grid layout.
    static func gridLayout(for count: Int) -> (cols: Int, rows: Int) {
        guard count > 0 else { return (1, 1) }
        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        return (cols, rows)
    }

    private static func scrollbackPath(for id: UUID) -> URL {
        PtermDirectories.sessionScrollback.appendingPathComponent("\(id.uuidString).bin")
    }
}
