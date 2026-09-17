import CoreGraphics
import Foundation

/// Pulls a dragged control point onto nearby ones so adjacent surfaces meet exactly.
///
/// The reason this matters is specific to projection: two layers whose edges are a
/// pixel apart leave a black hairline on the wall, and two that overlap by a pixel
/// leave a bright one. Neither is fixable by eye at the distance you usually stand
/// from a projector, and both are obvious to the audience. Landing the points on the
/// same coordinate is the only thing that removes the seam outright.
enum PointSnapping {

    /// What a point was pulled onto, so the stage can say why it moved.
    enum Target: Equatable {
        /// A control point or corner belonging to another layer.
        case otherLayer(name: String)
        /// Another point on the same layer — which lines up a fold or a return.
        case sameLayer
        /// An edge or the centre line of the canvas.
        case canvasGuide

        var label: String {
            switch self {
            case .otherLayer(let name): return name
            case .sameLayer: return "Same layer"
            case .canvasGuide: return "Canvas"
            }
        }
    }

    struct Result: Equatable {
        var position: CGPoint
        var target: Target
    }

    /// A candidate the drag can land on.
    struct Candidate: Equatable {
        var position: CGPoint
        var target: Target
    }

    /// How close, in normalized canvas units, a drag has to come before it is pulled
    /// in. Converted from a fingertip-sized distance on screen by the caller, because
    /// what counts as "close" depends on how large the stage is drawn.
    static let defaultRadius: Double = 0.02

    /// Every point another layer offers to snap to: its corners and, if it has one,
    /// its correction grid.
    static func candidates(in layers: [MappingLayer], excluding excludedID: UUID?) -> [Candidate] {
        var candidates: [Candidate] = []
        for layer in layers where layer.id != excludedID && layer.isVisible {
            let target = Target.otherLayer(name: layer.name)
            if layer.transform.mesh.isSubdivided {
                for point in layer.transform.meshPoints() {
                    candidates.append(Candidate(position: point, target: target))
                }
            } else {
                for corner in layer.transform.quad().corners {
                    candidates.append(Candidate(position: corner, target: target))
                }
            }
        }
        return candidates
    }

    /// The canvas's own edges, corners and centre lines.
    ///
    /// Included because the commonest alignment of all is "flush with the edge of the
    /// projector's frame", and hitting that by eye costs more attempts than it should.
    static func canvasCandidates(near position: CGPoint) -> [Candidate] {
        let guides: [Double] = [0, 0.5, 1]
        var candidates: [Candidate] = []
        for x in guides {
            candidates.append(Candidate(position: CGPoint(x: x, y: position.y),
                                        target: .canvasGuide))
        }
        for y in guides {
            candidates.append(Candidate(position: CGPoint(x: position.x, y: y),
                                        target: .canvasGuide))
        }
        // Corners, where both guides meet, are worth offering as a single exact stop.
        for x in guides {
            for y in guides {
                candidates.append(Candidate(position: CGPoint(x: x, y: y),
                                            target: .canvasGuide))
            }
        }
        return candidates
    }

    /// Points on the dragged layer itself, other than the one being moved.
    static func selfCandidates(of transform: LayerTransform, excluding index: Int?) -> [Candidate] {
        guard transform.mesh.isSubdivided else { return [] }
        return transform.meshPoints().enumerated().compactMap { offset, point in
            guard offset != index else { return nil }
            return Candidate(position: point, target: .sameLayer)
        }
    }

    /// Chooses the nearest candidate inside `radius`, or nil to leave the drag alone.
    ///
    /// Nearest rather than first: with several layers meeting at a corner the one
    /// under the finger is the one meant, and preferring whichever happened to be
    /// earlier in the list would make the pull feel arbitrary.
    ///
    /// `aspect` is the canvas's width over its height. Normalized coordinates are
    /// stretched by it, so without the correction a snap on a 16:9 canvas would reach
    /// nearly twice as far sideways as it does vertically — the pull would feel
    /// lopsided in exactly the way a projector makes obvious.
    static func snap(_ position: CGPoint, to candidates: [Candidate],
                     radius: Double = defaultRadius, aspect: Double = 1) -> Result? {
        let scaleX = aspect.isFinite && aspect > 0 ? aspect : 1
        var best: Result?
        var bestDistance = radius
        for candidate in candidates {
            let dx = (candidate.position.x - position.x) * scaleX
            let dy = candidate.position.y - position.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < bestDistance {
                bestDistance = distance
                best = Result(position: candidate.position, target: candidate.target)
            }
        }
        return best
    }
}
