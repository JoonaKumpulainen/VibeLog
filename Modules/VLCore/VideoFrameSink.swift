import CoreMedia
import CoreVideo

/// Receives finished 10-bit YCbCr frames from the GPU pipeline. Called off the main thread.
public protocol VideoFrameSink: AnyObject {
    /// A biplanar buffer to render into, or nil to drop this frame.
    func nextPixelBuffer() -> CVPixelBuffer?
    func append(_ buffer: CVPixelBuffer, at time: CMTime)
}
