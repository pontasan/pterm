import Foundation

enum AppScrollRowHash {
    /// Hash of a row holding only blank cells.
    static let blank: UInt64 = 0xcbf2_9ce4_8423_25d3

    /// Hash of the text in a row. Attributes are ignored because an application may
    /// restyle a row while scrolling it. Trailing blanks are ignored.
    static func hash<S: Sequence>(cells: S) -> UInt64 where S.Element == Cell {
        var hash = blank
        var pendingBlanks: UInt64 = 0
        for cell in cells {
            if cell.isWideContinuation { continue }
            if cell.codepoint == 0 || cell.codepoint == 0x20 {
                pendingBlanks += 1
                continue
            }
            if pendingBlanks > 0 {
                hash = (hash ^ (pendingBlanks &+ 0x1_0000_0000)) &* 0x100_0000_01b3
                pendingBlanks = 0
            }
            hash = (hash ^ UInt64(cell.codepoint)) &* 0x100_0000_01b3
        }
        return hash
    }
}

/// Keeps a selection attached to its text while a full-screen application scrolls
/// content that only the application holds.
///
/// Applications repaint without telling the terminal what moved, and one repaint reaches
/// the terminal over several reads, so most intermediate states are half old frame and
/// half new frame. Two rules follow from that:
///
/// - The position is never summed from the movement between reads. Each read aligns the
///   screen against the rows seen so far and derives the absolute position, so a
///   half-painted state can only be wrong until the repaint finishes.
/// - Rows are stored only from settled frames. Storing a half-painted frame would put text
///   under the wrong content row, and the store is what every later alignment relies on.
///
/// Rows are stored by content row: `global row - globalShift`. A content row keeps its
/// number wherever the application moves it, including outside the visible frame.
struct AppScrollSelectionTracker {
    struct CapturedRow {
        let cells: [Cell]
        let isWrapped: Bool
    }

    private struct StoredRow {
        var row: CapturedRow
        var hash: UInt64
        /// Seen in the moving part of the screen, so it is scrolled text and not a fixed row.
        var isScrolledText: Bool
    }

    /// Text reached by a jump is numbered beyond `keys`, on the side away from the older text.
    private struct JumpGap {
        var keys: ClosedRange<Int>
        var newerTextIsBelow: Bool

        func holdsNewerText(key: Int) -> Bool {
            newerTextIsBelow ? key < keys.lowerBound : key > keys.upperBound
        }
    }

    private(set) var globalShift = 0
    /// How text on the far side of a jump was renumbered, oldest first.
    private var joins: [(gap: JumpGap, offset: Int)] = []
    var joinCount: Int { joins.count }
    /// Rows of the screen that move. Rows outside it (headers, input boxes) are fixed.
    private(set) var movingBand: Range<Int>?

    private var previousFrame: [UInt64]
    private var previousBaseGlobalRow: Int
    private var shiftBeforeLastMove = 0
    private var frameBeforeLastMove: [UInt64]?
    private var frameAtLastSettle: [UInt64]
    private var overlay: (columns: Range<Int>, cells: [Cell])?
    private var overlayCandidate: (columns: Range<Int>, cells: [Cell], key: Int, original: CapturedRow)?
    private var storedRows: [Int: StoredRow] = [:]
    private var keysByHash: [UInt64: Set<Int>] = [:]
    private var storedLowerBound: Int?
    private var storedUpperBound: Int?
    private var scrolledTextLowerBound: Int?
    private var scrolledTextUpperBound: Int?
    /// Screen rows whose text was replaced in place since the content last moved.
    private var rowsEditedSinceLastMove: Set<Int> = []
    /// Text replaced by the last settled frame on the rows at the edges of the moving band.
    private var overwrittenAtEdges: [Int: (key: Int, stored: StoredRow, by: UInt64)] = [:]
    private var shiftAtLastSettle = 0
    /// Content rows between text that was reached by a jump, whose distance is unknown.
    private var undisplayedKeyRanges: [JumpGap] = []
    private let maximumCapturedRows: Int

