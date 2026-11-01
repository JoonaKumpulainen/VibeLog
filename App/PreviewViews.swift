import AVFoundation
import MetalKit
import SwiftUI
import VLProcessing

/// The ISP preview from the capture session.
struct SessionPreview: UIViewRepresentable {
    let session: AVCaptureSession

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
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.setNeedsLayout()
    }
}

/// The crude debayer of the newest RAW frame, proving the sensor data is real.
struct RawMonitor: UIViewRepresentable {
    let renderer: RawPreviewRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        renderer.attach(to: view)
        view.backgroundColor = .black
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}
