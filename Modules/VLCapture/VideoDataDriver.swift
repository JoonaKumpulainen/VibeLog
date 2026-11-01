import AVFoundation
import VLCore

/// Streams from AVCaptureVideoDataOutput. With a non-RAW format this is the control
/// run that shows what the recording path can sustain.
final class VideoDataDriver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((RawFrame) -> Void)?
    var onDrop: ((String) -> Void)?

    private let device: AVCaptureDevice
    let queue = DispatchQueue(label: "vibelog.video-data", qos: .userInitiated)

    init(device: AVCaptureDevice) {
        self.device = device
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let gains = device.deviceWhiteBalanceGains
        onFrame?(RawFrame(
            buffer: buffer,
            pts: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
            exposureSeconds: CMTimeGetSeconds(device.exposureDuration), iso: device.iso,
            whiteBalanceGains: [gains.redGain, gains.greenGain, gains.blueGain]))
    }

    func captureOutput(
        _ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let reason = CMGetAttachment(
            sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil)
        onDrop?(reason.map { String(describing: $0) } ?? "unknown")
    }
}