    /// `maximumCapturedRows` bounds memory for selections far larger than the screen.
    init(frame: [UInt64],
         baseGlobalRow: Int,
         maximumCapturedRows: Int,
         row: (Int) -> CapturedRow) {
        precondition(maximumCapturedRows >= frame.count, "The capture limit must hold a full frame")
        self.previousFrame = frame
        self.previousBaseGlobalRow = baseGlobalRow
        self.frameAtLastSettle = frame
        self.maximumCapturedRows = maximumCapturedRows
        for gridRow in frame.indices {
            store(StoredRow(row: row(gridRow), hash: frame[gridRow], isScrolledText: false),
                  key: baseGlobalRow + gridRow)
        }
    }

    /// Follows one state of the screen, which may be half painted. `activeRow` is the row
    /// being written (the cursor row), which may hold half a line.
    mutating func follow(frame: [UInt64], baseGlobalRow: Int, activeRow: Int?) {
        precondition(frame.count == previousFrame.count, "Frames must have the same row count")
        let previous = previousFrame
        previousFrame = frame
        defer { previousBaseGlobalRow = baseGlobalRow }
        guard let changed = Self.changedBand(previous: previous, current: frame) else { return }
        joinTextAcrossJump(frame: frame, baseGlobalRow: baseGlobalRow, activeRow: activeRow)

        // Until the moving rows are known, every row is evidence. A read can be so small
        // that it changes a single row, and fixed rows simply keep voting for no movement.
        let evidence = movingBand.map(changed.union) ?? 0..<frame.count
        let votes = shiftVotes(frame: frame, band: evidence, baseGlobalRow: baseGlobalRow, activeRow: activeRow)
        applyBestShift(votes: votes,
                       changed: changed,
                       evidence: evidence,
                       frame: frame,
                       previous: previous,
                       baseGlobalRow: baseGlobalRow,
                       activeRow: activeRow)
        extendMovingBand(frame: frame, baseGlobalRow: baseGlobalRow, activeRow: activeRow)
    }

    /// Stores a frame known to be completely painted, after `follow` has seen it.
    /// `scrollingUp` tells which way the user just scrolled the application, if they did.
    /// Returns false when the text the selection was attached to cannot be located anymore.
    mutating func settle(frame: [UInt64],
                         baseGlobalRow: Int,
                         scrollingUp: Bool? = nil,
                         row: (Int) -> CapturedRow) -> Bool {
        defer {
            frameAtLastSettle = frame
            shiftAtLastSettle = globalShift
        }
        // Edits are only meaningful against the last settled frame: without a move, rows
        // that differ from it were replaced in place.
        guard frame != frameAtLastSettle || movingBand != nil else { return true }
        excludePinnedRows(frame: frame)
        let band = movingBand ?? Self.changedBand(previous: frameAtLastSettle, current: frame) ?? 0..<0
        if let scrollingUp, replacesStoredText(frame: frame, band: band, baseGlobalRow: baseGlobalRow) {
            jump(scrollingUp: scrollingUp, band: band, frameRowCount: frame.count, baseGlobalRow: baseGlobalRow)
        }
        var frame = frame
        let cleaned = updateOverlay(frame: &frame, baseGlobalRow: baseGlobalRow, row: row)
        commitFrame(frame: frame, band: band, baseGlobalRow: baseGlobalRow) { gridRow in
            if let cleaned, cleaned.gridRow == gridRow { return cleaned.row }
            return row(gridRow)
        }
        let textRowCount = (movingBand.map { frame[$0] } ?? frame[...])
            .filter { $0 != AppScrollRowHash.blank }.count
        return !(rowsEditedSinceLastMove.count > 1 && rowsEditedSinceLastMove.count * 2 >= textRowCount)
    }

    /// Where a row held at one shift and join count is at another. Moving by the change in shift
    /// is not enough once text was joined across a jump, as each side of it moved differently.
    /// The target is explicit because output keeps moving the tracker on another thread: a
    /// caller applying "now" while recording an earlier state would apply the difference twice.
    func globalRow(ofRow row: Int,
                   atShift shift: Int,
                   joinCount: Int,
                   toShift targetShift: Int,
                   toJoinCount targetJoinCount: Int) -> Int {
        var key = row - shift
        let end = min(targetJoinCount, joins.count)
        if joinCount < end {
            for join in joins[joinCount..<end] where join.gap.holdsNewerText(key: key) {
                key += join.offset
            }
        }
        return key + targetShift
    }

