import CoreGraphics
import Foundation

/// Extra correction points inside a layer, for surfaces a four-corner warp cannot
/// describe.
///
/// A homography is exact for a flat surface at any angle, and that is all four
/// corners can express. A curved wall, a column, a stretched fabric or a set of
/// panels that do not sit quite flush need local correction, which is what this adds:
/// control points whose offsets are applied *on top of* the quad's projective map.
/// With every offset at zero the mesh reproduces the homography exactly, so adding
/// points to a finished mapping never moves it.
///
/// ## Why lines rather than free points
///
/// The grid is stored as the *positions of its dividing lines* rather than as a
/// count, so the spacing can be uneven: points can be crowded where a surface bends
/// and left sparse where it is flat. Tapping the stage inserts a line each way, which
/// puts a new control point exactly under the finger.
///
/// It does mean a new point arrives with the rest of its row and column rather than
/// alone. That is a deliberate trade: the renderer draws each cell as a quad with its
/// own homography, which is what keeps perspective correct inside every cell. Points
/// floating freely would need the surface triangulated, and a triangle can only carry
/// an affine map — straight lines in the content would kink at every shared edge.
struct MeshWarp: Codable, Equatable {
    /// Normalized positions of the vertical dividing lines, ascending, always
    /// starting at 0 and ending at 1. Two entries means an undivided quad.
    private(set) var columnPositions: [Double]
    /// Same, horizontally.
    private(set) var rowPositions: [Double]
    /// Hand-dragged offsets for every point, row-major, in normalized canvas units.
    private(set) var offsets: [CGPoint]
    /// Offsets derived from a surface scan, kept apart from the hand-dragged ones.
    ///
    /// Two arrays rather than one because they answer to different owners. The hand
    /// offsets are what the operator dragged and must never be recomputed; the scan
    /// offsets are derived, and a second bend has to *replace* them rather than add
    /// to them. Summing them into a single array makes bending twice double the bend
    /// — which is what happened, and what this separation fixes.
    private(set) var scanOffsets: [CGPoint]

    /// Even grid sizes offered as one-tap presets.
    static let availableDivisions = [1, 2, 3, 4, 6, 8]
    /// Cap on divisions each way. Every cell is its own draw call, so 12 x 12 is 144
    /// for one layer — past the point where a phone stays comfortable.
    static let maximumDivisions = 12
    /// Lines closer together than this are indistinguishable under a fingertip, and
    /// a cell that thin has nothing useful to warp.
    static let minimumSpacing: Double = 0.04

    // MARK: - Creation

    init(columns: Int = 1, rows: Int = 1) {
        columnPositions = Self.evenPositions(divisions: columns)
        rowPositions = Self.evenPositions(divisions: rows)
        let count = columnPositions.count * rowPositions.count
        offsets = Array(repeating: .zero, count: count)
        scanOffsets = Array(repeating: .zero, count: count)
    }

    private static func evenPositions(divisions: Int) -> [Double] {
        let count = max(1, min(maximumDivisions, divisions))
        return (0...count).map { Double($0) / Double(count) }
    }

    /// Sorts, clamps and de-duplicates a stored line list, and always keeps the two
    /// edges. A corrupt or hand-edited file must not be able to produce a grid the
    /// renderer can index out of bounds.
    private static func sanitised(_ stored: [Double]) -> [Double] {
        var cleaned = stored.filter { $0.isFinite && $0 > 0 && $0 < 1 }
            .map { min(max($0, 0), 1) }
            .sorted()
        cleaned = cleaned.reduce(into: [Double]()) { result, value in
            if let last = result.last, value - last < minimumSpacing / 2 { return }
            result.append(value)
        }
        if cleaned.count > maximumDivisions - 1 {
            cleaned = Array(cleaned.prefix(maximumDivisions - 1))
        }
        return [0] + cleaned + [1]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Shows saved before uneven grids existed store only a count each way.
        if let storedColumns = try container.decodeIfPresent([Double].self,
                                                             forKey: .columnPositions) {
            columnPositions = Self.sanitised(storedColumns)
        } else {
            let count = try container.decodeIfPresent(Int.self, forKey: .columns) ?? 1
            columnPositions = Self.evenPositions(divisions: count)
        }
        if let storedRows = try container.decodeIfPresent([Double].self,
                                                          forKey: .rowPositions) {
            rowPositions = Self.sanitised(storedRows)
        } else {
            let count = try container.decodeIfPresent(Int.self, forKey: .rows) ?? 1
            rowPositions = Self.evenPositions(divisions: count)
        }

        let needed = columnPositions.count * rowPositions.count
        func sized(_ stored: [CGPoint]) -> [CGPoint] {
            stored.count == needed
                ? stored
                : Array(stored.prefix(needed)) + Array(repeating: .zero,
                                                       count: max(0, needed - stored.count))
        }
        offsets = sized(try container.decodeIfPresent([CGPoint].self, forKey: .offsets) ?? [])
        scanOffsets = sized(try container.decodeIfPresent([CGPoint].self,
                                                          forKey: .scanOffsets) ?? [])
    }

