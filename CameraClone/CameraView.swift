import SwiftUI
import AVFoundation
import Photos
import PhotosUI
import UIKit
import CoreImage

final class CameraEngine: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.session.queue")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var deviceInput: AVCaptureDeviceInput?
    @Published var authorized = false
    @Published var recording = false
    @Published var flash = false
    @Published var flashMode: AVCaptureDevice.FlashMode = .auto
    @Published var exposureBias: Float = 0
    @Published var front = false
    @Published var zoom: CGFloat = 1
    @Published var errorMessage: String?
    private var configured = false
    private var recordingURL: URL?
    private var recordingKind = "VIDEO"
    private var photoKind = "PHOTO"
    private var panoramaFrames: [UIImage] = []
    @Published var panoramaCount = 0
    @Published var captureMode = "PHOTO"
    func selectMode(_ name: String) {
        queue.async {
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            DispatchQueue.main.async { self.captureMode = name }
            if name == "SLO-MO" { self.configureSlowMotion() }
            else { self.configureNormalVideo() }
        }
    }
    private func configureNormalVideo() {
        guard let device = deviceInput?.device else { return }
        do {
            try device.lockForConfiguration()
            // Restore a normal capture format after Slo-Mo.
            if let standard = device.formats.first(where: {
                let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return d.width >= 1920 && $0.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30 && $0.minFrameRate <= 30 })
            }) { device.activeFormat = standard }
            device.activeVideoMinFrameDuration = .invalid
            device.activeVideoMaxFrameDuration = .invalid
            device.unlockForConfiguration()
        } catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
    }
    private func configureSlowMotion() {
        guard let device = deviceInput?.device else { return }
        // High frame rates require input-priority rather than a fixed session preset.
        if session.sessionPreset != .inputPriority {
            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            session.commitConfiguration()
        }
        let formats = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width >= 1280 && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 120 && $0.minFrameRate <= 120 }
        }
        guard let format = formats.max(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }) else {
            DispatchQueue.main.async { self.errorMessage = "120 fps slow motion is not supported by this lens." }
            return
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 120)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 120)
            device.unlockForConfiguration()
        } catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
    }
    func captureForMode(_ name: String) {
        photoKind = name
        if name == "PANO" && panoramaFrames.isEmpty { DispatchQueue.main.async { self.panoramaCount = 0 } }
        capture()
    }
    func finishPanorama() {
        let frames = panoramaFrames
        panoramaFrames.removeAll()
        DispatchQueue.main.async { self.panoramaCount = 0 }
        guard frames.count >= 2 else { DispatchQueue.main.async { self.errorMessage = "Capture at least two overlapping panorama frames." }; return }
        // Stitch frames in a continuous horizontal strip. Users should rotate steadily with overlap.
        let height: CGFloat = 1000
        let scaled = frames.map { image -> CGSize in CGSize(width: image.size.width * height / max(image.size.height, 1), height: height) }
        let totalWidth = scaled.reduce(CGFloat(0)) { $0 + $1.width * 0.65 } + (scaled.last?.width ?? 0) * 0.35
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalWidth, height: height))
        let result = renderer.image { _ in
            var x: CGFloat = 0
            for (index, image) in frames.enumerated() {
                image.draw(in: CGRect(origin: CGPoint(x: x, y: 0), size: scaled[index]))
                x += scaled[index].width * 0.65
            }
        }
        guard let data = result.jpegData(compressionQuality: 0.9) else { return }
        savePhotoData(data)
    }
    private func savePhotoData(_ data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({ PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil) }) { success, error in
                if !success { DispatchQueue.main.async { self.errorMessage = error?.localizedDescription ?? "Could not save photo." } }
            }
        }
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { self.authorized = granted }
            guard granted else { return }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.queue.async {
                    if !self.configured { self.configure() }
                    if !self.session.isRunning { self.session.startRunning() }
                }
            }
        }
    }
    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }
    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        defer { session.commitConfiguration() }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.addInput(input); deviceInput = input
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if let mic = AVCaptureDevice.default(for: .audio), let audioInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(audioInput) { session.addInput(audioInput) }
        if photoOutput.isDepthDataDeliverySupported { photoOutput.isDepthDataDeliveryEnabled = true }
        configured = true
    }
    func flip() {
        queue.async {
            guard let old = self.deviceInput else { return }
            let position: AVCaptureDevice.Position = old.device.position == .back ? .front : .back
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position), let next = try? AVCaptureDeviceInput(device: camera) else { return }
            self.session.beginConfiguration()
            self.session.removeInput(old)
            if self.session.canAddInput(next) { self.session.addInput(next); self.deviceInput = next } else { self.session.addInput(old) }
            self.session.commitConfiguration()
            DispatchQueue.main.async { self.front = position == .front; self.zoom = 1 }
        }
    }
    func setZoom(_ value: CGFloat) {
        queue.async {
            guard let old = self.deviceInput else { return }
            // The 0.5x view uses the actual ultra-wide camera, not an invalid zoom factor.
            let ultra = !self.front && value < 0.99
            let desiredType: AVCaptureDevice.DeviceType = ultra ? .builtInUltraWideCamera : .builtInWideAngleCamera
            if old.device.deviceType != desiredType {
                guard let device = AVCaptureDevice.default(desiredType, for: .video, position: self.front ? .front : .back),
                      let replacement = try? AVCaptureDeviceInput(device: device) else {
                    DispatchQueue.main.async { self.errorMessage = "This camera lens is unavailable on your device." }
                    return
                }
                self.session.beginConfiguration()
                self.session.removeInput(old)
                if self.session.canAddInput(replacement) {
                    self.session.addInput(replacement)
                    self.deviceInput = replacement
                } else { self.session.addInput(old) }
                self.session.commitConfiguration()
            }
            guard let device = self.deviceInput?.device else { return }
            let factor = ultra ? CGFloat(1) : max(1, min(value, min(CGFloat(device.activeFormat.videoMaxZoomFactor), 15)))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = factor
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoom = ultra ? 0.5 : factor }
            } catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
        }
    }
    func focus(at point: CGPoint, in size: CGSize) {
        guard size.width > 0 && size.height > 0 else { return }
        queue.async {
            guard let device = self.deviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                let target = CGPoint(x: point.y / size.height, y: 1 - point.x / size.width)
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = target; device.focusMode = .autoFocus }
                if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = target; device.exposureMode = .autoExpose }
                device.unlockForConfiguration()
            } catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
        }
    }
    func setExposure(_ bias: Float) {
        queue.async {
            guard let device = self.deviceInput?.device else { return }
            let value = max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias))
            do { try device.lockForConfiguration(); device.setExposureTargetBias(value, completionHandler: nil); device.unlockForConfiguration(); DispatchQueue.main.async { self.exposureBias = value } }
            catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
        }
    }
    func capture() {
        queue.async {
            let settings = AVCapturePhotoSettings()
            if self.photoOutput.supportedFlashModes.contains(self.flashMode) { settings.flashMode = self.flashMode }
            settings.photoQualityPrioritization = .balanced
            if self.photoKind == "PORTRAIT" && self.photoOutput.isDepthDataDeliverySupported {
                settings.isDepthDataDeliveryEnabled = true
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error { DispatchQueue.main.async { self.errorMessage = error.localizedDescription }; return }
        guard let data = photo.fileDataRepresentation() else { return }
        if photoKind == "PANO", let image = UIImage(data: data) {
            panoramaFrames.append(image)
            DispatchQueue.main.async { self.panoramaCount = self.panoramaFrames.count }
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { DispatchQueue.main.async { self.errorMessage = "Allow Photos access in Settings to save images." }; return }
            PHPhotoLibrary.shared().performChanges({ PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil) }) { success, error in
                if !success { DispatchQueue.main.async { self.errorMessage = error?.localizedDescription ?? "Could not save photo." } }
            }
        }
    }
    func toggleRecording(kind: String = "VIDEO") {
        queue.async {
            if self.movieOutput.isRecording { self.movieOutput.stopRecording(); return }
            self.recordingKind = kind
            guard self.session.isRunning, self.movieOutput.connection(with: .video) != nil else {
                DispatchQueue.main.async { self.errorMessage = "Camera video output is not ready. Please try again." }
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            self.recordingURL = url
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) { DispatchQueue.main.async { self.recording = true } }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { self.recording = false }
        if let error = error { DispatchQueue.main.async { self.errorMessage = error.localizedDescription }; return }
        if recordingKind == "SLO-MO" || recordingKind == "TIME-LAPSE" {
            let speed: Double = recordingKind == "SLO-MO" ? 0.25 : 8.0
            retimeVideo(fileURL, speed: speed)
            return
        }
        saveVideo(fileURL)
    }
    private func retimeVideo(_ url: URL, speed: Double) {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        guard let source = asset.tracks(withMediaType: .video).first,
              let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { saveVideo(url); return }
        do {
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: source, at: .zero)
            track.preferredTransform = source.preferredTransform
            track.scaleTimeRange(CMTimeRange(start: .zero, duration: asset.duration), toDuration: CMTimeMultiplyByFloat64(asset.duration, multiplier: 1.0 / speed))
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { saveVideo(url); return }
            exporter.outputURL = output
            exporter.outputFileType = .mov
            exporter.exportAsynchronously {
                if exporter.status == .completed { self.saveVideo(output); try? FileManager.default.removeItem(at: url) }
                else { self.saveVideo(url) }
            }
        } catch { saveVideo(url) }
    }
    private func saveVideo(_ fileURL: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { DispatchQueue.main.async { self.errorMessage = "Allow Photos access to save videos." }; return }
            PHPhotoLibrary.shared().performChanges({ PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL) }) { success, error in
                try? FileManager.default.removeItem(at: fileURL)
                if !success { DispatchQueue.main.async { self.errorMessage = error?.localizedDescription ?? "Could not save video." } }
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView { let v = PreviewView(); v.previewLayer.session = session; v.previewLayer.videoGravity = .resizeAspectFill; return v }
    func updateUIView(_ uiView: PreviewView, context: Context) { uiView.previewLayer.session = session }
}
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraView: View {
    @StateObject private var engine = CameraEngine()
    @State private var mode = 4
    @State private var showSettings = false
    @State private var showGrid = false
    @State private var showLevel = false
    @State private var timer = 0
    @State private var style = 0
    @State private var shutterBusy = false
    @State private var showDual = false
    @State private var gallerySelection: PhotosPickerItem?
    @State private var galleryImage: UIImage?
    @State private var showGalleryPreview = false
    @State private var showQuickControls = false
    @State private var editingControls = false
    @AppStorage("camera.hiddenQuickControls") private var hiddenQuickControls = ""
    private let quickControlNames = ["FLASH", "LIVE", "ASPECT", "TIMER", "EXPOSURE", "STYLES", "FILTER", "NIGHT", "FORMAT", "SHARED LIBRARY"]
    private func isControlHidden(_ name: String) -> Bool {
        Set(hiddenQuickControls.split(separator: "|").map(String.init)).contains(name)
    }
    private func hideControl(_ name: String) {
        var hidden = Set(hiddenQuickControls.split(separator: "|").map(String.init))
        hidden.insert(name)
        hiddenQuickControls = hidden.sorted().joined(separator: "|")
    }

    @State private var aspect = "4:3"
    @State private var filter = "None"
    @State private var nightGuide = false
    @State private var liveRequested = false
    @State private var sharedLibraryRequested = false
    @AppStorage("camera.mirrorSelfies") private var mirrorSelfies = true
    @AppStorage("camera.locationTags") private var locationTags = false
    @AppStorage("camera.preserveMode") private var preserveMode = true
    @AppStorage("camera.showHistogram") private var showHistogram = false
    @AppStorage("camera.preferHEIF") private var preferHEIF = true
    @AppStorage("camera.videoFPS") private var videoFPS = 30
    @AppStorage("camera.videoQuality") private var videoQuality = "1080p"
    private let modes = ["TIME-LAPSE", "SLO-MO", "CINEMATIC", "VIDEO", "PHOTO", "PORTRAIT", "PANO"]
    private let styles = ["Natural", "Vivid", "Mono", "Warm", "Cool"]
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(session: engine.session)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay { if showGrid { gridOverlay } }
                    .overlay { if showLevel { Rectangle().fill(.yellow.opacity(0.85)).frame(height: 1).padding(.horizontal, 30) } }
                    .overlay { if filter == "Mono" { Color.black.opacity(0.05).blendMode(.saturation) } }
                    .contentShape(Rectangle())
                    .onTapGesture { if showQuickControls { showQuickControls = false; editingControls = false } }
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        Button { editingControls.toggle(); showQuickControls = true } label: {
                            Text(editingControls ? "Done" : "Edit").font(.subheadline)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(.black.opacity(0.42), in: Capsule())
                        }
                        Spacer()
                        Button { cycleFlash() } label: { Image(systemName: flashSymbol).foregroundStyle(engine.flashMode == .off ? .white : .yellow) }
                        Button { withAnimation(.easeInOut(duration: 0.2)) { showQuickControls.toggle() } } label: { Image(systemName: "chevron.up.chevron.down") }
                        Button { showDual = true } label: { Image(systemName: "square.on.square") }
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                    .font(.title3).padding(.horizontal, 20).padding(.vertical, 14)
                    .background(.black.opacity(0.38))
                    Spacer()
                    HStack(spacing: 12) {
                        ForEach([0.5, 1.0, 3.0], id: \.self) { value in
                            Button { engine.setZoom(value) } label: {
                                Text(value == 0.5 ? ".5" : (value == 1 ? "1×" : "3"))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(abs(engine.zoom - value) < 0.12 ? .yellow : .white)
                                    .frame(width: 38, height: 38)
                                    .background(abs(engine.zoom - value) < 0.12 ? Color.black.opacity(0.36) : Color.clear, in: Circle())
                            }
                        }
                    }
                    .padding(2)
                    .padding(.bottom, 10)
                    VStack(spacing: 18) {
                        ZStack {
                            HStack {
                                PhotosPicker(selection: $gallerySelection, matching: .images) {
                                    Image(systemName: "photo.on.rectangle")
                                        .font(.title3)
                                        .frame(width: 52, height: 52)
                                        .background(Color.black.opacity(0.18), in: Circle())
                                }
                                Spacer()
                                Button { withAnimation { showQuickControls.toggle() } } label: {
                                    Image(systemName: "circle.grid.3x3.fill")
                                        .font(.title3)
                                        .frame(width: 52, height: 52)
                                        .background(.ultraThinMaterial, in: Circle())
                                }
                            }
                            shutterButton
                        }
                        .frame(height: 92)
                        HStack(spacing: 0) {
                            PhotosPicker(selection: $gallerySelection, matching: .images) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.title3).frame(width: 52, height: 52)
                            }
                            .frame(maxWidth: .infinity)
                            modePicker
                                .frame(width: min(geometry.size.width * 0.65, 285))
                            Button { engine.flip() } label: {
                                Image(systemName: "arrow.triangle.2.circlepath.camera")
                                    .font(.title2)
                                    .frame(width: 52, height: 52)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 16)
                    .padding(.bottom, 14)
                    .background(Color.black.opacity(0.12))
                }
                if showQuickControls {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { showQuickControls = false; editingControls = false } }
                    VStack(spacing: 0) {
                        quickControls
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                        Spacer()
                    }
                    .padding(.top, 56)
                    .transition(.opacity)
                }
            }
            .foregroundStyle(.white)
            .onAppear { engine.start() }
            .onDisappear { engine.stop() }
            .fullScreenCover(isPresented: $showDual) { DualCameraView() }
            .onChange(of: gallerySelection) { item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run { galleryImage = image; showGalleryPreview = true }
                    }
                }
            }
            .sheet(isPresented: $showGalleryPreview) {
                NavigationStack {
                    Group {
                        if let galleryImage = galleryImage {
                            Image(uiImage: galleryImage).resizable().scaledToFit()
                        } else { Text("No photo selected") }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showGalleryPreview = false } } }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    Form {
                        Section("Quick Controls") {
                            Text("Press and hold a control in the camera panel, then tap its minus badge to hide it.")
                                .font(.footnote)
                            ForEach(quickControlNames, id: \.self) { name in
                                Toggle(name, isOn: Binding(
                                    get: { !isControlHidden(name) },
                                    set: { enabled in
                                        var hidden = Set(hiddenQuickControls.split(separator: "|").map(String.init))
                                        if enabled { hidden.remove(name) } else { hidden.insert(name) }
                                        hiddenQuickControls = hidden.sorted().joined(separator: "|")
                                    }
                                ))
                            }
                            Button("Restore All Controls") { hiddenQuickControls = "" }
                        }
                        Section("Camera") {
                            Toggle("Grid", isOn: $showGrid)
                            Toggle("Level guide", isOn: $showLevel)
                            Picker("Photo timer", selection: $timer) { Text("Off").tag(0); Text("3 seconds").tag(3); Text("10 seconds").tag(10) }
                            Picker("Preview style", selection: $style) { ForEach(0..<styles.count, id: \.self) { i in Text(styles[i]).tag(i) } }
                            Text("Preview styles are visual guides only; captured images use the camera's native processing.").font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("Dual Camera") {
                            Button { showSettings = false; showDual = true } label: {
                                Label("Open Front + Back Preview", systemImage: "square.on.square")
                            }
                            Text("Records both front and back cameras into one video in PiP or split-screen layout. Dual-camera recordings are video-only.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("Photo Preferences") {
                            Toggle("Mirror front camera selfies", isOn: $mirrorSelfies)
                            Toggle("Prefer HEIF format", isOn: $preferHEIF)
                            Toggle("Location tags", isOn: $locationTags)
                            Text("These preferences are reserved for future capture pipeline integration.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("Video Preferences") {
                            Picker("Resolution", selection: $videoQuality) {
                                Text("720p").tag("720p")
                                Text("1080p").tag("1080p")
                                Text("4K").tag("4K")
                            }
                            Picker("Frame rate", selection: $videoFPS) {
                                Text("24 fps").tag(24)
                                Text("30 fps").tag(30)
                                Text("60 fps").tag(60)
                            }
                            Text("Video format preferences are not yet applied to recording; available modes vary by camera hardware.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("Interface") {
                            Toggle("Preserve last mode", isOn: $preserveMode)
                            Toggle("Histogram (planned)", isOn: $showHistogram)
                        }
                        Section("About") { Text("Camera-inspired interface. Recording capabilities depend on your device hardware.") }
                    }.navigationTitle("Camera Settings").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
                }.preferredColorScheme(.dark)
            }
            .alert("Camera", isPresented: Binding(get: { engine.errorMessage != nil }, set: { if !$0 { engine.errorMessage = nil } })) { Button("OK", role: .cancel) { engine.errorMessage = nil } } message: { Text(engine.errorMessage ?? "") }
        }
    }
    private var shutterButton: some View {
        Button {
            if [0, 1, 2, 3].contains(mode) {
                if mode == 2 && !engine.recording {
                    engine.errorMessage = "Cinematic-style video recording is enabled. Automatic depth-of-field blur is not yet supported. Tap record again to start."
                } else { engine.toggleRecording(kind: modes[mode]) }
            }
            else if mode == 6 { engine.captureForMode("PANO") }
            else if !shutterBusy {
                shutterBusy = true
                if timer == 0 { engine.captureForMode(modes[mode]); shutterBusy = false }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timer)) { engine.captureForMode(modes[mode]); shutterBusy = false } }
            }
        } label: {
            Circle()
                .fill([0, 1, 2, 3].contains(mode) ? Color.red : Color.white)
                .frame(width: 72, height: 72)
                .overlay { Circle().stroke(.white, lineWidth: 3).frame(width: 84, height: 84) }
                .overlay { if engine.recording { RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 23, height: 23) } }
        }
        .frame(width: 92, height: 92)
    }

    private var modePicker: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach([-1, 0, 1], id: \.self) { offset in
                    let index = mode + offset
                    Group {
                        if modes.indices.contains(index) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    mode = index
                                    engine.selectMode(modes[index])
                                }
                            } label: {
                                Text(modes[index])
                                    .font(.system(size: 13, weight: mode == index ? .semibold : .regular))
                                    .minimumScaleFactor(0.7)
                                    .lineLimit(1)
                                    .foregroundStyle(mode == index ? .yellow : .white.opacity(0.9))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 46)
                                    .background {
                                        if mode == index { Capsule().fill(.white.opacity(0.12)) }
                                    }
                            }
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    .frame(width: proxy.size.width / 3)
                }
            }
            .background(Color.white.opacity(0.065), in: Capsule())
            .overlay { Capsule().stroke(.white.opacity(0.22), lineWidth: 0.6) }
        }
        .frame(height: 46)
    }

    private var flashSymbol: String {
        switch engine.flashMode {
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.a.fill"
        default: return "bolt.slash.fill"
        }
    }
    private func cycleFlash() {
        switch engine.flashMode {
        case .off: engine.flashMode = .auto
        case .auto: engine.flashMode = .on
        default: engine.flashMode = .off
        }
    }
    private func quickTile(_ name: String, icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Group {
            if !isControlHidden(name.components(separatedBy: " ").first == "TIMER" ? "TIMER" : name) {
                Button(action: {
                    if !editingControls { action() }
                }) {
                    VStack(spacing: 7) {
                        ZStack(alignment: .topLeading) {
                            Image(systemName: icon).font(.title2).foregroundStyle(active ? .yellow : .white)
                                .frame(width: 55, height: 55).background(.black.opacity(0.65), in: Circle())
                        }
                        Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .onLongPressGesture(minimumDuration: 0.5) { editingControls = true }
                .overlay(alignment: .topLeading) {
                    if editingControls {
                        Button { hideControl(name.hasPrefix("TIMER") ? "TIMER" : name) } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title3).foregroundStyle(.red, .white)
                                .frame(width: 30, height: 30)
                        }.offset(x: -7, y: -8)
                    }
                }
            }
        }
    }
    private var quickControls: some View {
        VStack(spacing: 14) {
            HStack {
                quickTile("FLASH", icon: flashSymbol, active: engine.flashMode != .off) { cycleFlash() }
                quickTile("LIVE", icon: "livephoto", active: liveRequested) { liveRequested.toggle(); engine.errorMessage = "Live Photo capture is not implemented in this build. Normal photos are still saved." }
                quickTile("ASPECT", icon: "aspectratio", active: aspect != "4:3") {
                    aspect = aspect == "4:3" ? "16:9" : (aspect == "16:9" ? "1:1" : "4:3")
                }
            }
            HStack {
                quickTile("TIMER \(timer == 0 ? "OFF" : "\(timer)s")", icon: "timer", active: timer != 0) { timer = timer == 0 ? 3 : (timer == 3 ? 10 : 0) }
                quickTile("EXPOSURE", icon: "plusminus.circle", active: abs(engine.exposureBias) > 0.1) { showExposure.toggle() }
                quickTile("STYLES", icon: "square.stack.3d.up", active: style != 0) { style = (style + 1) % styles.count }
            }
            HStack {
                quickTile("FILTER", icon: "camera.filters", active: filter != "None") { filter = filter == "None" ? "Mono" : "None" }
                quickTile("NIGHT", icon: "moon.stars", active: nightGuide) { nightGuide.toggle(); engine.errorMessage = "Night mode indicator only: computational Night Mode is not available through this app." }
                quickTile("FORMAT", icon: "photo", active: preferHEIF) { preferHEIF.toggle(); engine.errorMessage = "Format preference saved. This build uses the native photo output format." }
            }
            quickTile("SHARED LIBRARY", icon: "person.2", active: sharedLibraryRequested) {
                engine.errorMessage = "Shared Library routing is managed by iOS Photos and is not implemented in this build."
            }
            if showExposure {
                HStack {
                    Text("EV").font(.caption)
                    Slider(value: Binding(get: { Double(engine.exposureBias) }, set: { engine.setExposure(Float($0)) }), in: -2...2, step: 0.25)
                    Text(String(format: "%+.1f", engine.exposureBias)).font(.caption.monospacedDigit()).frame(width: 42)
                }.padding(.horizontal, 15)
            }
        }.padding(.vertical, 16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
    @State private var showExposure = false
    private var gridOverlay: some View {
        GeometryReader { proxy in
            Path { path in
                for i in 1...2 {
                    let x = proxy.size.width * CGFloat(i) / 3
                    let y = proxy.size.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                }
            }.stroke(.white.opacity(0.28), lineWidth: 0.5)
        }.allowsHitTesting(false)
    }
}
