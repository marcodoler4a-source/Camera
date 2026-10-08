import SwiftUI
import AVFoundation
import Photos
import CoreImage
import UIKit

final class DualCameraEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureMultiCamSession()
    let rearLayer = AVCaptureVideoPreviewLayer()
    let frontLayer = AVCaptureVideoPreviewLayer()
    @Published var error: String?
    @Published var recording = false
    @Published var capturingPhoto = false
    @Published var saving = false
    var split = false
    var frontPrimary = false

    private let queue = DispatchQueue(label: "camera.dual.capture")
    private let rearOutput = AVCaptureVideoDataOutput()
    private let frontOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var configured = false
    private var rearFrame: CIImage?
    private var frontFrame: CIImage?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private var outputURL: URL?
    private let outputSize = CGSize(width: 720, height: 1280)

    func start() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            error = "Simultaneous cameras are not supported on this device."
            return
        }
        queue.async {
            if !self.configured { self.configure() }
            if self.configured && !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async {
            if self.recording { self.finishRecording() }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func setLayout(split: Bool, frontPrimary: Bool) {
        queue.async { self.split = split; self.frontPrimary = frontPrimary }
    }

    private func configure() {
        guard let rear = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let rearInput = try? AVCaptureDeviceInput(device: rear),
              let frontInput = try? AVCaptureDeviceInput(device: front) else {
            DispatchQueue.main.async { self.error = "Front or back camera unavailable." }
            return
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(rearInput) else {
            DispatchQueue.main.async { self.error = "Rear camera unavailable for simultaneous capture." }
            return
        }
        session.addInputWithNoConnections(rearInput)
        guard session.canAddInput(frontInput) else {
            DispatchQueue.main.async { self.error = "Front camera unavailable for simultaneous capture." }
            return
        }
        session.addInputWithNoConnections(frontInput)
        let entries: [(AVCaptureDeviceInput, AVCaptureVideoPreviewLayer, AVCaptureVideoDataOutput)] = [
            (rearInput, rearLayer, rearOutput), (frontInput, frontLayer, frontOutput)
        ]
        for (input, layer, output) in entries {
            guard let port = input.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: input.device.position).first else { return }
            layer.setSessionWithNoConnection(session)
            layer.videoGravity = .resizeAspectFill
            let previewConnection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
            guard session.canAddConnection(previewConnection) else { return }
            session.addConnection(previewConnection)
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { return }
            session.addOutputWithNoConnections(output)
            let videoConnection = AVCaptureConnection(inputPorts: [port], output: output)
            guard session.canAddConnection(videoConnection) else { return }
            session.addConnection(videoConnection)
        }
        configured = true
    }

    func toggleRecording() {
        queue.async {
            if self.recording { self.finishRecording() }
            else { self.beginRecording() }
        }
    }

    // Capture the latest simultaneous front and rear frames into a single photo.
    func takePhoto() {
        queue.async {
            guard self.configured, self.session.isRunning,
                  let rear = self.rearFrame, let front = self.frontFrame else {
                DispatchQueue.main.async { self.error = "Wait for both camera previews before taking a photo." }
                return
            }
            DispatchQueue.main.async { self.capturingPhoto = true }
            let canvas = CGRect(origin: .zero, size: self.outputSize)
            let main = self.frontPrimary ? front : rear
            let small = self.frontPrimary ? rear : front
            let composite: CIImage
            if self.split {
                let left = CGRect(x: 0, y: 0, width: canvas.width / 2, height: canvas.height)
                let right = CGRect(x: canvas.width / 2, y: 0, width: canvas.width / 2, height: canvas.height)
                composite = self.fitted(small, into: right).composited(over: self.fitted(main, into: left))
            } else {
                let inset = CGRect(x: canvas.width * 0.59, y: canvas.height * 0.67,
                                   width: canvas.width * 0.37, height: canvas.height * 0.29)
                composite = self.fitted(small, into: inset).composited(over: self.fitted(main, into: canvas))
            }
            guard let cgImage = self.ciContext.createCGImage(composite, from: canvas),
                  let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95) else {
                DispatchQueue.main.async { self.capturingPhoto = false; self.error = "Could not render dual-camera photo." }
                return
            }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    DispatchQueue.main.async { self.capturingPhoto = false; self.error = "Allow Photos access to save the picture." }
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                }) { success, error in
                    DispatchQueue.main.async {
                        self.capturingPhoto = false
                        if !success { self.error = error?.localizedDescription ?? "Could not save dual-camera photo." }
                    }
                }
            }
        }
    }

    private func beginRecording() {
        guard configured, session.isRunning else {
            DispatchQueue.main.async { self.error = "Wait for both camera previews to start." }
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dual-\(UUID().uuidString).mov")
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(outputSize.width),
                AVVideoHeightKey: Int(outputSize.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000]
            ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
            guard writer.canAdd(input) else { throw NSError(domain: "DualCamera", code: 1) }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? NSError(domain: "DualCamera", code: 2) }
            self.writer = writer
            self.writerInput = input
            self.adaptor = adaptor
            self.outputURL = url
            self.startTime = nil
            DispatchQueue.main.async { self.recording = true }
        } catch {
            DispatchQueue.main.async { self.error = error.localizedDescription }
        }
    }

    private func finishRecording() {
        guard let writer = writer, let input = writerInput else { return }
        self.writer = nil
        self.writerInput = nil
        self.adaptor = nil
        self.startTime = nil
        DispatchQueue.main.async { self.recording = false; self.saving = true }
        input.markAsFinished()
        let url = outputURL
        writer.finishWriting {
            guard writer.status == .completed, let url = url else {
                DispatchQueue.main.async { self.saving = false; self.error = writer.error?.localizedDescription ?? "Recording could not be saved." }
                return
            }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    DispatchQueue.main.async { self.saving = false; self.error = "Allow Photos access to save the recording." }
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { success, error in
                    try? FileManager.default.removeItem(at: url)
                    DispatchQueue.main.async {
                        self.saving = false
                        if !success { self.error = error?.localizedDescription ?? "Failed to save video." }
                    }
                }
            }
        }
    }

    private func fitted(_ image: CIImage, into rect: CGRect) -> CIImage {
        let extent = image.extent
        let scale = max(rect.width / extent.width, rect.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let center = scaled.extent
        return scaled.transformed(by: CGAffineTransform(translationX: rect.midX - center.midX, y: rect.midY - center.midY)).cropped(to: rect)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        if output === rearOutput { rearFrame = image } else { frontFrame = image }
        guard output === rearOutput, let rear = rearFrame, let front = frontFrame,
              let writer = writer, let input = writerInput, let adaptor = adaptor,
              input.isReadyForMoreMediaData else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTime == nil { startTime = timestamp; writer.startSession(atSourceTime: timestamp) }
        guard let startTime = startTime else { return }
        let elapsed = CMTimeSubtract(timestamp, startTime)
        guard elapsed.isValid, elapsed.seconds >= 0, let pool = adaptor.pixelBufferPool else { return }
        var optionalBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &optionalBuffer) == kCVReturnSuccess,
              let destination = optionalBuffer else { return }
        let canvas = CGRect(origin: .zero, size: outputSize)
        let main = frontPrimary ? front : rear
        let small = frontPrimary ? rear : front
        let base: CIImage
        if split {
            let left = CGRect(x: 0, y: 0, width: canvas.width / 2, height: canvas.height)
            let right = CGRect(x: canvas.width / 2, y: 0, width: canvas.width / 2, height: canvas.height)
            base = fitted(small, into: right).composited(over: fitted(main, into: left))
        } else {
            let inset = CGRect(x: canvas.width * 0.59, y: canvas.height * 0.67, width: canvas.width * 0.37, height: canvas.height * 0.29)
            base = fitted(small, into: inset).composited(over: fitted(main, into: canvas))
        }
        ciContext.render(base, to: destination, bounds: canvas, colorSpace: CGColorSpaceCreateDeviceRGB())
        adaptor.append(destination, withPresentationTime: elapsed)
    }
}