    /// Both shapes are written: the line positions this version uses, and the counts
    /// an older build would read. An older build opening a newer show then sees an
    /// even grid rather than failing — the mapping is wrong in the spacing but the
    /// show still opens.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(columnPositions, forKey: .columnPositions)
        try container.encode(rowPositions, forKey: .rowPositions)
        try container.encode(columns, forKey: .columns)
        try container.encode(rows, forKey: .rows)
        try container.encode(offsets, forKey: .offsets)
        try container.encode(scanOffsets, forKey: .scanOffsets)
    }

    // MARK: - Shape

    var columns: Int { columnPositions.count - 1 }
    var rows: Int { rowPositions.count - 1 }
    var pointsAcross: Int { columnPositions.count }
    var pointsDown: Int { rowPositions.count }
    var pointCount: Int { pointsAcross * pointsDown }
    var cellCount: Int { columns * rows }
    var isSubdivided: Bool { columns > 1 || rows > 1 }
    var isEvenlySpaced: Bool {
        Self.isEven(columnPositions) && Self.isEven(rowPositions)
    }

    private static func isEven(_ positions: [Double]) -> Bool {
        let step = 1 / Double(positions.count - 1)
        return positions.enumerated().allSatisfy {
            abs($0.element - Double($0.offset) * step) < 1e-9
        }
    }

    var isWarped: Bool { effectiveOffsets.contains { $0.x != 0 || $0.y != 0 } }
    var hasScanCorrection: Bool { scanOffsets.contains { $0.x != 0 || $0.y != 0 } }

    func index(column: Int, row: Int) -> Int { row * pointsAcross + column }

    /// Normalized (u, v) of a control point inside the layer.
    func parameter(column: Int, row: Int) -> CGPoint {
        CGPoint(x: columnPositions[min(max(column, 0), columns)],
                y: rowPositions[min(max(row, 0), rows)])
    }

    // MARK: - Offsets

    /// The hand-dragged offset of a point. For what is drawn, use
    /// `effectiveOffset(at:)`, which includes any scan correction.
    func offset(column: Int, row: Int) -> CGPoint {
        offset(at: index(column: column, row: row))
    }

    func offset(at index: Int) -> CGPoint {
        offsets.indices.contains(index) ? offsets[index] : .zero
    }

    func scanOffset(at index: Int) -> CGPoint {
        scanOffsets.indices.contains(index) ? scanOffsets[index] : .zero
    }

    /// What the renderer and the handles actually use: hand plus scan.
    var effectiveOffsets: [CGPoint] {
        zip(offsets, scanOffsets).map { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
    }

    func effectiveOffset(at index: Int) -> CGPoint {
        let hand = offset(at: index)
        let scan = scanOffset(at: index)
        return CGPoint(x: hand.x + scan.x, y: hand.y + scan.y)
    }

    mutating func setOffset(_ offset: CGPoint, column: Int, row: Int) {
        setOffset(offset, at: index(column: column, row: row))
    }

    mutating func setOffset(_ offset: CGPoint, at index: Int) {
        guard offsets.indices.contains(index) else { return }
        offsets[index] = offset
    }

    /// Replaces the scan-derived correction outright. Idempotent by construction:
    /// bending to the same surface twice gives the same answer as bending once.
    mutating func setScanOffsets(_ newValue: [CGPoint]) {
        scanOffsets = Array(newValue.prefix(pointCount))
            + Array(repeating: .zero, count: max(0, pointCount - newValue.count))
    }

    mutating func clearScanCorrection() {
        scanOffsets = Array(repeating: .zero, count: pointCount)
    }

    mutating func reset() {
        offsets = Array(repeating: .zero, count: pointCount)
        scanOffsets = Array(repeating: .zero, count: pointCount)
    }

    // MARK: - Adding and removing points

    /// Whether a new dividing line can go in at `position` without crowding an
    /// existing one.
    func canInsertColumn(at position: Double) -> Bool {
        Self.canInsert(position, into: columnPositions)
    }

    func canInsertRow(at position: Double) -> Bool {
        Self.canInsert(position, into: rowPositions)
    }

    private static func canInsert(_ position: Double, into positions: [Double]) -> Bool {
        guard position.isFinite, positions.count <= maximumDivisions else { return false }
        guard position > minimumSpacing, position < 1 - minimumSpacing else { return false }
        return positions.allSatisfy { abs($0 - position) >= minimumSpacing }
    }

    /// Inserts a vertical dividing line, giving the new points offsets interpolated
    /// from their neighbours so the surface does not jump where it appears.
    @discardableResult
    mutating func insertColumn(at position: Double) -> Bool {
        guard canInsertColumn(at: position) else { return false }
        let insertion = columnPositions.firstIndex { $0 > position } ?? columnPositions.count

        var newOffsets: [CGPoint] = []
        var newScanOffsets: [CGPoint] = []
        newOffsets.reserveCapacity(pointCount + pointsDown)
        newScanOffsets.reserveCapacity(pointCount + pointsDown)

        for row in 0..<pointsDown {
            for column in 0..<pointsAcross {
                if column == insertion {
                    newOffsets.append(sampledOffset(u: position,
                                                    v: rowPositions[row], in: offsets))
                    newScanOffsets.append(sampledOffset(u: position,
                                                        v: rowPositions[row], in: scanOffsets))
                }
                newOffsets.append(offset(at: index(column: column, row: row)))
                newScanOffsets.append(scanOffset(at: index(column: column, row: row)))
            }
            if insertion == pointsAcross {
                newOffsets.append(sampledOffset(u: position,
                                                v: rowPositions[row], in: offsets))
                newScanOffsets.append(sampledOffset(u: position,
                                                    v: rowPositions[row], in: scanOffsets))
            }
        }

        columnPositions.insert(position, at: insertion)
        offsets = newOffsets
        scanOffsets = newScanOffsets
        return true
    }

    @discardableResult
    mutating func insertRow(at position: Double) -> Bool {
        guard canInsertRow(at: position) else { return false }
        let insertion = rowPositions.firstIndex { $0 > position } ?? rowPositions.count

        var newOffsets: [CGPoint] = []
        var newScanOffsets: [CGPoint] = []
        for row in 0...rows + 1 {
            if row == insertion {
                for column in 0..<pointsAcross {
                    newOffsets.append(sampledOffset(u: columnPositions[column],
                                                    v: position, in: offsets))
                    newScanOffsets.append(sampledOffset(u: columnPositions[column],
                                                        v: position, in: scanOffsets))
                }
            }
            guard row < pointsDown else { continue }
            for column in 0..<pointsAcross {
                newOffsets.append(offset(at: index(column: column, row: row)))
                newScanOffsets.append(scanOffset(at: index(column: column, row: row)))
            }
        }

        rowPositions.insert(position, at: insertion)
        offsets = newOffsets
        scanOffsets = newScanOffsets
        return true
    }

    /// Removes an interior dividing line. The two edges are the layer's own sides and
    /// are never removable.
    @discardableResult
    mutating func removeColumn(_ column: Int) -> Bool {
        guard column > 0, column < columns else { return false }
        var newOffsets: [CGPoint] = []
        var newScanOffsets: [CGPoint] = []
        for row in 0..<pointsDown {
            for c in 0..<pointsAcross where c != column {
                newOffsets.append(offset(at: index(column: c, row: row)))
                newScanOffsets.append(scanOffset(at: index(column: c, row: row)))
            }
        }
        columnPositions.remove(at: column)
        offsets = newOffsets
        scanOffsets = newScanOffsets
        return true
    }

    @discardableResult
    mutating func removeRow(_ row: Int) -> Bool {
        guard row > 0, row < rows else { return false }
        let start = row * pointsAcross
        offsets.removeSubrange(start..<(start + pointsAcross))
        scanOffsets.removeSubrange(start..<(start + pointsAcross))
        rowPositions.remove(at: row)
        return true
    }

    // MARK: - Resizing

    /// Replaces the grid with an evenly spaced one, resampling the correction so the
    /// surface keeps its shape.
    func resized(columns newColumns: Int, rows newRows: Int) -> MeshWarp {
        respaced(columnPositions: Self.evenPositions(divisions: newColumns),
                 rowPositions: Self.evenPositions(divisions: newRows))
    }

    /// Moves the grid onto new line positions, resampling both offset fields.
    func respaced(columnPositions newColumns: [Double],
                  rowPositions newRows: [Double]) -> MeshWarp {
        var resized = MeshWarp()
        resized.columnPositions = Self.sanitised(Array(newColumns.dropFirst().dropLast()))
        resized.rowPositions = Self.sanitised(Array(newRows.dropFirst().dropLast()))

        var hand = [CGPoint](repeating: .zero, count: resized.pointCount)
        var scan = hand
        if isWarped {
            for row in 0..<resized.pointsDown {
                for column in 0..<resized.pointsAcross {
                    let u = resized.columnPositions[column]
                    let v = resized.rowPositions[row]
                    let index = resized.index(column: column, row: row)
                    hand[index] = sampledOffset(u: u, v: v, in: offsets)
                    scan[index] = sampledOffset(u: u, v: v, in: scanOffsets)
                }
            }
        }
        resized.offsets = hand
        resized.scanOffsets = scan
        return resized
    }

    /// Bilinear sample of the hand-dragged offset field at a normalized position.
    func sampledOffset(u: Double, v: Double) -> CGPoint {
        sampledOffset(u: u, v: v, in: offsets)
    }

    /// Bilinear sample of an offset field, in the grid's own uneven spacing.
    private func sampledOffset(u: Double, v: Double, in field: [CGPoint]) -> CGPoint {
        let (column, fx) = Self.locate(min(max(u, 0), 1), in: columnPositions)
        let (row, fy) = Self.locate(min(max(v, 0), 1), in: rowPositions)

        func sample(_ column: Int, _ row: Int) -> CGPoint {
            let i = index(column: column, row: row)
            return field.indices.contains(i) ? field[i] : .zero
        }
        let topLeft = sample(column, row)
        let topRight = sample(column + 1, row)
        let bottomLeft = sample(column, row + 1)
        let bottomRight = sample(column + 1, row + 1)

        let top = CGPoint(x: topLeft.x + (topRight.x - topLeft.x) * fx,
                          y: topLeft.y + (topRight.y - topLeft.y) * fx)
        let bottom = CGPoint(x: bottomLeft.x + (bottomRight.x - bottomLeft.x) * fx,
                             y: bottomLeft.y + (bottomRight.y - bottomLeft.y) * fx)
        return CGPoint(x: top.x + (bottom.x - top.x) * fy,
                       y: top.y + (bottom.y - top.y) * fy)
    }

    /// Which cell a position falls in, and how far across it, for an uneven grid.
    private static func locate(_ position: Double, in positions: [Double]) -> (Int, Double) {
        let lastCell = positions.count - 2
        guard lastCell >= 0 else { return (0, 0) }
        var cell = lastCell
        for index in 0...lastCell where position < positions[index + 1] {
            cell = index
            break
        }
        let span = positions[cell + 1] - positions[cell]
        let fraction = span > 0 ? (position - positions[cell]) / span : 0
        return (cell, min(max(fraction, 0), 1))
    }

    private enum CodingKeys: String, CodingKey {
        case columnPositions, rowPositions, columns, rows, offsets, scanOffsets
    }
}

/// One cell of a warped layer: where it lands on the canvas, and which part of the
/// layer's texture belongs to it.
struct MeshCell: Equatable {
    var quad: Quad
    var uvOrigin: CGPoint
    var uvSize: CGSize
}