    /// A visible row, with the stored text where an overlay covers the screen.
    func capturedRow(atGlobalRow globalRow: Int, ifCovers visible: CapturedRow, gridRow: Int) -> CapturedRow {
        guard let overlay, let band = movingBand, gridRow == band.upperBound - 1 else { return visible }
        if let stored = storedRows[globalRow - globalShift], Self.sameText(stored.row, visible, outside: overlay.columns) {
            return stored.row
        }
        return Self.blanking(overlay.columns, in: visible)
    }

    /// Stored cells of a global row, when it is known to be scrolled text.
    func capturedRow(atGlobalRow globalRow: Int) -> CapturedRow? {
        guard let stored = storedRows[globalRow - globalShift], stored.isScrolledText else { return nil }
        return stored.row
    }

    /// Global rows of the scrolled text seen so far, including rows evicted by the limit.
    var scrolledTextGlobalRowExtent: ClosedRange<Int>? {
        guard let lower = scrolledTextLowerBound, let upper = scrolledTextUpperBound else { return nil }
        return (lower + globalShift)...(upper + globalShift)
    }

    /// True for a global row inside a jump: text there exists but never reached the screen.
    func isUndisplayed(globalRow: Int) -> Bool {
        let key = globalRow - globalShift
        return undisplayedKeyRanges.contains { $0.keys.contains(key) }
    }

    // MARK: - Pinned Rows

    /// Applications can pin a row at the edge of the moving text, such as the prompt a scrolled
    /// answer belongs to. It is not known in advance: it joins the band like the text it
    /// replaces, and shows itself by holding still while the content moved. It is not part of
    /// the text, and what it overwrote on its first appearance is put back.
    private mutating func excludePinnedRows(frame: [UInt64]) {
        guard globalShift != shiftAtLastSettle, var band = movingBand else { return }
        func isPinned(_ gridRow: Int) -> Bool {
            frame[gridRow] != AppScrollRowHash.blank && frame[gridRow] == frameAtLastSettle[gridRow]
        }
        var excluded: [Int] = []
        while !band.isEmpty, isPinned(band.lowerBound) {
            excluded.append(band.lowerBound)
            band = (band.lowerBound + 1)..<band.upperBound
        }
        while !band.isEmpty, isPinned(band.upperBound - 1) {
            excluded.append(band.upperBound - 1)
            band = band.lowerBound..<(band.upperBound - 1)
        }
        for gridRow in excluded {
            if let overwritten = overwrittenAtEdges.removeValue(forKey: gridRow), overwritten.by == frame[gridRow] {
                store(overwritten.stored, key: overwritten.key)
            }
        }
        movingBand = band
    }

    // MARK: - Jumps

    /// True when the screen shares no text with what is stored for its position: most text
    /// rows hold different text and the alignment found no better position.
    private func replacesStoredText(frame: [UInt64], band: Range<Int>, baseGlobalRow: Int) -> Bool {
        var textRows = 0
        var replaced = 0
        for gridRow in band where frame[gridRow] != AppScrollRowHash.blank {
            textRows += 1
            guard let stored = storedRows[baseGlobalRow + gridRow - globalShift] else { continue }
            if stored.hash != AppScrollRowHash.blank, stored.hash != frame[gridRow] {
                replaced += 1
            }
        }
        return replaced > 1 && replaced * 2 >= textRows
    }

    /// The user scrolled past everything stored, so the text is still there, only out of
    /// sight and at an unknown distance. The screen continues at unused content rows on that
    /// side, far enough that scrolling back cannot reach stored rows before their text shows.
    /// Alignment returns to them by itself when the text does.
    private mutating func jump(scrollingUp: Bool, band: Range<Int>, frameRowCount: Int, baseGlobalRow: Int) {
        guard let lower = storedLowerBound, let upper = storedUpperBound else { return }
        for gridRow in band {
            let key = baseGlobalRow + gridRow - globalShift
            guard var stored = storedRows[key] else { continue }
            stored.isScrolledText = true
            storedRows[key] = stored
            noteScrolledText(key: key)
        }
        let gap = maximumCapturedRows
        if scrollingUp {
            globalShift = baseGlobalRow + frameRowCount - lower + gap
            undisplayedKeyRanges.append(JumpGap(keys: (lower - gap)...(lower - 1), newerTextIsBelow: true))
        } else {
            globalShift = baseGlobalRow - upper - gap - 1
            undisplayedKeyRanges.append(JumpGap(keys: (upper + 1)...(upper + gap), newerTextIsBelow: false))
        }
        movingBand = movingBand ?? band
        frameBeforeLastMove = nil
        overlayCandidate = nil
        rowsEditedSinceLastMove.removeAll(keepingCapacity: true)
    }

