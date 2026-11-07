import AVFoundation
import UIKit

@available(iOS 7.0, *)
final class FeedQRScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    enum Outcome {
        case scanned(String)
        case unavailable(String)
        case cancelled
    }

    private let onFinish: (Outcome) -> Void
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "org.podcold.feed-qr-camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var finished = false

    init(onFinish: @escaping (Outcome) -> Void) {
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Scan Feed QR Code"
        edgesForExtendedLayout = []
        view.backgroundColor = .black
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard preview == nil, !finished else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self, !self.finished else { return }
                    if granted { self.startCamera() } else { self.cameraAccessDenied() }
                }
            }
        default:
            cameraAccessDenied()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        sessionQueue.async { [session] in session.stopRunning() }
    }

    private func startCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            cameraUnavailable()
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { cameraUnavailable(); return }
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else { cameraUnavailable(); return }
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let connection = layer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer

        sessionQueue.async { [weak self, session] in
            session.startRunning()
            if !session.isRunning {
                DispatchQueue.main.async { [weak self] in self?.cameraUnavailable() }
            }
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for object in metadataObjects {
            if let code = object as? AVMetadataMachineReadableCodeObject, let text = code.stringValue {
                finish(.scanned(text))
                return
            }
        }
    }

    @objc private func cancel() { finish(.cancelled) }

    private func cameraUnavailable() {
        finish(.unavailable("The camera could not scan a QR code. You can paste the feed link instead."))
    }

    private func cameraAccessDenied() {
        finish(.unavailable("Camera access is unavailable. Check Settings or paste the feed link."))
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        dismiss(animated: true) { [onFinish] in onFinish(outcome) }
    }
}
