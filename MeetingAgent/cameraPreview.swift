import SwiftUI
import AVFoundation

struct CameraPreview: NSViewRepresentable {
    @State private var session = AVCaptureSession()

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        
        // Setup Camera
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return view }
        
        if session.canAddInput(input) { session.addInput(input) }
        
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        
        session.startRunning()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.frame = nsView.bounds
    }
}   