    /// A screen showing text from both sides of a jump tells how far apart they really are.
    /// The newer text takes its true numbers, and the older text keeps its own.
    private mutating func joinTextAcrossJump(frame: [UInt64], baseGlobalRow: Int, activeRow: Int?) {
        guard !undisplayedKeyRanges.isEmpty, let band = movingBand else { return }
        for index in undisplayedKeyRanges.indices.reversed() {
            let gap = undisplayedKeyRanges[index]
            var newerVotes: [Int: Int] = [:]
            var olderVotes: [Int: Int] = [:]
            for gridRow in band where gridRow != activeRow && frame[gridRow] != AppScrollRowHash.blank {
                guard let keys = keysByHash[frame[gridRow]] else { continue }
                // Scrolling on can store the same text again beyond the jump, so a line can be
                // on both sides. Only a line occurring more than once on one side is ambiguous.
                let newerKeys = keys.filter { gap.holdsNewerText(key: $0) }
                let olderKeys = keys.filter { !gap.holdsNewerText(key: $0) }
                if newerKeys.count == 1, let key = newerKeys.first {
                    newerVotes[baseGlobalRow + gridRow - key, default: 0] += 1
                }
                if olderKeys.count == 1, let key = olderKeys.first {
                    olderVotes[baseGlobalRow + gridRow - key, default: 0] += 1
                }
            }
            guard let newer = newerVotes.max(by: { $0.value < $1.value }), newer.value >= 2,
                  let older = olderVotes.max(by: { $0.value < $1.value }), older.value >= 2,
                  // Joining renumbers everything on one side, which leaves no room for a
                  // coincidence. One row can still differ, by being an overlay.
                  storedTextComparison(shift: older.key, frame: frame, band: band, baseGlobalRow: baseGlobalRow, activeRow: activeRow).disagreeing <= 1,
                  storedTextComparison(shift: newer.key, frame: frame, band: band, baseGlobalRow: baseGlobalRow, activeRow: activeRow).disagreeing <= 1 else { continue }
            let movedBy = newer.key - older.key
            guard textFitsTogether(across: gap, offset: movedBy) else { continue }
            renumberNewerText(of: gap, by: movedBy)
            joins.append((gap, movedBy))
            undisplayedKeyRanges.remove(at: index)
            globalShift = older.key
            frameBeforeLastMove = nil
            return
        }
    }

    /// Where both sides hold a row for the same position after joining, it must be the same
    /// text. This judges the join by everything stored, not only by what the screen shows.
    private func textFitsTogether(across gap: JumpGap, offset: Int) -> Bool {
        var conflicts = 0
        for (key, stored) in storedRows where gap.holdsNewerText(key: key) && stored.hash != AppScrollRowHash.blank {
            if let other = storedRows[key + offset], other.hash != AppScrollRowHash.blank, other.hash != stored.hash {
                conflicts += 1
            }
        }
        return conflicts <= 1
    }

    private mutating func renumberNewerText(of gap: JumpGap, by offset: Int) {
        let moved = storedRows.filter { gap.holdsNewerText(key: $0.key) }
        for (key, stored) in moved {
            storedRows.removeValue(forKey: key)
            removeFromHashIndex(hash: stored.hash, key: key)
        }
        for (key, stored) in moved {
            storedRows[key + offset] = stored
            if stored.hash != AppScrollRowHash.blank {
                keysByHash[stored.hash, default: []].insert(key + offset)
            }
        }
        for index in undisplayedKeyRanges.indices where gap.holdsNewerText(key: undisplayedKeyRanges[index].keys.lowerBound) {
            let keys = undisplayedKeyRanges[index].keys
            undisplayedKeyRanges[index].keys = (keys.lowerBound + offset)...(keys.upperBound + offset)
        }
        func renumbered(_ key: Int?) -> Int? { key.map { gap.holdsNewerText(key: $0) ? $0 + offset : $0 } }
        storedLowerBound = storedRows.keys.min()
        storedUpperBound = storedRows.keys.max()
        // The extent of scrolled text ends at what is stored, now that the gap between is gone.
        scrolledTextLowerBound = renumbered(scrolledTextLowerBound)
        scrolledTextUpperBound = renumbered(scrolledTextUpperBound)
    }

