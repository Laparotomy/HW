import CoreGraphics
import Foundation

/// Extra correction points inside a layer, for surfaces a four-corner warp cannot
/// describe.
///
/// A homography is exact for a flat surface at any angle, and that is all four
/// corners can express. A curved wall, a column, a stretched fabric or a set of
/// panels that do not sit quite flush need local correction, which is what this adds:
/// a grid of control points whose offsets are applied *on top of* the quad's
/// projective map. With every offset at zero the mesh reproduces the homography
/// exactly, so subdividing a finished mapping never moves it.
struct MeshWarp: Codable, Equatable {
    /// Cells across and down. 1 x 1 is a plain quad with no extra points.
    private(set) var columns: Int
    private(set) var rows: Int
    /// Hand-dragged offsets for `(columns + 1) * (rows + 1)` points in row-major
    /// order, in normalized canvas units.
    private(set) var offsets: [CGPoint]
    /// Offsets derived from a surface scan, kept apart from the hand-dragged ones.
    ///
    /// Two arrays rather than one because they answer to different owners. The hand
    /// offsets are what the operator dragged and must never be recomputed; the scan
    /// offsets are derived, and a second bend has to *replace* them rather than add
    /// to them. Summing them into a single array makes bending twice double the bend
    /// — which is what happened, and what this separation fixes.
    private(set) var scanOffsets: [CGPoint]

    /// Grid sizes offered in the UI. Capped at 8 because each cell is its own draw
    /// call — 8 x 8 is 64 per layer, which is already a lot to spend on one surface.
    static let availableDivisions = [1, 2, 3, 4, 6, 8]
    static let maximumDivisions = 8

    init(columns: Int = 1, rows: Int = 1) {
        self.columns = max(1, min(Self.maximumDivisions, columns))
        self.rows = max(1, min(Self.maximumDivisions, rows))
        let count = (self.columns + 1) * (self.rows + 1)
        offsets = Array(repeating: .zero, count: count)
        scanOffsets = Array(repeating: .zero, count: count)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedColumns = try container.decode(Int.self, forKey: .columns)
        let storedRows = try container.decode(Int.self, forKey: .rows)
        columns = max(1, min(Self.maximumDivisions, storedColumns))
        rows = max(1, min(Self.maximumDivisions, storedRows))
        // A file written by a newer version, or simply corrupt, must not be able to
        // index the renderer out of bounds.
        let needed = (columns + 1) * (rows + 1)
        func sized(_ stored: [CGPoint]) -> [CGPoint] {
            stored.count == needed
                ? stored
                : Array(stored.prefix(needed)) + Array(repeating: .zero,
                                                       count: max(0, needed - stored.count))
        }
        offsets = sized(try container.decode([CGPoint].self, forKey: .offsets))
        scanOffsets = sized(try container.decodeIfPresent([CGPoint].self,
                                                          forKey: .scanOffsets) ?? [])
    }

    var pointsAcross: Int { columns + 1 }
    var pointsDown: Int { rows + 1 }
    var pointCount: Int { pointsAcross * pointsDown }
    var cellCount: Int { columns * rows }
    var isSubdivided: Bool { columns > 1 || rows > 1 }
    var isWarped: Bool { effectiveOffsets.contains { $0.x != 0 || $0.y != 0 } }
    var hasScanCorrection: Bool { scanOffsets.contains { $0.x != 0 || $0.y != 0 } }

    /// What the renderer and the handles actually use: hand plus scan.
    var effectiveOffsets: [CGPoint] {
        zip(offsets, scanOffsets).map { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
    }

    func effectiveOffset(at index: Int) -> CGPoint {
        let hand = offset(at: index)
        let scan = scanOffsets.indices.contains(index) ? scanOffsets[index] : .zero
        return CGPoint(x: hand.x + scan.x, y: hand.y + scan.y)
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

    func index(column: Int, row: Int) -> Int { row * pointsAcross + column }

    /// The hand-dragged offset of a point. For what is drawn, use
    /// `effectiveOffset(at:)`, which includes any scan correction.
    func offset(column: Int, row: Int) -> CGPoint {
        offset(at: index(column: column, row: row))
    }

    mutating func setOffset(_ offset: CGPoint, column: Int, row: Int) {
        let i = index(column: column, row: row)
        guard offsets.indices.contains(i) else { return }
        offsets[i] = offset
    }

    func offset(at index: Int) -> CGPoint {
        offsets.indices.contains(index) ? offsets[index] : .zero
    }

    mutating func setOffset(_ offset: CGPoint, at index: Int) {
        guard offsets.indices.contains(index) else { return }
        offsets[index] = offset
    }

    mutating func reset() {
        offsets = Array(repeating: .zero, count: pointCount)
        scanOffsets = Array(repeating: .zero, count: pointCount)
    }

    /// Normalized (u, v) of a control point inside the layer.
    func parameter(column: Int, row: Int) -> CGPoint {
        CGPoint(x: Double(column) / Double(columns), y: Double(row) / Double(rows))
    }

    /// Changes the grid size, resampling the existing correction so the surface keeps
    /// its shape. Going from 2x2 to 4x4 mid-alignment would otherwise throw away the
    /// work done so far.
    func resized(columns newColumns: Int, rows newRows: Int) -> MeshWarp {
        let clampedColumns = max(1, min(Self.maximumDivisions, newColumns))
        let clampedRows = max(1, min(Self.maximumDivisions, newRows))
        guard clampedColumns != columns || clampedRows != rows else { return self }

        var resized = MeshWarp(columns: clampedColumns, rows: clampedRows)
        guard isWarped else { return resized }

        var hand = resized.offsets
        var scan = resized.scanOffsets
        for row in 0...clampedRows {
            for column in 0...clampedColumns {
                let u = Double(column) / Double(clampedColumns)
                let v = Double(row) / Double(clampedRows)
                let index = resized.index(column: column, row: row)
                hand[index] = sampledOffset(u: u, v: v, in: offsets)
                scan[index] = sampledOffset(u: u, v: v, in: scanOffsets)
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

    private func sampledOffset(u: Double, v: Double, in field: [CGPoint]) -> CGPoint {
        let x = min(max(u, 0), 1) * Double(columns)
        let y = min(max(v, 0), 1) * Double(rows)
        let column = min(Int(x), columns - 1)
        let row = min(Int(y), rows - 1)
        let fx = x - Double(column)
        let fy = y - Double(row)

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

    private enum CodingKeys: String, CodingKey {
        case columns, rows, offsets, scanOffsets
    }
}

/// One cell of a warped layer: where it lands on the canvas, and which part of the
/// layer's texture belongs to it.
struct MeshCell: Equatable {
    var quad: Quad
    var uvOrigin: CGPoint
    var uvSize: CGSize
}
