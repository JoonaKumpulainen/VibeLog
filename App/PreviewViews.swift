import AVFoundation
import MetalKit
import SwiftUI
import VLProcessing

/// The ISP preview from the capture session. Hidden, it stays connected and keeps working;
/// disconnected, it leaves the session, which never changes during a take.
struct SessionPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var hidden = false
    var connected = true
    var holdsState = false

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = connected ? session : nil
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        view.isHidden = hidden
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.isHidden = hidden
        if !holdsState, connected != (view.previewLayer.session != nil) {
            view.previewLayer.session = connected ? session : nil
        }
        view.setNeedsLayout()
    }
}

/// The GPU pipeline's output, in log or through the Rec.709 monitoring LUT. The drawable
/// keeps the size the 10-minute recording was proven with, so a larger viewfinder adds no GPU load.
struct ProcessedMonitor: UIViewRepresentable {
    let pipeline: ProcessingPipeline

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        pipeline.attach(to: view)
        view.backgroundColor = .black
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 972, height: 1296)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}