    // MARK: - Overlay

    /// Applications can draw over the last moving row, such as a "Jump to bottom" hint, which
    /// is not part of the text under it. It shows as one run of cells that differs from the
    /// text stored for that row. Cells with their own background on an otherwise unchanged row
    /// are an overlay. Without one, an ordinary edit looks the same on one row, so an overlay
    /// is only believed once the same cells show on a second, different line.
    private mutating func updateOverlay(frame: inout [UInt64],
                                        baseGlobalRow: Int,
                                        row: (Int) -> CapturedRow) -> (gridRow: Int, row: CapturedRow)? {
        guard let band = movingBand, !band.isEmpty else { return nil }
        let lastRow = band.upperBound - 1
        let cells = row(lastRow).cells
        let key = baseGlobalRow + lastRow - globalShift

        if let current = overlay, !Self.sameText(cells, current.cells, at: current.columns) {
            overlay = nil
        }
        if overlay == nil, let stored = storedRows[key],
           let run = Self.differingRun(between: stored.row.cells, and: cells) {
            let columns = Self.overlayColumns(containing: run, in: cells)
            if Self.hasOwnBackground(columns, in: cells) {
                overlay = (columns, cells)
            } else if let candidate = overlayCandidate, candidate.key != key,
               candidate.columns == columns, Self.sameText(cells, candidate.cells, at: columns) {
                overlay = (columns, cells)
                // The first line showing it was overwritten before it could be recognized.
                store(StoredRow(row: candidate.original, hash: AppScrollRowHash.hash(cells: candidate.original.cells), isScrolledText: true),
                      key: candidate.key)
            } else {
                overlayCandidate = (columns, cells, key, stored.row)
            }
        }
        guard let columns = overlay?.columns else { return nil }

        let visible = row(lastRow)
        let cleaned = Self.blanking(columns, in: visible)
        // Text the overlay covers is already stored from when the row was above it.
        if let stored = storedRows[key], Self.sameText(stored.row, visible, outside: columns) {
            frame[lastRow] = stored.hash
            return (lastRow, stored.row)
        }
        frame[lastRow] = AppScrollRowHash.hash(cells: cleaned.cells)
        return (lastRow, cleaned)
    }

    /// The one run of cells where two rows differ, when that is all that differs.
    private static func differingRun(between a: [Cell], and b: [Cell]) -> Range<Int>? {
        let count = max(a.count, b.count)
        func codepoint(_ row: [Cell], _ column: Int) -> UInt32 {
            guard column < row.count, row[column].codepoint != 0 else { return 0x20 }
            return row[column].codepoint
        }
        var start = 0
        while start < count, codepoint(a, start) == codepoint(b, start) { start += 1 }
        guard start < count else { return nil }
        var end = count
        while end > start, codepoint(a, end - 1) == codepoint(b, end - 1) { end -= 1 }
        // A row replaced by other text differs nearly everywhere, and also from its first
        // cell. What is drawn over a line leaves that line visible on at least one side.
        let isMostlyTheSameRow = start > 0 || end < count
        guard isMostlyTheSameRow, end - start >= 2 else { return nil }
        return start..<end
    }

