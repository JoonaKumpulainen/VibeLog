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

/// Reports every touch that begins anywhere in its window, without taking it from the views
/// that handle it. Buttons, dials and drags all count, which a SwiftUI tap gesture misses.
struct TouchWatcher: UIViewRepresentable {
    let onTouch: () -> Void

    final class WatchingView: UIView {
        var onTouch: () -> Void = {}
        private var recognizer: Recognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            guard let window else { return }
            let added = Recognizer { [weak self] in self?.onTouch() }
            window.addGestureRecognizer(added)
            recognizer = added
        }
    }

    /// Never recognizes, so it never delays or cancels another view's touches.
    final class Recognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private let began: () -> Void

        init(began: @escaping () -> Void) {
            self.began = began
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            began()
            state = .failed
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }

    func makeUIView(context: Context) -> WatchingView {
        let view = WatchingView()
        view.isUserInteractionEnabled = false
        view.onTouch = onTouch
        return view
    }

    func updateUIView(_ view: WatchingView, context: Context) {
        view.onTouch = onTouch
    }
}
