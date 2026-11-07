import AVFoundation
import CoreVideo

/// Plays a take with a look, through the same decode and look step the export uses, so what plays
/// is what the export writes. The take's own audio plays alongside.
public enum LookPlayback {
    /// Playback is drawn at most this wide, which is plenty for the screen and keeps it at the take's rate.
    static let maximumWidth = 1920

    /// A composition for `asset` that draws every frame through `exporter`'s look, and hands the
    /// frames it draws to `scope` to measure.
    public static func composition(
        for asset: AVAsset, exporter: LookExporter, scope: PictureScope? = nil
    ) async throws -> AVVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw LookExporter.Failure.noVideo
        }
        let size = try await track.load(.naturalSize)
        let rate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        // A custom compositor gets frames as stored, so the take's rotation is drawn here.
        let turns = quarterTurns(try await track.load(.preferredTransform))
        let longSide = min(Int(size.width), maximumWidth)
        let shortSide = Int((size.height * CGFloat(longSide) / max(size.width, 1)).rounded())
        let (width, height) = turns % 2 == 0 ? (longSide, shortSide) : (shortSide, longSide)

        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = LookCompositor.self
        composition.renderSize = CGSize(width: width, height: height)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(rate > 0 ? rate.rounded() : 30))
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        composition.instructions = [LookInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration), trackID: track.trackID, exporter: exporter,
            quarterTurns: turns, scope: scope)]
        return composition
    }

    /// The transform's rotation in clockwise quarter turns, as the screen shows it.
    static func quarterTurns(_ transform: CGAffineTransform) -> Int {
        let turns = Int((atan2(transform.b, transform.a) / (.pi / 2)).rounded())
        return ((turns % 4) + 4) % 4
    }
}

/// Carries the look to the compositor, which AVFoundation makes itself.
final class LookInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let exporter: LookExporter
    let quarterTurns: Int
    let scope: PictureScope?

    init(
        timeRange: CMTimeRange, trackID: CMPersistentTrackID, exporter: LookExporter, quarterTurns: Int,
        scope: PictureScope?
    ) {
        self.timeRange = timeRange
        self.scope = scope
        self.trackID = trackID
        self.exporter = exporter
        self.quarterTurns = quarterTurns
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}

/// Draws each frame on its own queue, one at a time, since the exporter reuses its log image.
final class LookCompositor: NSObject, AVVideoCompositing {
    private let queue = DispatchQueue(label: "VibeLog.lookPlayback", qos: .userInitiated)

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_4444AYpCbCr16,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            guard let instruction = request.videoCompositionInstruction as? LookInstruction,
                let frame = request.sourceFrame(byTrackID: instruction.trackID),
                let output = request.renderContext.newPixelBuffer()
            else {
                request.finish(with: LookExporter.Failure.noVideo)
                return
            }
            do {
                try instruction.exporter.render(frame, into: output, quarterTurns: instruction.quarterTurns)
                instruction.scope?.measure(output)
                request.finish(withComposedVideoFrame: output)
            } catch {
                request.finish(with: error)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}
