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
    /// Offsets for `(columns + 1) * (rows + 1)` points in row-major order, in
    /// normalized canvas units.
    private(set) var offsets: [CGPoint]

    /// Grid sizes offered in the UI. Capped at 8 because each cell is its own draw
    /// call — 8 x 8 is 64 per layer, which is already a lot to spend on one surface.
    static let availableDivisions = [1, 2, 3, 4, 6, 8]
    static let maximumDivisions = 8

    init(columns: Int = 1, rows: Int = 1) {
        self.columns = max(1, min(Self.maximumDivisions, columns))
        self.rows = max(1, min(Self.maximumDivisions, rows))
        offsets = Array(repeating: .zero, count: (self.columns + 1) * (self.rows + 1))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedColumns = try container.decode(Int.self, forKey: .columns)
        let storedRows = try container.decode(Int.self, forKey: .rows)
        columns = max(1, min(Self.maximumDivisions, storedColumns))
        rows = max(1, min(Self.maximumDivisions, storedRows))
        let stored = try container.decode([CGPoint].self, forKey: .offsets)
        // A file written by a newer version, or simply corrupt, must not be able to
        // index the renderer out of bounds.
        let needed = (columns + 1) * (rows + 1)
        offsets = stored.count == needed
            ? stored
            : Array(stored.prefix(needed)) + Array(repeating: .zero,
                                                   count: max(0, needed - stored.count))
    }

    var pointsAcross: Int { columns + 1 }
    var pointsDown: Int { rows + 1 }
    var pointCount: Int { pointsAcross * pointsDown }
    var cellCount: Int { columns * rows }
    var isSubdivided: Bool { columns > 1 || rows > 1 }
    var isWarped: Bool { offsets.contains { $0.x != 0 || $0.y != 0 } }

    func index(column: Int, row: Int) -> Int { row * pointsAcross + column }

    func offset(column: Int, row: Int) -> CGPoint {
        let i = index(column: column, row: row)
        return offsets.indices.contains(i) ? offsets[i] : .zero
    }

    mutating func setOffset(_ offset: CGPoint, column: Int, row: Int) {
        let i = index(column: column, row: row)
        guard offsets.indices.contains(i) else { return }
        offsets[i] = offset
    }

    mutating func setOffset(_ offset: CGPoint, at index: Int) {
        guard offsets.indices.contains(index) else { return }
        offsets[index] = offset
    }

    mutating func reset() {
        offsets = Array(repeating: .zero, count: pointCount)
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

        for row in 0...clampedRows {
            for column in 0...clampedColumns {
                let u = Double(column) / Double(clampedColumns)
                let v = Double(row) / Double(clampedRows)
                resized.setOffset(sampledOffset(u: u, v: v), column: column, row: row)
            }
        }
        return resized
    }

    /// Bilinear sample of the offset field at a normalized position.
    func sampledOffset(u: Double, v: Double) -> CGPoint {
        let x = min(max(u, 0), 1) * Double(columns)
        let y = min(max(v, 0), 1) * Double(rows)
        let column = min(Int(x), columns - 1)
        let row = min(Int(y), rows - 1)
        let fx = x - Double(column)
        let fy = y - Double(row)

        let topLeft = offset(column: column, row: row)
        let topRight = offset(column: column + 1, row: row)
        let bottomLeft = offset(column: column, row: row + 1)
        let bottomRight = offset(column: column + 1, row: row + 1)

        let top = CGPoint(x: topLeft.x + (topRight.x - topLeft.x) * fx,
                          y: topLeft.y + (topRight.y - topLeft.y) * fx)
        let bottom = CGPoint(x: bottomLeft.x + (bottomRight.x - bottomLeft.x) * fx,
                             y: bottomLeft.y + (bottomRight.y - bottomLeft.y) * fx)
        return CGPoint(x: top.x + (bottom.x - top.x) * fy,
                       y: top.y + (bottom.y - top.y) * fy)
    }

    private enum CodingKeys: String, CodingKey {
        case columns, rows, offsets
    }
}

/// One cell of a warped layer: where it lands on the canvas, and which part of the
/// layer's texture belongs to it.
struct MeshCell: Equatable {
    var quad: Quad
    var uvOrigin: CGPoint
    var uvSize: CGSize
}
