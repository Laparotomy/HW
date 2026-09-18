import ARKit
import CoreImage
import CoreVideo
import Foundation
import UIKit
import os

/// 65 x 49 keeps the 4:3 sensor ratio, is finer than any mesh the warp uses, and
/// costs about 25 KB inside a project file. Declared outside the actor-isolated
/// class so the depth sampler can stay on the camera's own queue.
private let depthColumns = 65
private let depthRows = 49
/// Coverage is a reassurance for the operator, not a measurement, so it is sampled a
/// few times a second rather than on all sixty frames.
private let coverageInterval: TimeInterval = 0.25

/// Captures what the surface looks like, and where it is.
///
/// Two things come out of a capture, and they are worth keeping separate because
/// only one of them needs special hardware:
///
/// - **A reference photo**, on every iPhone ARKit runs on. Held at the projector and
///   shown under the stage, it is the single most useful thing here: you map against
///   the actual wall instead of against a memory of it.
/// - **A depth grid**, only on iPhones with a LiDAR scanner. This is what carries the
///   shape of a curved or stepped surface, and what `ScanSolver` turns into a warp.
///
/// The distinction is surfaced rather than hidden. An app that quietly produced a
/// flat warp on a non-LiDAR phone would look broken; one that says "this phone can
/// photograph the surface but not measure it" is merely honest about the hardware.
@MainActor
final class SurfaceScanner: NSObject, ObservableObject {

    enum Capability: Equatable {
        /// ARKit will not run here at all.
        case unsupported
        /// Camera only: a reference photo, no measurements.
        case referenceOnly
        /// LiDAR present: reference photo plus depth.
        case depth

        var headline: String {
            switch self {
            case .unsupported: return "Scanning is not available on this device"
            case .referenceOnly: return "Reference photo"
            case .depth: return "Reference photo and depth"
            }
        }

        var detail: String {
            switch self {
            case .unsupported:
                return "This device cannot run the camera tracking a scan needs."
            case .referenceOnly:
                return "This iPhone has no LiDAR scanner, so it can photograph the "
                    + "surface but not measure its shape. The photo still does the "
                    + "main job: map against what you can see."
            case .depth:
                return "The LiDAR scanner measures the surface, so a layer can be bent "
                    + "to follow its curves as well as lined up by eye."
            }
        }
    }

    enum ScanError: LocalizedError {
        case notRunning
        case noFrame
        case imageEncodingFailed

        var errorDescription: String? {
            switch self {
            case .notRunning: return "The camera is not running."
            case .noFrame: return "The camera has not produced a frame yet. Give it a moment."
            case .imageEncodingFailed: return "That frame could not be saved."
            }
        }
    }

    /// One capture, before it has been written into a project.
    struct Capture {
        var imageData: Data
        var camera: ScanCamera
        var depth: DepthGrid?
    }

    let session = ARSession()

    @Published private(set) var capability: Capability = .unsupported
    @Published private(set) var isRunning = false
    /// Rolling estimate of how much of the frame is returning depth, so the operator
    /// can see the scan improving rather than guessing.
    @Published private(set) var depthCoverage: Double = 0

    private let context = CIContext()
    private let log = Logger(subsystem: "app.videomapper", category: "Scan")
    /// Written and read only on the AR session's delegate queue.
    private nonisolated(unsafe) var lastCoverageUpdate: TimeInterval = 0

    override init() {
        super.init()
        session.delegate = self
        capability = Self.detectCapability()
    }

    static func detectCapability() -> Capability {
        guard ARWorldTrackingConfiguration.isSupported else { return .unsupported }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { return .depth }
        return .referenceOnly
    }

    func start() {
        guard capability != .unsupported else { return }
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.vertical, .horizontal]
        if capability == .depth {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func stop() {
        session.pause()
        isRunning = false
    }

    /// Freezes the current frame into something a project can store.
    func capture() throws -> Capture {
        guard isRunning else { throw ScanError.notRunning }
        guard let frame = session.currentFrame else { throw ScanError.noFrame }

        guard let imageData = encodeReferenceImage(frame.capturedImage) else {
            throw ScanError.imageEncodingFailed
        }

        let resolution = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let camera = ScanCamera(focalX: Double(intrinsics[0][0]),
                                focalY: Double(intrinsics[1][1]),
                                principalX: Double(intrinsics[2][0]),
                                principalY: Double(intrinsics[2][1]),
                                imageWidth: Double(resolution.width),
                                imageHeight: Double(resolution.height))

        let depth = frame.sceneDepth.flatMap { Self.sampleDepth($0.depthMap) }
        return Capture(imageData: imageData, camera: camera, depth: depth)
    }

    /// The captured frame is YCbCr in sensor orientation. It is kept that way rather
    /// than rotated: the intrinsics above describe the sensor frame, and a reference
    /// photo that does not match its own camera model is worse than none.
    private func encodeReferenceImage(_ buffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
    }

    /// Resamples ARKit's depth map onto the fixed grid a project stores.
    ///
    /// Nearest-neighbour rather than averaging: a depth map's zeros are "no reading",
    /// not "zero metres", and averaging them into a neighbour invents a surface that
    /// is not there.
    nonisolated static func sampleDepth(_ buffer: CVPixelBuffer) -> DepthGrid? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32
        else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 1, height > 1,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        var depths = [Double](repeating: 0, count: depthColumns * depthRows)
        for row in 0..<depthRows {
            let y = min(height - 1, Int((Double(row) / Double(depthRows - 1)) * Double(height - 1)))
            let rowBase = base.advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: Float32.self)
            for column in 0..<depthColumns {
                let x = min(width - 1,
                            Int((Double(column) / Double(depthColumns - 1)) * Double(width - 1)))
                let value = Double(rowBase[x])
                // ARKit reports unmeasured samples as zero, and occasionally as a
                // NaN or an absurd distance when the confidence is bottoming out.
                depths[row * depthColumns + column] =
                    (value.isFinite && value > 0.05 && value < 30) ? value : 0
            }
        }
        return DepthGrid(columns: depthColumns, rows: depthRows, depths: depths)
    }
}

extension SurfaceScanner: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frame.timestamp - lastCoverageUpdate >= coverageInterval else { return }
        lastCoverageUpdate = frame.timestamp
        guard let depthMap = frame.sceneDepth?.depthMap,
              let grid = Self.sampleDepth(depthMap) else { return }
        let coverage = grid.coverage
        Task { @MainActor [weak self] in
            self?.depthCoverage = coverage
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.isRunning = false
            self?.log.error("AR session failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