    /// An overlay usually has its own background, and that is what says where it ends: the
    /// differing cells alone stop short where the text under it happens to be blank, which
    /// would make the same overlay look different on every line. They can also reach one cell
    /// past it, when its edge cut a wide character of the text in half.
    private static func overlayColumns(containing run: Range<Int>, in cells: [Cell]) -> Range<Int> {
        guard run.upperBound <= cells.count else { return run }
        var core = run
        if core.count > 2, cells[core.lowerBound].attributes.background == .default {
            core = (core.lowerBound + 1)..<core.upperBound
        }
        if core.count > 2, cells[core.upperBound - 1].attributes.background == .default {
            core = core.lowerBound..<(core.upperBound - 1)
        }
        let background = cells[core.lowerBound].attributes.background
        guard background != .default,
              core.allSatisfy({ cells[$0].attributes.background == background }) else { return run }
        var start = core.lowerBound
        while start > 0, cells[start - 1].attributes.background == background { start -= 1 }
        var end = core.upperBound
        while end < cells.count, cells[end].attributes.background == background { end += 1 }
        return start..<end
    }

    private static func hasOwnBackground(_ columns: Range<Int>, in cells: [Cell]) -> Bool {
        guard columns.upperBound <= cells.count, !columns.isEmpty else { return false }
        let background = cells[columns.lowerBound].attributes.background
        return background != .default && columns.allSatisfy { cells[$0].attributes.background == background }
    }

    /// True when two rows hold the same text apart from `columns`, and the cell on either side
    /// of them, which holds half a wide character when the overlay cut it.
    private static func sameText(_ a: CapturedRow, _ b: CapturedRow, outside columns: Range<Int>) -> Bool {
        let around = max(columns.lowerBound - 1, 0)..<(columns.upperBound + 1)
        return AppScrollRowHash.hash(cells: blanking(around, in: a).cells) == AppScrollRowHash.hash(cells: blanking(around, in: b).cells)
    }

    private static func sameText(_ a: [Cell], _ b: [Cell], at columns: Range<Int>) -> Bool {
        guard columns.upperBound <= a.count, columns.upperBound <= b.count else { return false }
        return columns.allSatisfy { a[$0].codepoint == b[$0].codepoint }
    }

    private static func blanking(_ columns: Range<Int>, in captured: CapturedRow) -> CapturedRow {
        var cells = captured.cells
        for column in columns where column < cells.count {
            cells[column] = Cell(codepoint: 0x20, attributes: .default, width: 1, isWideContinuation: false)
        }
        return CapturedRow(cells: cells, isWrapped: captured.isWrapped)
    }

    // MARK: - Alignment

    private static func changedBand(previous: [UInt64], current: [UInt64]) -> Range<Int>? {
        var top = 0
        while top < current.count, previous[top] == current[top] { top += 1 }
        guard top < current.count else { return nil }
        var bottom = current.count
        while bottom > top, previous[bottom - 1] == current[bottom - 1] { bottom -= 1 }
        return top..<bottom
    }

    /// Every text row votes for each shift that would put it where it was stored. A line that
    /// occurs many times, like a "Ran 1 command" in a transcript, says little about where the
    /// screen is, so its vote is divided among its occurrences.
    private func shiftVotes(frame: [UInt64],
                            band: Range<Int>,
                            baseGlobalRow: Int,
                            activeRow: Int?) -> [Int: Double] {
        var votes: [Int: Double] = [:]
        for gridRow in band where gridRow != activeRow && frame[gridRow] != AppScrollRowHash.blank {
            guard let keys = keysByHash[frame[gridRow]] else { continue }
            let weight = 1 / Double(keys.count)
            for key in keys {
                votes[baseGlobalRow + gridRow - key, default: 0] += weight
            }
        }
        return votes
    }

    /// How many rows of the screen agree and disagree with the text stored for their position.
    private func storedTextComparison(shift: Int, frame: [UInt64], band: Range<Int>, baseGlobalRow: Int, activeRow: Int?) -> (agreeing: Int, disagreeing: Int) {
        var agreeing = 0
        var disagreeing = 0
        for gridRow in band where gridRow != activeRow && frame[gridRow] != AppScrollRowHash.blank {
            guard let stored = storedRows[baseGlobalRow + gridRow - shift], stored.hash != AppScrollRowHash.blank else { continue }
            if stored.hash == frame[gridRow] {
                agreeing += 1
            } else {
                disagreeing += 1
            }
        }
        return (agreeing, disagreeing)
    }