struct DualPreviewSurface: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    func makeUIView(context: Context) -> DualPreviewHost { DualPreviewHost(layer: previewLayer) }
    func updateUIView(_ uiView: DualPreviewHost, context: Context) { uiView.setPreviewLayer(previewLayer) }
}
final class DualPreviewHost: UIView {
    private var cameraLayer: AVCaptureVideoPreviewLayer
    init(layer: AVCaptureVideoPreviewLayer) {
        cameraLayer = layer
        super.init(frame: .zero)
        self.layer.addSublayer(layer)
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func setPreviewLayer(_ newLayer: AVCaptureVideoPreviewLayer) {
        if cameraLayer !== newLayer {
            cameraLayer.removeFromSuperlayer()
            cameraLayer = newLayer
            layer.addSublayer(newLayer)
        }
        cameraLayer.frame = bounds
    }
    override func layoutSubviews() { super.layoutSubviews(); cameraLayer.frame = bounds }
}

struct DualCameraView: View {
    @StateObject private var engine = DualCameraEngine()
    @State private var photoMode = false
    @State private var split = false
    @State private var frontPrimary = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    DualPreviewSurface(previewLayer: engine.rearLayer)
                        .frame(width: split ? geometry.size.width / 2 : (frontPrimary ? geometry.size.width * 0.36 : geometry.size.width),
                               height: split ? geometry.size.height : (frontPrimary ? geometry.size.height * 0.29 : geometry.size.height))
                        .clipShape(RoundedRectangle(cornerRadius: split || !frontPrimary ? 0 : 16))
                        .offset(x: split ? 0 : (frontPrimary ? geometry.size.width * 0.60 : 0),
                                y: split ? 0 : (frontPrimary ? 16 : 0))
                        .zIndex(frontPrimary ? 2 : 0)
                    DualPreviewSurface(previewLayer: engine.frontLayer)
                        .frame(width: split ? geometry.size.width / 2 : (frontPrimary ? geometry.size.width : geometry.size.width * 0.36),
                               height: split ? geometry.size.height : (frontPrimary ? geometry.size.height : geometry.size.height * 0.29))
                        .clipShape(RoundedRectangle(cornerRadius: split || frontPrimary ? 0 : 16))
                        .offset(x: split ? geometry.size.width / 2 : (frontPrimary ? 0 : geometry.size.width * 0.60),
                                y: split ? 0 : (frontPrimary ? 0 : 16))
                        .zIndex(frontPrimary ? 0 : 2)
                }
            }
            VStack {
                HStack {
                    Button { dismiss() } label: { Label("Close", systemImage: "xmark.circle.fill") }
                    Spacer()
                    Button {
                        frontPrimary.toggle()
                        engine.setLayout(split: split, frontPrimary: frontPrimary)
                    } label: { Label("Swap", systemImage: "arrow.triangle.2.circlepath.camera") }
                    Button {
                        split.toggle()
                        engine.setLayout(split: split, frontPrimary: frontPrimary)
                    } label: { Label(split ? "PiP" : "Split", systemImage: "rectangle.split.2x1") }
                }
                .padding(20)
                .background(.black.opacity(0.55))
                Spacer()
                if engine.saving { ProgressView("Saving to Photos…").tint(.white).padding() }
                if engine.capturingPhoto { ProgressView("Saving photo…").tint(.white).padding() }
                Picker("Capture mode", selection: $photoMode) {
                    Text("VIDEO").tag(false)
                    Text("PHOTO").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 230)
                .padding(.bottom, 12)
                Button { if photoMode { engine.takePhoto() } else { engine.toggleRecording() } } label: {
                    Image(systemName: photoMode ? "circle.inset.filled" : (engine.recording ? "stop.circle.fill" : "record.circle"))
                        .font(.system(size: 65))
                        .foregroundStyle(engine.recording ? .red : .white)
                }
                .disabled(engine.saving || engine.capturingPhoto)
                .padding(.bottom, 30)
                Text(photoMode ? "DUAL CAMERA • PHOTO" : (engine.recording ? "RECORDING BOTH CAMERAS" : "DUAL CAMERA • VIDEO"))
                    .font(.caption.bold()).tracking(1)
                    .padding(10)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(.bottom, 18)
            }
            .foregroundStyle(.white)
        }
        .onAppear {
            // Allow the single-camera capture session time to release its devices.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { engine.start() }
        }
        .onDisappear { engine.stop() }
        .alert("Dual Camera", isPresented: Binding(get: { engine.error != nil }, set: { if !$0 { engine.error = nil } })) {
            Button("OK", role: .cancel) { engine.error = nil }
        } message: { Text(engine.error ?? "") }
    }
}