    /// False when more rows disagree than agree, which is what a coincidental alignment looks like.
    private func storedTextAgrees(shift: Int, frame: [UInt64], band: Range<Int>, baseGlobalRow: Int, activeRow: Int?) -> Bool {
        let comparison = storedTextComparison(shift: shift, frame: frame, band: band, baseGlobalRow: baseGlobalRow, activeRow: activeRow)
        return comparison.disagreeing <= comparison.agreeing
    }

    private mutating func applyBestShift(votes: [Int: Double],
                                         changed: Range<Int>,
                                         evidence: Range<Int>,
                                         frame: [UInt64],
                                         previous: [UInt64],
                                         baseGlobalRow: Int,
                                         activeRow: Int?) {
        var best = globalShift
        var bestVotes = votes[globalShift] ?? 0
        for (shift, count) in votes {
            let isCloser = abs(shift - globalShift) < abs(best - globalShift)
            if count > bestVotes || (count == bestVotes && isCloser && best != globalShift) {
                best = shift
                bestVotes = count
            }
        }
        // One row can match by coincidence, for example an edit that repeats another line.
        guard best != globalShift, bestVotes >= 2,
              storedTextAgrees(shift: best, frame: frame, band: evidence, baseGlobalRow: baseGlobalRow, activeRow: activeRow) else { return }
        shiftBeforeLastMove = globalShift
        frameBeforeLastMove = previous
        globalShift = best
        rowsEditedSinceLastMove.removeAll(keepingCapacity: true)

        // Everything already repainted at the new position is moving, also rows that an
        // earlier read changed. Rows of the old position that left the screen in this very
        // move were moving as well, and are the first ones a copy would otherwise lose.
        var band = movingBand.map(changed.union) ?? changed
        let isFirstMove = movingBand == nil
        for gridRow in frame.indices where gridRow != activeRow && frame[gridRow] != AppScrollRowHash.blank {
            guard let stored = storedRows[baseGlobalRow + gridRow - best], stored.hash == frame[gridRow] else { continue }
            // A fixed row also matches: its own copy from when tracking began is found again
            // whenever the content returns to that position. Fixed rows never moved, which is
            // what tells them apart: known scrolled text, or on the first move, a row that
            // does not hold the same text at the old position.
            let staysInPlace = storedRows[baseGlobalRow + gridRow - shiftBeforeLastMove]?.hash == frame[gridRow]
            if isFirstMove ? !staysInPlace : stored.isScrolledText {
                band = band.union(gridRow..<(gridRow + 1))
            }
        }
        movingBand = band
        for gridRow in band {
            let key = previousBaseGlobalRow + gridRow - shiftBeforeLastMove
            guard var stored = storedRows[key] else { continue }
            stored.isScrolledText = true
            storedRows[key] = stored
            noteScrolledText(key: key)
        }
    }

    /// A repaint reaches the rows of the moving band one read at a time, in reads that can
    /// be as small as part of one row. A row belongs to the band once it differs from the
    /// screen the repaint started from and either held scrolled text there or holds it now.
    /// Fixed rows do not qualify, because they do not differ from that screen.
    private mutating func extendMovingBand(frame: [UInt64], baseGlobalRow: Int, activeRow: Int?) {
        guard var band = movingBand, let origin = frameBeforeLastMove else { return }
        func qualifies(_ gridRow: Int) -> Bool {
            guard gridRow != activeRow, frame[gridRow] != origin[gridRow] else { return false }
            let heldScrolledText = origin[gridRow] != AppScrollRowHash.blank
                && storedRows[baseGlobalRow + gridRow - shiftBeforeLastMove]?.hash == origin[gridRow]
            let holdsScrolledText = frame[gridRow] != AppScrollRowHash.blank
                && storedRows[baseGlobalRow + gridRow - globalShift]?.hash == frame[gridRow]
            return heldScrolledText || holdsScrolledText
        }
        if let lowest = frame.indices[band.upperBound...].last(where: qualifies) {
            band = band.lowerBound..<(lowest + 1)
        }
        if let highest = frame.indices[..<band.lowerBound].first(where: qualifies) {
            band = highest..<band.upperBound
        }
        movingBand = band
    }

    // MARK: - Storage

    /// Classifies every row before changing anything, because storing one row removes
    /// the old text of its key from the index, which would change how later rows look.
    private mutating func commitFrame(frame: [UInt64],
                                      band: Range<Int>,
                                      baseGlobalRow: Int,
                                      row: (Int) -> CapturedRow) {
        let isMoving = movingBand != nil
        var aligned = 0
        var misaligned = 0
        var writes: [(gridRow: Int, key: Int, isEdit: Bool)] = []

        for gridRow in band {
            let hash = frame[gridRow]
            let key = baseGlobalRow + gridRow - globalShift
            guard var stored = storedRows[key] else {
                writes.append((gridRow, key, false))
                continue
            }
            if stored.hash == hash {
                aligned += 1
                stored.isScrolledText = stored.isScrolledText || isMoving
                storedRows[key] = stored
                if stored.isScrolledText { noteScrolledText(key: key) }
                continue
            }
            if hash != AppScrollRowHash.blank, !(keysByHash[hash]?.isEmpty ?? true) {
                misaligned += 1
            }
            let isEdit = stored.hash != AppScrollRowHash.blank && hash != AppScrollRowHash.blank
            writes.append((gridRow, key, isEdit))
        }

        // A settled frame that mostly holds rows of other positions is not explained by the
        // current alignment. Storing it would corrupt what later alignments rely on.
        guard misaligned * 10 <= aligned + writes.count else { return }

        // What a row overwrote stays known while the row holds that text, which can be for
        // several repaints when the content does not move in between.
        overwrittenAtEdges = overwrittenAtEdges.filter { $0.key < frame.count && frame[$0.key] == $0.value.by }
        // A row differing from its stored text right after a move proves little: it can be an
        // overlay, a pinned row or a wrong alignment. Stored text is the only copy of what left
        // the screen, so it is replaced only when the difference remains at the same position.
        let hasMoved = globalShift != shiftAtLastSettle
        for write in writes {
            let wasScrolledText = storedRows[write.key]?.isScrolledText ?? false
            if write.isEdit, hasMoved, wasScrolledText { continue }
            if write.isEdit, write.gridRow == band.lowerBound || write.gridRow == band.upperBound - 1,
               let replaced = storedRows[write.key] {
                overwrittenAtEdges[write.gridRow] = (write.key, replaced, frame[write.gridRow])
            }
            if write.isEdit { rowsEditedSinceLastMove.insert(write.gridRow) }
            store(StoredRow(row: row(write.gridRow),
                            hash: frame[write.gridRow],
                            isScrolledText: wasScrolledText || isMoving),
                  key: write.key)
        }
    }

    private mutating func store(_ stored: StoredRow, key: Int) {
        if let old = storedRows[key] { removeFromHashIndex(hash: old.hash, key: key) }
        storedRows[key] = stored
        if stored.hash != AppScrollRowHash.blank { keysByHash[stored.hash, default: []].insert(key) }
        storedLowerBound = min(storedLowerBound ?? key, key)
        storedUpperBound = max(storedUpperBound ?? key, key)
        if stored.isScrolledText { noteScrolledText(key: key) }

        // Evict from the end farthest from the row just stored, to keep what surrounds the screen.
        while storedRows.count > maximumCapturedRows,
              let lower = storedLowerBound,
              let upper = storedUpperBound {
            let evicted = upper - key > key - lower ? upper : lower
            if let old = storedRows.removeValue(forKey: evicted) {
                removeFromHashIndex(hash: old.hash, key: evicted)
            }
            if evicted == upper {
                storedUpperBound = upper - 1
            } else {
                storedLowerBound = lower + 1
            }
        }
    }

    private mutating func noteScrolledText(key: Int) {
        scrolledTextLowerBound = min(scrolledTextLowerBound ?? key, key)
        scrolledTextUpperBound = max(scrolledTextUpperBound ?? key, key)
    }

    private mutating func removeFromHashIndex(hash: UInt64, key: Int) {
        guard var keys = keysByHash[hash] else { return }
        keys.remove(key)
        keysByHash[hash] = keys.isEmpty ? nil : keys
    }
}

private extension Range where Bound == Int {
    func union(_ other: Range<Int>) -> Range<Int> {
        Swift.min(lowerBound, other.lowerBound)..<Swift.max(upperBound, other.upperBound)
    }
}
