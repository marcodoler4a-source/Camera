import SwiftUI
import AVFoundation
import CoreMotion
import Photos
import PhotosUI
import UIKit
import CoreImage
import Vision

final class CameraEngine: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.session.queue")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let trackingOutput = AVCaptureVideoDataOutput()
    private let trackingQueue = DispatchQueue(label: "camera.subject.tracking", qos: .userInitiated)
    private var trackingFrame = 0
    private var trackingLastUpdate = Date.distantPast
    private var preferredVideoQuality = "4K"
    private var preferredVideoFPS = 30
    func setVideoPreferences(quality: String, fps: Int) {
        queue.async {
            self.preferredVideoQuality = quality
            self.preferredVideoFPS = fps
            if self.activeMode == "VIDEO" || self.activeMode == "CINEMATIC" { self.configureNormalVideo() }
        }
    }
    // Light painting composites the brightest pixels from consecutive video frames.
    // This is a multi-frame creative effect, not a long RAW sensor exposure.
    @Published var lightPaintingActive = false
    private var lightPaintingImage: CIImage?
    private var lightPaintingFrames = 0
    private var lightPaintingStart = Date()
    func toggleLightPainting() {
        trackingQueue.async {
            if self.lightPaintingActive {
                let result = self.lightPaintingImage
                self.lightPaintingImage = nil
                self.lightPaintingFrames = 0
                DispatchQueue.main.async { self.lightPaintingActive = false }
                guard let result = result,
                      let cg = self.peakingContext.createCGImage(result, from: result.extent),
                      let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.92) else { return }
                self.savePhotoData(jpeg)
            } else {
                self.lightPaintingImage = nil
                self.lightPaintingFrames = 0
                self.lightPaintingStart = Date()
                DispatchQueue.main.async { self.lightPaintingActive = true }
            }
        }
    }
    // Keep a short burst in memory and save the sharpest frame as an extra favorite.
    // The original ten burst photographs are still saved unchanged.
    private var bestShotRemaining = 0
    private var bestShotData: Data?
    private var bestShotScore: Double = -1
    func beginBestShotBurst(count: Int) {
        queue.async {
            self.bestShotRemaining = count
            self.bestShotData = nil
            self.bestShotScore = -1
        }
    }
    private func considerBestShot(_ data: Data) {
        guard bestShotRemaining > 0 else { return }
        bestShotRemaining -= 1
        if let input = CIImage(data: data),
           let edges = CIFilter(name: "CIEdges", parameters: [kCIInputImageKey: input, kCIInputIntensityKey: 1.0])?.outputImage,
           let average = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: edges, kCIInputExtentKey: CIVector(cgRect: edges.extent)])?.outputImage {
            var pixel = [UInt8](repeating: 0, count: 4)
            peakingContext.render(average, toBitmap: &pixel, rowBytes: 4,
                                  bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                  format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            let score = Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])
            if score > bestShotScore { bestShotScore = score; bestShotData = data }
        }
        if bestShotRemaining == 0 {
            if let best = bestShotData { savePhotoData(best) }
            bestShotData = nil
            DispatchQueue.main.async { self.errorMessage = "Burst finished. Sharpest frame saved as an extra photo." }
        }
    }
    @Published var proEnabled = false
    @Published var histogramBins: [CGFloat] = Array(repeating: 0, count: 32)
    @Published var rgbBins: [[CGFloat]] = Array(repeating: Array(repeating: 0, count: 32), count: 3)
    @Published var waveformBins: [CGFloat] = Array(repeating: 0, count: 48)
    @Published var waveformPoints: [CGPoint] = []
    @Published var rgbWavePoints: [[CGPoint]] = [[], [], []]
    @Published var scopesEnabled = false
    @Published var stabilizationEnabled = true
    @Published var audioLevel: Float = -60
    func setScopes(_ enabled: Bool) { DispatchQueue.main.async { self.scopesEnabled = enabled; if enabled { self.histogramEnabled = true } } }
    func setStabilization(_ enabled: Bool) {
        queue.async {
            self.stabilizationEnabled = enabled
            if let connection = self.movieOutput.connection(with: .video), connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = enabled ? .cinematic : .off
            }
        }
    }
    @Published var zebraMask: UIImage?
    @Published var zebrasEnabled = false
    private var zebraFrameCounter = 0
    func setZebras(_ enabled: Bool) { zebrasEnabled = enabled; if !enabled { DispatchQueue.main.async { self.zebraMask = nil } } }
    @Published var histogramEnabled = false
    @Published var focusPeakingEnabled = false
    @Published var focusPeakingImage: UIImage?
    private let peakingContext = CIContext(options: [.useSoftwareRenderer: false])
    private var peakingFrame = 0
    func setFocusPeaking(_ enabled: Bool) { focusPeakingEnabled = enabled; if !enabled { DispatchQueue.main.async { self.focusPeakingImage = nil } } }
    @Published var rawEnabled = false
    @Published var manualISO: Float = 100
    @Published var manualShutter: Double = 1.0 / 60.0
    @Published var manualFocus: Float = 0.5
    @Published var manualTemperature: Float = 5000
    private var histogramCounter = 0
    func setHistogram(_ enabled: Bool) { histogramEnabled = enabled }
    func setRAW(_ enabled: Bool) { rawEnabled = enabled }
    func setManualExposure(iso: Float, shutter: Double) {
        queue.async {
            guard let device = self.deviceInput?.device else { return }
            let safeISO = min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)
            let maxSeconds = max(1.0 / 10000.0, CMTimeGetSeconds(device.activeFormat.maxExposureDuration))
            let safeDuration = CMTimeMakeWithSeconds(max(1.0/10000.0, min(shutter, maxSeconds)), preferredTimescale: 1000000)
            do {
                try device.lockForConfiguration()
                device.setExposureModeCustom(duration: safeDuration, iso: safeISO, completionHandler: nil)
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.manualISO = safeISO; self.manualShutter = CMTimeGetSeconds(safeDuration) }
            } catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
        }
    }
    func setManualFocus(_ value: Float) {
        queue.async {
            guard let device = self.deviceInput?.device, device.isFocusModeSupported(.locked) else { return }
            do { try device.lockForConfiguration(); device.setFocusModeLocked(lensPosition: value, completionHandler: nil); device.unlockForConfiguration()
                DispatchQueue.main.async { self.manualFocus = value }
            } catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
        }
    }
    func setWhiteBalance(_ kelvin: Float) {
        queue.async {
            guard let device = self.deviceInput?.device, device.isWhiteBalanceModeSupported(.locked) else { return }
            do {
                try device.lockForConfiguration()
                let temperature = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0)
                let rawGains = device.deviceWhiteBalanceGains(for: temperature)
                let maximum = device.maxWhiteBalanceGain
                let gains = AVCaptureDevice.WhiteBalanceGains(redGain: min(max(rawGains.redGain, 1), maximum), greenGain: min(max(rawGains.greenGain, 1), maximum), blueGain: min(max(rawGains.blueGain, 1), maximum))
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.manualTemperature = kelvin }
            } catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
        }
    }
    func resetManualControls() {
        queue.async {
            guard let device = self.deviceInput?.device else { return }
            do { try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                device.unlockForConfiguration()
            } catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
        }
    }
    @Published var eyeAutofocusEnabled = false
    func setEyeAutofocus(_ enabled: Bool) { DispatchQueue.main.async { self.eyeAutofocusEnabled = enabled; if enabled { self.subjectTrackingEnabled = true } } }
    @Published var subjectTrackingEnabled = false
    @Published var orientationLockEnabled = true
    @Published var trackingSubjectFound = false
    func setSubjectTracking(_ enabled: Bool) {
        DispatchQueue.main.async { self.subjectTrackingEnabled = enabled; if !enabled { self.trackingSubjectFound = false } }
    }
    func setOrientationLock(_ enabled: Bool) { DispatchQueue.main.async { self.orientationLockEnabled = enabled } }
    // On-device Vision person tracking: continuously refocuses/re-exposes on a moving person.
    // A stationary phone cannot mechanically pan to follow someone.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if lightPaintingActive, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            lightPaintingFrames += 1
            if lightPaintingFrames % 3 == 0 && Date().timeIntervalSince(lightPaintingStart) < 120 {
                let source = CIImage(cvPixelBuffer: buffer)
                let factor = min(1.0, 960.0 / max(source.extent.width, source.extent.height))
                let frame = source.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                if let previous = lightPaintingImage {
                    lightPaintingImage = frame.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: previous])
                } else {
                    lightPaintingImage = frame
                }
            }
        }
        if histogramEnabled || scopesEnabled {
            histogramCounter += 1
            if histogramCounter % 15 == 0, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
                let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
                if CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
                   let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                    let pixels = base.assumingMemoryBound(to: UInt8.self)
                    var bins = Array(repeating: CGFloat(0), count: 32)
                    var channels = Array(repeating: Array(repeating: CGFloat(0), count: 32), count: 3)
                    var wave = Array(repeating: CGFloat(0), count: 48)
                    var waveCounts = Array(repeating: CGFloat(0), count: 48)
                    var scopePoints = [CGPoint]()
                    var channelPoints = [[CGPoint]](repeating: [], count: 3)
                    for y in stride(from: 0, to: height, by: max(1, height / 48)) {
                        for x in stride(from: 0, to: width, by: max(1, width / 64)) {
                            let offset = y * rowBytes + x * 4
                            let luma = (Int(pixels[offset]) + Int(pixels[offset+1]) + Int(pixels[offset+2])) / 3
                            bins[min(31, luma / 8)] += 1
                            if self.scopesEnabled {
                                channels[0][min(31, Int(pixels[offset+2]) / 8)] += 1
                                channels[1][min(31, Int(pixels[offset+1]) / 8)] += 1
                                channels[2][min(31, Int(pixels[offset]) / 8)] += 1
                                let column = min(47, x * 48 / max(1, width))
                                wave[column] += CGFloat(luma) / 255
                                waveCounts[column] += 1
                                // True spatial scope: horizontal image position versus signal level.
                                if scopePoints.count < 2400 {
                                    scopePoints.append(CGPoint(x: CGFloat(x) / CGFloat(max(1,width)), y: CGFloat(luma) / 255))
                                    channelPoints[0].append(CGPoint(x: CGFloat(x) / CGFloat(max(1,width)), y: CGFloat(pixels[offset+2]) / 255))
                                    channelPoints[1].append(CGPoint(x: CGFloat(x) / CGFloat(max(1,width)), y: CGFloat(pixels[offset+1]) / 255))
                                    channelPoints[2].append(CGPoint(x: CGFloat(x) / CGFloat(max(1,width)), y: CGFloat(pixels[offset]) / 255))
                                }
                            }
                        }
                    }
                    let peak = max(1, bins.max() ?? 1)
                    let normalizedRGB = channels.map { channel -> [CGFloat] in
                        let maximum = max(1, channel.max() ?? 1)
                        return channel.map { $0 / maximum }
                    }
                    let normalizedWave = zip(wave, waveCounts).map { $1 > 0 ? $0 / $1 : CGFloat(0) }
                    DispatchQueue.main.async {
                        self.histogramBins = bins.map { $0 / peak }
                        if self.scopesEnabled { self.rgbBins = normalizedRGB; self.waveformBins = normalizedWave; self.waveformPoints = scopePoints; self.rgbWavePoints = channelPoints }
                    }
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            }
        }
        // Real-time clipping overlay from the camera pixel buffer, not a static stripe overlay.
        if zebrasEnabled, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            zebraFrameCounter += 1
            if zebraFrameCounter % 12 == 0 {
                let input = CIImage(cvPixelBuffer: buffer)
                let small = input.transformed(by: CGAffineTransform(scaleX: 0.18, y: 0.18))
                let luminance = small.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                let mask = luminance.applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0.93, y: 0.93, z: 0.93, w: 0), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
                guard let stripes = CIFilter(name: "CICheckerboardGenerator") else { return }
                stripes.setValue(CIColor(red: 1, green: 0.75, blue: 0, alpha: 0.8), forKey: "inputColor0")
                stripes.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor1")
                stripes.setValue(5.0, forKey: "inputWidth")
                guard let stripeImage = stripes.outputImage else { return }
                let result = stripeImage.cropped(to: mask.extent).applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: mask.extent), kCIInputMaskImageKey: mask])
                if let cg = peakingContext.createCGImage(result, from: result.extent) {
                    DispatchQueue.main.async { self.zebraMask = UIImage(cgImage: cg) }
                }
            }
        }
        // True live edge-based focus peaking: highlight high-frequency details in red.
        // Work on a reduced-size image to avoid stalling the camera capture queue.
        if focusPeakingEnabled {
            peakingFrame += 1
            if peakingFrame % 8 == 0, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let source = CIImage(cvPixelBuffer: buffer)
                let scale = min(1.0, 240.0 / max(source.extent.width, source.extent.height))
                let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                if let edges = CIFilter(name: "CIEdges", parameters: [kCIInputImageKey: small, kCIInputIntensityKey: 7.0])?.outputImage,
                   let threshold = CIFilter(name: "CIColorMatrix", parameters: [kCIInputImageKey: edges,
                        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputAVector": CIVector(x: 2.5, y: 2.5, z: 2.5, w: 0),
                        "inputBiasVector": CIVector(x: 1, y: 0, z: 0, w: -1.7)])?.outputImage,
                   let cg = peakingContext.createCGImage(threshold, from: threshold.extent) {
                    DispatchQueue.main.async { self.focusPeakingImage = UIImage(cgImage: cg) }
                }
            }
        }
        guard subjectTrackingEnabled || eyeAutofocusEnabled else { return }
        trackingFrame += 1
        guard trackingFrame % 12 == 0, Date().timeIntervalSince(trackingLastUpdate) > 0.35,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        trackingLastUpdate = Date()
        let request = VNDetectHumanRectanglesRequest()
        do {
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:])
            if eyeAutofocusEnabled {
                let faces = VNDetectFaceLandmarksRequest()
                try handler.perform([faces])
                if let face = faces.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
                    let eye = face.landmarks?.leftEye?.normalizedPoints.first ?? face.landmarks?.rightEye?.normalizedPoints.first
                    let target = eye.map { CGPoint(x: face.boundingBox.minX + CGFloat($0.x) * face.boundingBox.width, y: face.boundingBox.minY + CGFloat($0.y) * face.boundingBox.height) }
                        ?? CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY + face.boundingBox.height * 0.17)
                    self.updateTrackingFocus(CGPoint(x: target.x, y: 1 - target.y))
                    DispatchQueue.main.async { self.trackingSubjectFound = true }
                    return
                }
            }
            try handler.perform([request])
            guard let person = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else {
                DispatchQueue.main.async { self.trackingSubjectFound = false }
                return
            }
            DispatchQueue.main.async { self.trackingSubjectFound = true }
            let box = person.boundingBox
            // Vision normalized coordinates: origin bottom-left. Device focus coordinates: top-left.
            let focus = CGPoint(x: box.midX, y: 1 - box.midY)
            updateTrackingFocus(focus)
        } catch { DispatchQueue.main.async { self.trackingSubjectFound = false } }
    }
    private func updateTrackingFocus(_ focus: CGPoint) {
        queue.async {
            guard (self.subjectTrackingEnabled || self.eyeAutofocusEnabled), let device = self.deviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = focus
                    if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = focus
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                }
                device.unlockForConfiguration()
            } catch { /* Tracking is best effort. */ }
        }
    }
    private func currentVideoOrientation() -> AVCaptureVideoOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        case .portraitUpsideDown: return .portraitUpsideDown
        case .portrait: return .portrait
        default:
            // The physical sensor often reports .unknown/.faceUp when the shutter is pressed.
            // Read the visible interface orientation instead of silently saving landscape.
            let interface = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }.first
            switch interface {
            case .landscapeLeft: return .landscapeLeft
            case .landscapeRight: return .landscapeRight
            case .portraitUpsideDown: return .portraitUpsideDown
            default: return .portrait
            }
        }
    }

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
    private var recordingRequested = false
    private var photoKind = "PHOTO"
    private var livePhotoRequested = false
    private var pendingLivePhotos: [Int64: (Data, URL?)] = [:]
    private var livePhotoCaptureIDs = Set<Int64>()
    private var liveMovieURLs: [Int64: URL] = [:]
    func setLivePhotoEnabled(_ enabled: Bool) {
        queue.async {
            self.livePhotoRequested = enabled
            self.configureLivePhotoOutputs()
        }
    }

    // Live Photo requires a photo-compatible capture session. The movie-file
    // recorder can prevent AVFoundation from offering Live Photo capture.
    // Temporarily detach it in PHOTO mode, then restore it for video modes.
    private func configureLivePhotoOutputs() {
        guard configured, !movieOutput.isRecording else { return }
        let useLive = livePhotoRequested && activeMode == "PHOTO"
        session.beginConfiguration()
        if useLive {
            if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
            if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
        } else if !session.outputs.contains(movieOutput) && session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        session.commitConfiguration()
        // Check support only after the output graph is committed.
        if photoOutput.isLivePhotoCaptureSupported {
            photoOutput.isLivePhotoCaptureEnabled = useLive
        } else {
            photoOutput.isLivePhotoCaptureEnabled = false
            if useLive {
                DispatchQueue.main.async {
                    self.errorMessage = "Live Photos are not supported with the current camera configuration. Try the rear camera and turn off Dual Camera."
                }
            }
        }
    }
    var photoAspect = "4:3"
    var photoFilter = "None"
    var photoStyle = "Natural"
    private var panoramaFrames: [UIImage] = []
    // Single-shot Night Mode: one exposure, with low-light processing in processedPhotoData.
    @Published var nightEnabled = false
    @Published var nightSecondsRemaining = 0
    @Published var nightCapturing = false
    private var nightProcessing = false
    func setNightProcessing(_ enabled: Bool) {
        queue.async {
            self.nightProcessing = enabled
            DispatchQueue.main.async { self.nightEnabled = enabled }
        }
    }
    @Published var macroEnabled = false
    @Published var autoMacroEnabled = true
    private var macroMonitor: DispatchSourceTimer?
    private var nearFocusSamples = 0
    private var farFocusSamples = 0
    // Do not let automatic macro switching override a manually chosen zoom.
    private var manualZoomSelected = false
    // The public camera API does not expose subject distance. Lens position is
    // only a heuristic; a manual Macro toggle remains available.
    private func beginMacroMonitoring() {
        guard macroMonitor == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 0.7)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.autoMacroEnabled, !self.manualZoomSelected,
                  self.session.isRunning, !self.movieOutput.isRecording,
                  self.captureMode == "PHOTO" || self.captureMode == "PORTRAIT",
                  let device = self.deviceInput?.device, device.position == .back else { return }
            // Lens position is 0 (far) to 1 (near), not a calibrated distance.
            // Do not switch if a suitable ultra-wide lens does not exist.
            guard AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil else { return }
            let position = device.lensPosition
            if !self.macroEnabled {
                self.nearFocusSamples = position > 0.82 ? self.nearFocusSamples + 1 : 0
                if self.nearFocusSamples >= 3 {
                    self.nearFocusSamples = 0
                    self.setMacro(true)
                }
            } else {
                // Lens position on a different camera is not comparable.
                // Leave macro engaged until the user toggles it or changes zoom.
                self.farFocusSamples = 0
            }
        }
        macroMonitor = timer
        timer.resume()
    }
    func setMacro(_ enabled: Bool) {
        queue.async {
            self.manualZoomSelected = !enabled
            guard let old = self.deviceInput else { return }
            let type: AVCaptureDevice.DeviceType = enabled ? .builtInUltraWideCamera : .builtInWideAngleCamera
            guard let camera = AVCaptureDevice.default(type, for: .video, position: .back), let next = try? AVCaptureDeviceInput(device: camera) else {
                DispatchQueue.main.async { self.errorMessage = "Macro camera is unavailable on this device." }
                return
            }
            self.session.beginConfiguration()
            self.session.removeInput(old)
            if self.session.canAddInput(next) { self.session.addInput(next); self.deviceInput = next }
            else { self.session.addInput(old) }
            self.session.commitConfiguration()
            if let device = self.deviceInput?.device {
                do { try device.lockForConfiguration(); if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = enabled ? .near : .none }; device.focusMode = .continuousAutoFocus; device.unlockForConfiguration() } catch {}
            }
            DispatchQueue.main.async { self.macroEnabled = enabled; self.zoom = enabled ? 0.5 : 1 }
        }
    }
    @Published var panoramaCount = 0
    @Published var captureMode = "PHOTO"
    private var activeMode = "PHOTO"
    func selectMode(_ name: String) {
        queue.async {
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            self.activeMode = name
            DispatchQueue.main.async { self.captureMode = name }
            if name == "SLO-MO" { self.configureSlowMotion() }
            else if name == "PHOTO" || name == "PORTRAIT" || name == "PANO" { self.configurePhotoQuality() }
            else { self.configureNormalVideo() }
            self.configureLivePhotoOutputs()
            if name != "PHOTO" { self.restoreVideoOutputIfNeeded() }
        }
    }
    private func configurePhotoQuality() {
        // Photo preset prioritizes still-photo capture resolution instead of video throughput.
        guard !movieOutput.isRecording, session.canSetSessionPreset(.photo), session.sessionPreset != .photo else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.commitConfiguration()
    }
    private func configureNormalVideo() {
        // Prefer 4K video where supported; fall back to the device's high-quality preset.
        guard !movieOutput.isRecording else { return }
        let requested: AVCaptureSession.Preset = preferredVideoQuality == "720p" ? .hd1280x720 : (preferredVideoQuality == "1080p" ? .hd1920x1080 : .hd4K3840x2160)
        let preferred: AVCaptureSession.Preset = session.canSetSessionPreset(requested) ? requested : .high
        if session.sessionPreset != preferred {
            session.beginConfiguration()
            session.sessionPreset = preferred
            session.commitConfiguration()
        }
        guard let device = deviceInput?.device else { return }
        do {
            try device.lockForConfiguration()
            let fps = Double(preferredVideoFPS)
            let supportsFPS = device.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
            if supportsFPS {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(preferredVideoFPS))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(preferredVideoFPS))
            } else {
                device.activeVideoMinFrameDuration = .invalid
                device.activeVideoMaxFrameDuration = .invalid
                DispatchQueue.main.async { self.errorMessage = "Selected frame rate is unavailable at this resolution; using camera default." }
            }
            device.unlockForConfiguration()
        } catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
    }
    private func configureSlowMotion() {
        guard let device = deviceInput?.device else { return }
        // High frame rates require input-priority rather than a fixed session preset.
        let formats = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width >= 1280 && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 120 && $0.minFrameRate <= 120 }
        }
        guard let format = formats.max(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }) else {
            // Keep the camera usable and retime the captured video if 120 fps is unavailable.
            return
        }
        if session.sessionPreset != .inputPriority {
            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            session.commitConfiguration()
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
        guard frames.count >= 2 else { DispatchQueue.main.async { self.errorMessage = "Sweep more slowly and capture at least two panorama frames." }; return }
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
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.errorMessage = "Allow Photos access to save panoramas." }
                return
            }
            PHPhotoLibrary.shared().performChanges({ PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil) }) { success, error in
                if !success { DispatchQueue.main.async { self.errorMessage = error?.localizedDescription ?? "Could not save photo." } }
            }
        }
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { self.authorized = granted }
            guard granted else { return }
            self.queue.async {
                if !self.configured { self.configure() }
                guard self.configured else {
                    DispatchQueue.main.async { self.errorMessage = "Camera setup failed. Check camera permission and restart the app." }
                    return
                }
                self.restoreAutomaticCamera()
                self.restoreVideoOutputIfNeeded()
                if !self.session.isRunning { self.session.startRunning() }
                if !self.session.isRunning {
                    DispatchQueue.main.async { self.errorMessage = "Camera could not start. Close other camera apps and try again." }
                } else {
                    self.beginMacroMonitoring()
                }
            }
        }
    }
    func stop() { queue.async { self.macroMonitor?.cancel(); self.macroMonitor = nil; if self.session.isRunning { self.session.stopRunning() } } }
    func stopBeforeDualCamera(_ completion: @escaping () -> Void) {
        queue.async {
            self.macroMonitor?.cancel()
            self.macroMonitor = nil
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async(execute: completion)
        }
    }
    // Build a minimal reliable capture graph first. Optional analysis and audio
    // connections must never prevent the still/video camera from starting.
    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.errorMessage = "Rear camera input could not be created." }
            return
        }
        session.addInput(input)
        deviceInput = input
        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.errorMessage = "Photo output could not be attached to the camera." }
            return
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        trackingOutput.alwaysDiscardsLateVideoFrames = true
        trackingOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        trackingOutput.setSampleBufferDelegate(self, queue: trackingQueue)
        if session.canAddOutput(trackingOutput) { session.addOutput(trackingOutput) }
        session.commitConfiguration()
        configured = true
        // Camera preview and capture must work even without microphone permission.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            guard granted else { return }
            self.queue.async {
                guard let mic = AVCaptureDevice.default(for: .audio),
                      let audioInput = try? AVCaptureDeviceInput(device: mic),
                      self.session.canAddInput(audioInput) else { return }
                self.session.beginConfiguration()
                self.session.addInput(audioInput)
                self.session.commitConfiguration()
            }
        }
    }
    private func restoreAutomaticCamera() {
        guard let device = deviceInput?.device else { return }
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.setExposureTargetBias(0, completionHandler: nil)
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.exposureBias = 0 }
        } catch { print("Camera automatic exposure reset: \(error)") }
    }
    private func restoreVideoOutputIfNeeded() {
        guard !movieOutput.isRecording, !session.outputs.contains(movieOutput) else { return }
        session.beginConfiguration()
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        session.commitConfiguration()
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
            self.configureLivePhotoOutputs()
            DispatchQueue.main.async { self.front = position == .front; self.zoom = 1 }
        }
    }
    // Keep the physical camera zoom within its actual active-format limits.
    // A dial can display 5x even when the selected lens cannot reach it.
    func setZoom(_ value: CGFloat) {
        let requested = max(CGFloat(0.5), min(value, CGFloat(15)))
        queue.async {
            self.manualZoomSelected = true
            guard let old = self.deviceInput else { return }
            let ultra = !self.front && requested < 0.99
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
                } else if self.session.canAddInput(old) {
                    self.session.addInput(old)
                }
                self.session.commitConfiguration()
            }
            guard let device = self.deviceInput?.device else { return }
            let availableMaximum = min(CGFloat(15), CGFloat(device.activeFormat.videoMaxZoomFactor), CGFloat(device.maxAvailableVideoZoomFactor))
            let availableMinimum = max(CGFloat(1), CGFloat(device.minAvailableVideoZoomFactor))
            let factor = ultra ? CGFloat(1) : min(max(requested, availableMinimum), max(availableMinimum, availableMaximum))
            do {
                try device.lockForConfiguration()
                // Avoid reapplying the same zoom on every tiny drag update.
                if abs(device.videoZoomFactor - factor) > 0.005 {
                    device.videoZoomFactor = factor
                }
                device.unlockForConfiguration()
                let displayed = ultra ? CGFloat(0.5) : factor
                // Keep macro state consistent with the lens chosen by the zoom dial.
                DispatchQueue.main.async { self.macroEnabled = ultra }
                DispatchQueue.main.async { self.zoom = displayed }
            } catch {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            }
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
        // Read device orientation on the calling thread before dispatching capture.
        // Unlike video orientation lock, still photos follow the phone's position.
        let shotOrientation = currentVideoOrientation()
        queue.async {
            guard self.session.isRunning, self.session.outputs.contains(self.photoOutput), self.photoOutput.connection(with: .video) != nil else {
                DispatchQueue.main.async { self.errorMessage = "Camera session is not ready. Please close and reopen CameraClone." }
                return
            }
            if let connection = self.photoOutput.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = shotOrientation
            }
            let settings: AVCapturePhotoSettings
            if self.rawEnabled, let rawType = self.photoOutput.availableRawPhotoPixelFormatTypes.first, self.photoKind == "PHOTO", !self.livePhotoRequested {
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawType)
            } else {
                settings = AVCapturePhotoSettings()
                if self.rawEnabled { DispatchQueue.main.async { self.errorMessage = "RAW requires Photo mode with Live Photo disabled and a supported camera." } }
            }
            if self.photoOutput.supportedFlashModes.contains(self.flashMode) { settings.flashMode = self.flashMode }
            settings.photoQualityPrioritization = .quality
            if self.livePhotoRequested && self.photoKind == "PHOTO" {
                if self.photoOutput.isLivePhotoCaptureSupported && self.photoOutput.isLivePhotoCaptureEnabled {
                    let path = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                    settings.livePhotoMovieFileURL = path
                } else {
                    DispatchQueue.main.async { self.errorMessage = "Live Photo is unavailable with this camera configuration." }
                }
            }
            if self.photoKind == "PORTRAIT" && self.photoOutput.isDepthDataDeliverySupported {
                settings.isDepthDataDeliveryEnabled = true
            }
            if settings.livePhotoMovieFileURL != nil {
                self.livePhotoCaptureIDs.insert(settings.uniqueID)
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            if livePhotoCaptureIDs.contains(photo.resolvedSettings.uniqueID) {
                livePhotoRequested = false
                queue.async { self.configureLivePhotoOutputs() }
                DispatchQueue.main.async { self.errorMessage = "Live Photo failed (\(error.localizedDescription)). Live Photo has been disabled; regular Photo mode is still available." }
            } else {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            }
            return
        }
        guard let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else { return }
                PHPhotoLibrary.shared().performChanges({
                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = "com.adobe.raw-image"
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
                }) { success, error in
                    if !success { DispatchQueue.main.async { self.errorMessage = error?.localizedDescription ?? "RAW photo save failed." } }
                }
            }
            return
        }
        if photoKind == "PANO", let image = UIImage(data: data) {
            // Collect overlapping sweep frames; save only the final panorama.
            panoramaFrames.append(image)
            DispatchQueue.main.async { self.panoramaCount = self.panoramaFrames.count }
            return
        }
        if livePhotoCaptureIDs.contains(photo.resolvedSettings.uniqueID) {
            pendingLivePhotos[photo.resolvedSettings.uniqueID] = (data, liveMovieURLs[photo.resolvedSettings.uniqueID])
            return
        }
        let processed = processedPhotoData(data)
        considerBestShot(processed)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { DispatchQueue.main.async { self.errorMessage = "Allow Photos access in Settings to save images." }; return }
            PHPhotoLibrary.shared().performChanges({ PHAssetCreationRequest.forAsset().addResource(with: .photo, data: processed, options: nil) }) { success, error in
                if !success { DispatchQueue.main.async { self.errorMessage = error?.localizedDescription ?? "Could not save photo." } }
            }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime, photoDisplayTime: CMTime,
                     resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error {
            livePhotoRequested = false
            queue.async { self.configureLivePhotoOutputs() }
            DispatchQueue.main.async { self.errorMessage = "Live Photo motion recording failed. Live Photo disabled; use regular Photo mode." }
        } else {
            liveMovieURLs[resolvedSettings.uniqueID] = outputFileURL
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        let id = resolvedSettings.uniqueID
        if let error = error, !livePhotoCaptureIDs.contains(id) {
            DispatchQueue.main.async { self.errorMessage = "Photo capture: \(error.localizedDescription)" }
        }
        livePhotoCaptureIDs.remove(id)
        guard let item = pendingLivePhotos.removeValue(forKey: id) else {
            if let url = liveMovieURLs.removeValue(forKey: id) { try? FileManager.default.removeItem(at: url) }
            return
        }
        let movieURL = liveMovieURLs.removeValue(forKey: id) ?? item.1
        guard let url = movieURL else {
            savePhotoData(item.0)
            DispatchQueue.main.async { self.errorMessage = "Live Photo motion data unavailable; saved a still photo." }
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.errorMessage = "Allow Photos access to save Live Photos." }
                try? FileManager.default.removeItem(at: url)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: item.0, options: nil)
                request.addResource(with: .pairedVideo, fileURL: url, options: nil)
            }) { success, error in
                if !success { DispatchQueue.main.async { self.errorMessage = error?.localizedDescription ?? "Unable to save Live Photo." } }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // The same Core Image looks are used for photos and exported videos.
    private func applySelectedFilter(_ image: CIImage, named name: String) -> CIImage {
        switch name {
        case "Vivid": return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputContrastKey: 1.12])
        case "Vivid Warm": return applySelectedFilter(image, named: "Vivid").applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 5200, y: 0)])
        case "Vivid Cool": return applySelectedFilter(image, named: "Vivid").applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 8000, y: 0)])
        case "Dramatic": return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.78, kCIInputContrastKey: 1.38])
        case "Dramatic Warm": return applySelectedFilter(image, named: "Dramatic").applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 5200, y: 0)])
        case "Dramatic Cool": return applySelectedFilter(image, named: "Dramatic").applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 8000, y: 0)])
        case "Mono": return image.applyingFilter("CIPhotoEffectMono")
        case "Black & White": return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.22])
        case "Silvertone": return image.applyingFilter("CIPhotoEffectTonal")
        case "Noir": return image.applyingFilter("CIPhotoEffectNoir")
        default: return image
        }
    }
    // Sample device orientation while recording, then correct individual exported frames.
    // AVFoundation's connection orientation alone only fixes the movie's metadata.
    private let orientationSamplesLock = NSLock()
    private var orientationSamples: [(seconds: Double, angle: CGFloat)] = []
    private var recordingStartTime: Date?
    private var recordingReferenceAngle: CGFloat = 0
    private var recordingFrameCorrectionEnabled = false
    private var orientationObserver: NSObjectProtocol?
    private let rotationMotion = CMMotionManager()
    private var motionReferenceAngle: Double?
    private var rotationSampleTimer: DispatchSourceTimer?

    private func angleForDeviceOrientation(_ orientation: UIDeviceOrientation) -> CGFloat? {
        switch orientation {
        case .portrait: return 0
        case .portraitUpsideDown: return .pi
        case .landscapeLeft: return -.pi / 2
        case .landscapeRight: return .pi / 2
        default: return nil // Face-up, face-down, and unknown aren't useful angles.
        }
    }
    private func startOrientationSampling() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationSamplesLock.lock()
        recordingStartTime = Date()
        // Use the starting position as the reference; a portrait-locked movie is already upright at t=0.
        orientationSamples = [(0, 0)]
        recordingReferenceAngle = angleForDeviceOrientation(UIDevice.current.orientation) ?? 0
        orientationSamplesLock.unlock()
        // Track gravity continuously, including intermediate rotations that do not
        // trigger UIDevice.orientationDidChangeNotification.
        motionReferenceAngle = nil
        if rotationMotion.isDeviceMotionAvailable {
            rotationMotion.deviceMotionUpdateInterval = 1.0 / 30.0
            rotationMotion.startDeviceMotionUpdates()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
            timer.setEventHandler { [weak self] in
                guard let self = self, let motion = self.rotationMotion.deviceMotion else { return }
                let gravity = motion.gravity
                // Ignore nearly flat devices: gravity cannot resolve screen rotation.
                guard hypot(gravity.x, gravity.y) > 0.35 else { return }
                let angle = atan2(gravity.x, -gravity.y)
                if self.motionReferenceAngle == nil { self.motionReferenceAngle = angle }
                guard let baseline = self.motionReferenceAngle else { return }
                let relative = atan2(sin(angle - baseline), cos(angle - baseline))
                self.orientationSamplesLock.lock()
                if let start = self.recordingStartTime {
                    let seconds = max(0, Date().timeIntervalSince(start))
                    self.orientationSamples.append((seconds, CGFloat(relative)))
                }
                self.orientationSamplesLock.unlock()
            }
            rotationSampleTimer = timer
            timer.resume()
        }
        orientationObserver = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, let angle = self.angleForDeviceOrientation(UIDevice.current.orientation) else { return }
            guard !self.rotationMotion.isDeviceMotionActive else { return }
            self.orientationSamplesLock.lock()
            if let start = self.recordingStartTime {
                let seconds = max(0, Date().timeIntervalSince(start))
                // Compensate only the rotation relative to the initial phone orientation.
                // Applying an absolute angle would turn recordings that began in landscape sideways.
                let relativeAngle = atan2(sin(angle - self.recordingReferenceAngle), cos(angle - self.recordingReferenceAngle))
                if self.orientationSamples.last?.angle != relativeAngle { self.orientationSamples.append((seconds, relativeAngle)) }
            }
            self.orientationSamplesLock.unlock()
        }
    }
    private func finishOrientationSampling() -> [(seconds: Double, angle: CGFloat)] {
        rotationSampleTimer?.cancel()
        rotationSampleTimer = nil
        rotationMotion.stopDeviceMotionUpdates()
        if let observer = orientationObserver { NotificationCenter.default.removeObserver(observer); orientationObserver = nil }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        orientationSamplesLock.lock()
        let samples = orientationSamples
        recordingStartTime = nil
        orientationSamplesLock.unlock()
        return samples
    }
    private func correctFrameOrientation(_ image: CIImage, angle: CGFloat) -> CIImage {
        guard abs(angle) > 0.01 else { return image }
        let rect = image.extent
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let rotation = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle)
            .translatedBy(x: -center.x, y: -center.y)
        let rotated = image.transformed(by: rotation)
        // Fill the original canvas so landscape turns do not introduce black borders.
        let fill = max(rect.width / rotated.extent.width, rect.height / rotated.extent.height)
        let scaled = rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.midX, y: -rotated.extent.midY)
            .scaledBy(x: fill, y: fill)
            .translatedBy(x: rect.midX, y: rect.midY))
        return scaled.cropped(to: rect)
    }
    private var recordingFilter = "None"
    private func saveFilteredVideo(_ url: URL, filter name: String, orientationSamples: [(seconds: Double, angle: CGFloat)] = [], correctRotation: Bool = false) {
        guard name != "None" || correctRotation else { saveVideo(url); return }
        let asset = AVURLAsset(url: url)
        let composition = AVVideoComposition(asset: asset) { [weak self] request in
            guard let self = self else { request.finish(with: request.sourceImage, context: nil); return }
            let source = request.sourceImage.clampedToExtent()
            let elapsed = CMTimeGetSeconds(request.compositionTime)
            let angle = correctRotation ? (orientationSamples.last(where: { $0.seconds <= elapsed })?.angle ?? 0) : 0
            let corrected = self.correctFrameOrientation(source, angle: angle)
            let result = self.applySelectedFilter(corrected, named: name).cropped(to: request.sourceImage.extent)
            request.finish(with: result, context: nil)
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            DispatchQueue.main.async { self.errorMessage = "Unable to create a video correction export. Original recording retained." }
            return
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        exporter.videoComposition = composition
        exporter.outputURL = output
        guard exporter.supportedFileTypes.contains(.mov) else {
            DispatchQueue.main.async { self.errorMessage = "Video correction cannot export MOV on this device. Original recording retained." }
            return
        }
        exporter.outputFileType = .mov
        exporter.exportAsynchronously { [weak self] in
            guard let self = self else { return }
            if exporter.status == .completed,
               FileManager.default.fileExists(atPath: output.path),
               !AVURLAsset(url: output).tracks(withMediaType: .video).isEmpty {
                self.saveVideo(output)
                // Retain original until processed copy has been accepted by Photos.
            } else {
                DispatchQueue.main.async { self.errorMessage = "Video correction failed: \(exporter.error?.localizedDescription ?? "unknown export error"). Original recording retained for troubleshooting." }
            }
        }
    }

    private func processedPhotoData(_ data: Data) -> Data {
        guard let original = UIImage(data: data), let cg = original.cgImage else { return data }
        // Bake the captured EXIF orientation into pixels before cropping or filtering.
        let exif: Int32
        switch original.imageOrientation {
        case .up: exif = 1
        case .down: exif = 3
        case .left: exif = 8
        case .right: exif = 6
        case .upMirrored: exif = 2
        case .downMirrored: exif = 4
        case .leftMirrored: exif = 5
        case .rightMirrored: exif = 7
        @unknown default: exif = 1
        }
        var image = CIImage(cgImage: cg).oriented(forExifOrientation: exif)
        let targetRatio: CGFloat = photoAspect == "1:1" ? 1 : (photoAspect == "16:9" ? 16.0 / 9.0 : 4.0 / 3.0)
        let bounds = image.extent
        let effectiveRatio = bounds.height > bounds.width ? 1.0 / targetRatio : targetRatio
        let width = min(bounds.width, bounds.height * effectiveRatio)
        let height = min(bounds.height, bounds.width / effectiveRatio)
        image = image.cropped(to: CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height))
        if nightProcessing && photoKind != "PANO" {
            // Software low-light enhancement: reduce chroma/luma noise and gently brighten.
            // This does not reproduce Apple's multi-frame computational Night Mode.
            image = image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.035, "inputSharpness": 0.45])
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.09, kCIInputContrastKey: 1.04])
        }
        image = applySelectedFilter(image, named: photoFilter)
        let style = photoStyle
        if photoFilter == "None" && style == "Mono" {
            image = image.applyingFilter("CIPhotoEffectMono")
        } else if photoFilter == "None" && style == "Vivid" {
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.28, kCIInputContrastKey: 1.12])
        } else if photoFilter == "None" && (style == "Warm" || style == "Cool") {
            image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: style == "Warm" ? 5100 : 7900, y: 0)])
        }
        let context = CIContext()
        guard let output = context.createCGImage(image, from: image.extent) else { return data }
        return UIImage(cgImage: output).jpegData(compressionQuality: 0.94) ?? data
    }
    func toggleRecording(kind: String = "VIDEO") {
        queue.async {
            if self.movieOutput.isRecording {
                self.recordingRequested = false
                self.movieOutput.stopRecording()
                return
            }
            // Ignore a second tap while AVCaptureMovieFileOutput is starting.
            if self.recordingRequested { return }
            self.recordingKind = kind
            self.recordingFilter = self.photoFilter
            self.recordingFrameCorrectionEnabled = false
            if !self.session.outputs.contains(self.movieOutput) {
                self.livePhotoRequested = false
                self.configureLivePhotoOutputs()
            }
            self.restoreVideoOutputIfNeeded()
            guard self.session.isRunning, self.movieOutput.connection(with: .video) != nil else {
                DispatchQueue.main.async { self.errorMessage = "Video output unavailable. Switch to PHOTO, then VIDEO, and try again." }
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            self.recordingURL = url
            // A fixed portrait recording orientation prevents upside-down movies when the phone is turned.
            // Never derive locked orientation from UIDevice, which may report portraitUpsideDown.
            if let connection = self.movieOutput.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = self.currentVideoOrientation()
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = self.stabilizationEnabled ? .cinematic : .off
                }
                if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = self.front }
            }
            self.recordingRequested = true
            // Capture the starting device orientation on main before recording begins.
            DispatchQueue.main.async {
                if self.recordingFrameCorrectionEnabled { self.startOrientationSampling() }
                self.queue.async {
                    self.movieOutput.startRecording(to: url, recordingDelegate: self)
                }
            }
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) { DispatchQueue.main.async { self.recording = true } }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async { self.recordingRequested = false }
        let samples = finishOrientationSampling()
        let shouldCorrect = recordingFrameCorrectionEnabled
        DispatchQueue.main.async { self.recording = false }
        // AVFoundation may report a recoverable recording error while still producing a playable movie.
        // Validate the finished movie rather than assuming a non-empty file is usable.
        let asset = AVURLAsset(url: fileURL)
        let hasVideo = !asset.tracks(withMediaType: .video).isEmpty
        guard FileManager.default.fileExists(atPath: fileURL.path), hasVideo,
              asset.duration.isValid, CMTimeCompare(asset.duration, .zero) > 0 else {
            DispatchQueue.main.async { self.errorMessage = error?.localizedDescription ?? "Recording did not produce a playable video. Please try again." }
            return
        }
        if let error = error {
            print("CameraClone: recoverable recording warning: \(error.localizedDescription)")
        }
        if recordingKind == "SLO-MO" || recordingKind == "TIME-LAPSE" {
            let speed: Double = recordingKind == "SLO-MO" ? 0.25 : 8.0
            retimeVideo(fileURL, speed: speed)
            return
        }
        saveFilteredVideo(fileURL, filter: recordingFilter, orientationSamples: samples, correctRotation: shouldCorrect)
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
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.errorMessage = "Allow Photos access in Settings to save videos." }
                return
            }
            // Keep the temporary movie alive until the Photos transaction finishes.
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }) { success, error in
                if success {
                    try? FileManager.default.removeItem(at: fileURL)
                } else {
                    // Do not delete the only recording on failure; retain it for diagnostics/retry.
                    DispatchQueue.main.async { self.errorMessage = error?.localizedDescription ?? "Video could not be saved to Photos. Check Photos permission and available storage." }
                }
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView { let v = PreviewView(); v.previewLayer.session = session; v.previewLayer.videoGravity = .resizeAspectFill
        if let connection = v.previewLayer.connection, connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        return v }
    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        if let connection = uiView.previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }
}
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraView: View {
    @StateObject private var engine = CameraEngine()
    @State private var mode = 4
    @State private var showZoomDial = false
    @State private var portraitLighting = 0
    @State private var showPortraitDial = false
    @State private var portraitDragStart: CGFloat? = nil
    @State private var lastPhotoThumbnail: UIImage? = nil
    private let portraitLights = ["NATURAL LIGHT", "STUDIO LIGHT", "CONTOUR LIGHT", "STAGE LIGHT", "STAGE MONO", "HIGH-KEY MONO"]
    private func loadLastThumbnail() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { result in if result == .authorized || result == .limited { DispatchQueue.main.async { loadLastThumbnail() } } }
            return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject else { return }
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 160, height: 160), contentMode: .aspectFill, options: nil) { image, _ in
            if let image = image { DispatchQueue.main.async { lastPhotoThumbnail = image } }
        }
    }
    @State private var zoomDragStart: CGFloat? = nil
    @State private var showProPanel = false
    @State private var proISO: Double = 100
    @State private var proShutter: Double = 1.0 / 60.0
    @State private var proFocus: Double = 0.5
    @State private var proKelvin: Double = 5000
    @State private var showGoldenGuide = false
    @State private var showScopes = false
    @State private var actionStabilization = true
    @State private var showDocumentScanner = false
    @State private var scanPDF: URL?
    @State private var scanError: String?
    @State private var showPhotoEditor = false
    @State private var objectEraseBusy = false
    @State private var objectEraseMessage: String?
    @State private var editBrightness: Double = 0
    @State private var editHighlights: Double = 0
    @State private var editShadows: Double = 0
    @State private var editSharpness: Double = 0
    @State private var editVignette: Double = 0
    @State private var editWarmth: Double = 0
    @State private var editCrop: Double = 1
    @State private var showFocusPeaking = false
    @State private var showZebras = false
    @State private var eyeAFEnabled = false
    @State private var burstActive = false
    @State private var burstTimer: Timer?
    @State private var burstShots = 0
    private func toggleBurst() {
        if burstActive { burstTimer?.invalidate(); burstTimer = nil; burstActive = false; return }
        guard modes[mode] == "PHOTO" else { engine.errorMessage = "Switch to PHOTO mode for burst capture."; return }
        burstActive = true; burstShots = 0
        engine.beginBestShotBurst(count: 10)
        burstTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { timer in
            guard burstShots < 10 else { timer.invalidate(); burstTimer = nil; burstActive = false; return }
            engine.captureForMode("PHOTO")
            burstShots += 1
        }
    }
    @State private var bracketActive = false
    private func captureBracket() {
        guard modes[mode] == "PHOTO", !bracketActive else { return }
        bracketActive = true
        let original = engine.exposureBias
        // Save three distinct exposures. Merging into a single HDR image is not yet implemented.
        for (index, ev) in [-1.0, 0.0, 1.0].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 1.25) {
                engine.setExposure(Float(ev))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { engine.captureForMode("PHOTO") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.4) {
            engine.setExposure(original)
            bracketActive = false
        }
    }
    @State private var intervalSeconds = 3
    @State private var intervalActive = false
    @State private var intervalTimer: Timer?
    @State private var focusTargetNear = true
    private func toggleIntervalometer() {
        if intervalActive {
            intervalTimer?.invalidate(); intervalTimer = nil; intervalActive = false
        } else {
            guard modes[mode] == "PHOTO" else { return }
            intervalActive = true
            engine.captureForMode("PHOTO")
            intervalTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(intervalSeconds), repeats: true) { _ in
                engine.captureForMode("PHOTO")
            }
        }
    }
    private func rackFocus() {
        focusTargetNear.toggle()
        let target: Float = focusTargetNear ? 0.15 : 0.9
        // Smooth stepped lens transition for a simple cinematic rack-focus effect.
        let initial = engine.manualFocus
        for step in 1...16 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.07) {
                engine.setManualFocus(initial + (target - initial) * Float(step) / 16)
            }
        }
    }
    @State private var editContrast: Double = 1
    @State private var editSaturation: Double = 1
    @State private var editRotation: Double = 0
    @State private var showSettings = false
    @State private var showGrid = false
    @State private var showLevel = false
    @State private var timer = 0
    @State private var style = 0
    @State private var shutterBusy = false
    @State private var countdownRemaining = 0
    @State private var countdownToken = UUID()
    private func startPhotoCountdown() {
        guard !shutterBusy else { return }
        shutterBusy = true
        let selectedMode = modes[mode]
        if timer == 0 {
            engine.captureForMode(selectedMode)
            shutterBusy = false
            return
        }
        countdownToken = UUID()
        let token = countdownToken
        countdownRemaining = timer
        func tick(_ remaining: Int) {
            guard countdownToken == token else { return }
            countdownRemaining = remaining
            if remaining == 0 {
                engine.captureForMode(selectedMode)
                shutterBusy = false
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick(remaining - 1) }
            }
        }
        tick(timer)
    }
    private func openDualCamera() {
        // Wait for AVCaptureSession.stopRunning() to finish before MultiCam starts.
        // This is necessary in PHOTO mode, where photo/live-photo outputs may still
        // own the camera hardware when the cover is presented.
        engine.stopBeforeDualCamera {
            showDual = true
        }
    }

    @State private var showDual = false
    // Best-effort launch: Apple does not provide a documented Photos-app URL scheme.
    // If the private URL is unsupported, retain the working in-app album fallback.
    private func openSystemPhotosApp() {
        guard let url = URL(string: "photos-redirect://") else {
            showAlbum = true
            return
        }
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                DispatchQueue.main.async { showAlbum = true }
            }
        }
    }

    @State private var showAlbum = false
    @State private var gallerySelection: PhotosPickerItem?
    @State private var galleryImage: UIImage?
    @State private var showGalleryPreview = false
    @State private var showQuickControls = false
    @State private var editingControls = false
    @AppStorage("camera.hiddenQuickControls") private var hiddenQuickControls = ""
    private let quickControlNames = ["FLASH", "LIVE", "ASPECT", "TIMER", "EXPOSURE", "STYLES", "FILTER", "NIGHT", "FORMAT", "MACRO", "SHARED LIBRARY"]
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
    @State private var showFilters = false
    private let availableFilters = ["None", "Vivid", "Vivid Warm", "Vivid Cool", "Dramatic", "Dramatic Warm", "Dramatic Cool", "Mono", "Black & White", "Silvertone", "Noir"]
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
    @State private var panoramaTimer: Timer?
    @State private var panoramaCapturing = false
    private let modes = ["TIME-LAPSE", "SLO-MO", "CINEMATIC", "VIDEO", "PHOTO", "PORTRAIT", "PANO"]
    private let styles = ["Natural", "Vivid", "Mono", "Warm", "Cool"]
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(session: engine.session)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay {
                        if countdownRemaining > 0 {
                            Text("\(countdownRemaining)")
                                .font(.system(size: 104, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.8), radius: 12)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        if showFocusPeaking, let peaking = engine.focusPeakingImage {
                            Image(uiImage: peaking).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped().opacity(0.8).allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        if showZebras, let mask = engine.zebraMask {
                            Image(uiImage: mask).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped().allowsHitTesting(false)
                        }
                    }
                    .overlay { if showGrid { gridOverlay } }
                    .overlay { if showGoldenGuide { goldenGuideOverlay } }
                    .overlay(alignment: .topTrailing) {
                        if showHistogram {
                            HStack(alignment: .bottom, spacing: 1) {
                                ForEach(0..<32, id: \.self) { i in
                                    Rectangle().fill(Color.green.opacity(0.85))
                                        .frame(width: 3, height: max(1, engine.histogramBins[i] * 45))
                                }
                            }.frame(height: 52, alignment: .bottom)
                                .padding(7).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                                .padding(.top, 68).padding(.trailing, 12)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if showScopes {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("RGB PARADE").font(.system(size: 9, weight: .bold))
                                HStack(spacing: 3) {
                                    ForEach(0..<3, id: \.self) { channel in
                                        GeometryReader { _ in
                                            Canvas { context, size in
                                                let color: Color = channel == 0 ? .red : (channel == 1 ? .green : .blue)
                                                for point in engine.rgbWavePoints[channel] {
                                                    let rect = CGRect(x: point.x * size.width, y: (1 - point.y) * size.height, width: 1.5, height: 1.5)
                                                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.55)))
                                                }
                                            }
                                        }.frame(height: 52)
                                    }
                                }
                                Text("LUMA WAVEFORM · SPATIAL").font(.system(size: 9, weight: .bold))
                                Canvas { context, size in
                                    for point in engine.waveformPoints {
                                        context.fill(Path(ellipseIn: CGRect(x: point.x * size.width, y: (1 - point.y) * size.height, width: 1.4, height: 1.4)), with: .color(.white.opacity(0.6)))
                                    }
                                }.frame(height: 52)
                            }
                            .foregroundStyle(.white).padding(8)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                            .padding(.leading, 12).padding(.top, 68).allowsHitTesting(false)
                        }
                    }
                    .overlay { if showLevel { Rectangle().fill(.yellow.opacity(0.85)).frame(height: 1).padding(.horizontal, 30) } }
                    .saturation((filter == "Mono" || filter == "Black & White" || filter == "Silvertone" || filter == "Noir") ? 0 : 1)
                    .contrast(filter == "Black & White" ? 1.22 : (filter == "Noir" ? 1.35 : 1))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if showFilters { withAnimation { showFilters = false } }
                        if showQuickControls { showQuickControls = false; editingControls = false }
                    }
                VStack(spacing: 0) {
                    VStack(spacing: 9) {
                        HStack(spacing: 8) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    topControl("ZEBRA", symbol: "line.3.horizontal.decrease", active: showZebras) {
                                        showZebras.toggle(); engine.setZebras(showZebras)
                                    }
                                    topControl("INTERVAL", symbol: "timer", active: intervalActive) { toggleIntervalometer() }
                                    topControl("RACK", symbol: "viewfinder", active: false) { rackFocus() }
                                    topControl("FLASH", symbol: flashSymbol, active: engine.flashMode != .off) { cycleFlash() }
                                    topControl("LIVE", symbol: "livephoto", active: liveRequested) {
                                        liveRequested.toggle()
                                        engine.setLivePhotoEnabled(liveRequested)
                                    }
                                    topControl("ASPECT", symbol: "aspectratio", active: aspect != "4:3") {
                                        aspect = aspect == "4:3" ? "16:9" : (aspect == "16:9" ? "1:1" : "4:3")
                                        engine.photoAspect = aspect
                                    }
                                    topControl("EXPOSURE", symbol: "plusminus.circle", active: abs(engine.exposureBias) > 0.1) {
                                        withAnimation { showQuickControls = true; showExposure = true }
                                    }
                                    topControl("FILTER", symbol: "camera.filters", active: filter != "None") {
                                        withAnimation { showFilters.toggle(); showQuickControls = false }
                                    }
                                    topControl("STYLES", symbol: "square.stack.3d.up", active: style != 0) {
                                        style = (style + 1) % styles.count
                                        engine.photoStyle = styles[style]
                                    }
                                    topControl("NIGHT", symbol: "moon.stars", active: nightGuide) {
                                        nightGuide.toggle()
                                        engine.setNightProcessing(nightGuide)
                                    }
                                    topControl("MACRO", symbol: "camera.macro", active: engine.macroEnabled) { engine.setMacro(!engine.macroEnabled) }
                                    topControl("SHARED LIBRARY", symbol: "person.2.slash", active: false) {
                                        engine.errorMessage = "Shared Library routing is not implemented in this build."
                                    }
                                    Button { engine.setSubjectTracking(!engine.subjectTrackingEnabled) } label: {
                                        Image(systemName: engine.subjectTrackingEnabled ? "person.crop.rectangle.stack.fill" : "person.crop.rectangle.stack")
                                            .foregroundStyle(engine.subjectTrackingEnabled ? .yellow : .white)
                                            .frame(width: 30, height: 36)
                                    }.accessibilityLabel("Follow moving person")
                                    Button { withAnimation { showProPanel.toggle() } } label: {
                                        Text("PRO").font(.system(size: 12, weight: .heavy))
                                            .foregroundStyle(showProPanel ? .yellow : .white)
                                            .frame(width: 38, height: 36)
                                    }.accessibilityLabel("Professional camera controls")
                                    Button { openDualCamera() } label: {
                                        Image(systemName: "square.on.square").frame(width: 30, height: 36)
                                    }
                                    Button { showSettings = true } label: {
                                        Image(systemName: "gearshape").frame(width: 30, height: 36)
                                    }
                                }
                                .font(.system(size: 19))
                            }
                        }
                        .padding(.horizontal, 9)
                    }
                    .padding(.top, 10).padding(.bottom, 12)
                    .background(Color.black.opacity(0.13))
                    Spacer()
                    if showProPanel {
                        proControls
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                    }
                    if mode == 5 {
                        portraitDial
                    }
                    if showZoomDial {
                        zoomDial
                            // Seamlessly joins the transparent bottom camera drawer.
                            .padding(.bottom, -12)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    HStack(spacing: 12) {
                        ForEach([0.5, 1.0, 3.0], id: \.self) { value in
                            Button {
                                engine.setZoom(value)
                                // Tap chooses a lens; press and swipe to adjust continuously.
                                withAnimation(.easeInOut(duration: 0.15)) { showZoomDial = false }
                            } label: {
                                Text(value == 0.5 ? ".5" : (value == 1 ? "1×" : "3"))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(abs(engine.zoom - value) < 0.12 ? .yellow : .white)
                                    .frame(width: 38, height: 38)
                                    .background(abs(engine.zoom - value) < 0.12 ? Color.black.opacity(0.47) : Color.clear, in: Circle())
                            }
                        }
                    }
                    .padding(2)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { gesture in
                                if zoomDragStart == nil { zoomDragStart = engine.zoom }
                                let start = zoomDragStart ?? engine.zoom
                                let newZoom = min(15.0, max(0.5, start + CGFloat(gesture.translation.width / 18.0)))
                                engine.setZoom(newZoom)
                                if !showZoomDial { withAnimation(.easeOut(duration: 0.12)) { showZoomDial = true } }
                            }
                            .onEnded { _ in
                                zoomDragStart = nil
                                withAnimation(.easeOut(duration: 0.22)) { showZoomDial = false }
                            }
                    )
                    .padding(.bottom, 10)
                    VStack(spacing: 18) {
                        // Reference layout: shutter centered independently of the side controls.
                        HStack(spacing: 0) {
                            Color.clear.frame(maxWidth: .infinity)
                            shutterButton.frame(width: 92, height: 92)
                            Button { withAnimation { showQuickControls.toggle(); if !showQuickControls { editingControls = false } } } label: {
                                VStack(spacing: 4) {
                                    ForEach(0..<2, id: \.self) { _ in
                                        HStack(spacing: 4) {
                                            ForEach(0..<3, id: \.self) { _ in
                                                Circle()
                                                    .fill(Color.white)
                                                    .frame(width: 5, height: 5)
                                            }
                                        }
                                    }
                                }
                                .frame(width: 54, height: 54)
                                .background(Color.black.opacity(0.52), in: Circle())
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .frame(height: 94)
                        HStack(spacing: 0) {
                            Button { openSystemPhotosApp() } label: {
                                Group {
                                    if let thumbnail = lastPhotoThumbnail {
                                        Image(uiImage: thumbnail).resizable().scaledToFill()
                                    } else {
                                        Image(systemName: "photo.on.rectangle.angled").resizable().scaledToFit().padding(14)
                                    }
                                }
                                    .font(.system(size: 23))
                                    .frame(width: 52, height: 52)
                                    .background(.black.opacity(0.48), in: Circle())
                                    .clipShape(Circle())
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            modePicker.frame(width: min(geometry.size.width * 0.60, 290))
                            Button { engine.flip() } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 25))
                                    .frame(width: 56, height: 56)
                                    .background(.black.opacity(0.53), in: Circle())
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                    .background(Color.black.opacity(0.045))
                }
                if showFilters {
                    VStack {
                        Spacer()
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(availableFilters, id: \.self) { name in
                                    Button {
                                        filter = name
                                        engine.photoFilter = name
                                    } label: {
                                        VStack(spacing: 5) {
                                            Image(systemName: "camera.filters")
                                                .font(.system(size: 21))
                                                .frame(width: 54, height: 54)
                                                .background(filter == name ? Color.yellow.opacity(0.32) : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                                            Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                        }
                                        .foregroundStyle(filter == name ? .yellow : .white)
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal, 14)
                        }
                    }
                    .padding(.bottom, 300)
                    .background(alignment: .bottom) { Color.clear }
                }
                if engine.nightCapturing {
                    VStack(spacing: 12) {
                        Text("HOLD STILL")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text("Night Mode · \(engine.nightSecondsRemaining)s")
                            .font(.system(size: 22, weight: .medium, design: .rounded))
                            .foregroundStyle(.yellow)
                    }
                    .padding(24)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
                    .allowsHitTesting(false)
                }
                if showQuickControls {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { showQuickControls = false; editingControls = false } }
                    VStack(spacing: 0) {
                        HStack {
                            Text("Quick Controls").font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Button { withAnimation(.easeInOut(duration: 0.2)) { editingControls.toggle() } } label: {
                                Text(editingControls ? "Done" : "Edit")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(.black.opacity(0.38), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
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
            .onAppear { engine.photoAspect = aspect; engine.photoFilter = filter; engine.photoStyle = styles[style]; engine.start(); engine.setHistogram(showHistogram); engine.setVideoPreferences(quality: videoQuality, fps: videoFPS); loadLastThumbnail() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in loadLastThumbnail() }
            .onDisappear { intervalTimer?.invalidate(); intervalTimer = nil; intervalActive = false; burstTimer?.invalidate(); burstTimer = nil; burstActive = false; engine.stop() }
            .onChange(of: engine.errorMessage) { message in
                if let message = message, message.contains("Live Photo") { liveRequested = false }
            }
            .onChange(of: showDual) { opening in
                // The single-camera session is already fully stopped before presentation.
                if !opening { engine.start() }
            }
            .fullScreenCover(isPresented: $showDual) { DualCameraView() }
            .fullScreenCover(isPresented: $showAlbum) { CameraAlbumView() }
            .sheet(isPresented: $showDocumentScanner) {
                DocumentScannerView(exportedPDF: $scanPDF, errorText: $scanError)
                    .ignoresSafeArea()
            }
            .sheet(item: Binding<ScanExportItem?>(
                get: { scanPDF.map { ScanExportItem(url: $0) } },
                set: { if $0 == nil { scanPDF = nil } }
            )) { item in
                ScanPDFShare(url: item.url)
            }
            .alert("Document Scanner", isPresented: Binding(
                get: { scanError != nil },
                set: { if !$0 { scanError = nil } }
            )) { Button("OK") { scanError = nil } } message: {
                Text(scanError ?? "")
            }
            .sheet(isPresented: $showPhotoEditor) {
                NavigationStack {
                    VStack(spacing: 18) {
                        if let image = galleryImage {
                            Image(uiImage: image).resizable().scaledToFit()
                                .brightness(editBrightness).contrast(editContrast).saturation(editSaturation)
                                .rotationEffect(.degrees(editRotation))
                                .frame(maxHeight: 380)
                        } else { Text("Import an image from the gallery to edit") }
                        PhotosPicker("Choose Photo", selection: $gallerySelection, matching: .images)
                        sliderRow("Brightness", value: $editBrightness, range: -1...1)
                        sliderRow("Contrast", value: $editContrast, range: 0.5...2)
                        sliderRow("Saturation", value: $editSaturation, range: 0...2)
                        sliderRow("Highlights", value: $editHighlights, range: -1...1)
                        sliderRow("Shadows", value: $editShadows, range: -1...1)
                        sliderRow("Sharpness", value: $editSharpness, range: 0...2)
                        sliderRow("Vignette", value: $editVignette, range: 0...2)
                        sliderRow("Warmth", value: $editWarmth, range: -1...1)
                        sliderRow("Center crop", value: $editCrop, range: 0.4...1)
                        Button("Rotate 90°") { editRotation += 90 }
                        Button(objectEraseBusy ? "Processing foreground…" : "Remove Foreground Subject (AI Mask)") { removeForegroundSubject() }
                            .disabled(galleryImage == nil || objectEraseBusy)
                        if let objectEraseMessage { Text(objectEraseMessage).font(.caption).foregroundStyle(.secondary) }
                        Button("Save Edited Copy") { saveEditedPhoto() }.disabled(galleryImage == nil)
                    }.padding().navigationTitle("Photo Editor")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { showPhotoEditor = false } } }
                }.preferredColorScheme(.dark)
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
                        Section("Professional Tools") {
                            Toggle("Live histogram", isOn: $showHistogram).onChange(of: showHistogram) { engine.setHistogram($0) }
                            Toggle("Waveform and RGB parade", isOn: $showScopes).onChange(of: showScopes) { engine.setScopes($0) }
                            Toggle("Video stabilization (cinematic where supported)", isOn: $actionStabilization).onChange(of: actionStabilization) { engine.setStabilization($0) }
                            Toggle("Focus peaking (red edges)", isOn: $showFocusPeaking).onChange(of: showFocusPeaking) { engine.setFocusPeaking($0) }
                            Toggle("Eye autofocus (Vision face landmarks)", isOn: $eyeAFEnabled)
                                .onChange(of: eyeAFEnabled) { engine.setEyeAutofocus($0) }
                            Button(burstActive ? "Stop Burst" : "Capture 10-Photo Burst") { showSettings = false; toggleBurst() }
                            Button("Capture Exposure Bracket (-1, 0, +1 EV)") { showSettings = false; captureBracket() }
                            Button(engine.lightPaintingActive ? "Finish & Save Light Painting" : "Start Light Painting (up to 2 min)") {
                                showSettings = false
                                engine.toggleLightPainting()
                            }
                            Text("Keep the camera steady. Light painting composites the brightest parts of sampled frames; tap again to save. Resolution is limited to approximately 960 pixels on the longest side.")
                                .font(.footnote).foregroundStyle(.secondary)

                            Text("Burst saves the 10 individual frames plus an additional sharpest-frame selection using edge-detail scoring. Exposure bracketing still saves three separate photos; HDR merging is not included.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Toggle("Golden-ratio guide", isOn: $showGoldenGuide)
                            Toggle("RAW (DNG) photos", isOn: Binding(get: { engine.rawEnabled }, set: { engine.setRAW($0) }))
                            Button("Open Pro Controls") { showSettings = false; showProPanel = true }
                            Button("Open Photo Editor") { showSettings = false; showPhotoEditor = true }
                            Text("RAW requires supported hardware and is unavailable with Live Photo. Pro controls depend on camera capabilities.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("Camera") {
                            Toggle("Grid", isOn: $showGrid)
                            Toggle("Level guide", isOn: $showLevel)
                            Picker("Photo timer", selection: $timer) { Text("Off").tag(0); Text("3 seconds").tag(3); Text("10 seconds").tag(10) }
                            Picker("Preview style", selection: $style) { ForEach(0..<styles.count, id: \.self) { i in Text(styles[i]).tag(i) } }
                            Text("Selected filters are applied to saved photos and exported videos. Video filtering happens after recording and may take time.").font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("Document Scanner") {
                            Button("Scan Documents to PDF") {
                                showSettings = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    showDocumentScanner = true
                                }
                            }
                            Text("Scan and correct multiple pages using Apple's document scanner, then share or save the PDF.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("Dual Camera") {
                            Button { showSettings = false; openDualCamera() } label: {
                                Label("Open Front + Back Preview", systemImage: "square.on.square")
                            }
                            Text("Captures front and rear cameras in PiP or split-screen, for photos and videos.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("Photo Preferences") {
                            Toggle("Mirror front camera selfies", isOn: $mirrorSelfies)
                            Toggle("Prefer HEIF format", isOn: $preferHEIF)
                            Toggle("Location tags", isOn: $locationTags)
                            Text("These preferences are reserved for future capture pipeline integration.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("Subject Tracking") {
                            Toggle("Follow moving person (focus and exposure)", isOn: Binding(
                                get: { engine.subjectTrackingEnabled },
                                set: { engine.setSubjectTracking($0) }
                            ))
                            if engine.subjectTrackingEnabled {
                                Text(engine.trackingSubjectFound ? "Person detected — tracking focus" : "Looking for a person")
                                    .foregroundStyle(.secondary)
                            }
                            Text("Tracks a person with on-device detection and adjusts focus/exposure. This does not physically pan the camera or reframe the recorded video.")
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
                            Button("Apply Video Settings") { engine.setVideoPreferences(quality: videoQuality, fps: videoFPS) }
                            Text("Video resolution and frame rate are applied where supported. Some lens combinations may use fallback settings.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("Interface") {
                            Toggle("Preserve last mode", isOn: $preserveMode)
                            Toggle("Live histogram", isOn: $showHistogram).onChange(of: showHistogram) { engine.setHistogram($0) }
                        }
                        Section("About") { Text("Camera-inspired interface. Recording capabilities depend on your device hardware.") }
                    }.navigationTitle("Camera Settings").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
                }.preferredColorScheme(.dark)
            }
            .alert("Camera", isPresented: Binding(get: { engine.errorMessage != nil }, set: { if !$0 { engine.errorMessage = nil } })) { Button("OK", role: .cancel) { engine.errorMessage = nil } } message: { Text(engine.errorMessage ?? "") }
        }
    }
    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(.caption); Spacer(); Text(String(format: "%.2f", value.wrappedValue)).font(.caption.monospacedDigit()) }
            Slider(value: value, in: range)
        }
    }
    private var proControls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("PRO CONTROLS").font(.caption.bold())
                Spacer()
                Button("AUTO") { engine.resetManualControls() }
                Button { showProPanel = false } label: { Image(systemName: "xmark.circle.fill") }
            }
            sliderRow("ISO", value: $proISO, range: 25...1600)
                .onChange(of: proISO) { engine.setManualExposure(iso: Float($0), shutter: proShutter) }
            sliderRow("Shutter (seconds)", value: $proShutter, range: 0.000125...30)
                .onChange(of: proShutter) { engine.setManualExposure(iso: Float(proISO), shutter: $0) }
            sliderRow("Manual focus", value: $proFocus, range: 0...1)
                .onChange(of: proFocus) { engine.setManualFocus(Float($0)) }
            sliderRow("White balance (K)", value: $proKelvin, range: 2500...9000)
                .onChange(of: proKelvin) { engine.setWhiteBalance(Float($0)) }
        }.padding(12).background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14))
    }
    private var goldenGuideOverlay: some View {
        GeometryReader { g in
            Path { path in
                for f in [0.382, 0.618] {
                    path.move(to: CGPoint(x: g.size.width * f, y: 0))
                    path.addLine(to: CGPoint(x: g.size.width * f, y: g.size.height))
                    path.move(to: CGPoint(x: 0, y: g.size.height * f))
                    path.addLine(to: CGPoint(x: g.size.width, y: g.size.height * f))
                }
            }.stroke(.yellow.opacity(0.6), lineWidth: 0.8)
        }.allowsHitTesting(false)
    }
    // Vision segments the prominent subject. Core Image fills the resulting hole using
    // a blurred background approximation; this is NOT generative object inpainting.
    private func removeForegroundSubject() {
        guard let input = galleryImage, let cgImage = input.cgImage else { return }
        guard #available(iOS 17.0, *) else { objectEraseMessage = "Requires iOS 17 or later."; return }
        objectEraseBusy = true
        objectEraseMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let request = VNGenerateForegroundInstanceMaskRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try handler.perform([request])
                guard let observation = request.results?.first else { throw NSError(domain: "CameraClone", code: 1, userInfo: [NSLocalizedDescriptionKey: "No foreground subject detected."]) }
                let maskBuffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
                let image = CIImage(cgImage: cgImage)
                let mask = CIImage(cvPixelBuffer: maskBuffer)
                let expanded = mask.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 6])
                let blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 42]).cropped(to: image.extent)
                let blended = blurred.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: expanded])
                let context = CIContext()
                guard let output = context.createCGImage(blended, from: image.extent) else { throw NSError(domain: "CameraClone", code: 2) }
                DispatchQueue.main.async {
                    self.galleryImage = UIImage(cgImage: output)
                    self.objectEraseMessage = "Foreground masked and filled approximately. Review edges before saving."
                    self.objectEraseBusy = false
                }
            } catch {
                DispatchQueue.main.async { self.objectEraseMessage = error.localizedDescription; self.objectEraseBusy = false }
            }
        }
    }
    private func saveEditedPhoto() {
        guard let original = galleryImage, let cg = original.cgImage else { return }
        let source = CIImage(cgImage: cg)
        let color = CIFilter(name: "CIColorControls")!
        color.setValue(source, forKey: kCIInputImageKey)
        color.setValue(editBrightness, forKey: kCIInputBrightnessKey)
        color.setValue(editContrast, forKey: kCIInputContrastKey)
        color.setValue(editSaturation, forKey: kCIInputSaturationKey)
        guard var result = color.outputImage else { return }
        if let tone = CIFilter(name: "CIHighlightShadowAdjust", parameters: [kCIInputImageKey: result, "inputHighlightAmount": 1 + editHighlights, "inputShadowAmount": editShadows + 0.5])?.outputImage { result = tone }
        if editSharpness > 0, let sharp = CIFilter(name: "CISharpenLuminance", parameters: [kCIInputImageKey: result, "inputSharpness": editSharpness])?.outputImage { result = sharp }
        if editVignette > 0, let vignette = CIFilter(name: "CIVignette", parameters: [kCIInputImageKey: result, kCIInputIntensityKey: editVignette, kCIInputRadiusKey: 1.5])?.outputImage { result = vignette }
        if editWarmth != 0, let warm = CIFilter(name: "CITemperatureAndTint", parameters: [kCIInputImageKey: result, "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - editWarmth * 2400, y: 0)])?.outputImage { result = warm }
        let insetX = result.extent.width * (1 - editCrop) / 2
        let insetY = result.extent.height * (1 - editCrop) / 2
        result = result.cropped(to: result.extent.insetBy(dx: insetX, dy: insetY))
        let transformed = result.transformed(by: CGAffineTransform(rotationAngle: CGFloat(editRotation * .pi / 180)))
        let context = CIContext()
        guard let output = context.createCGImage(transformed, from: transformed.extent) else { return }
        let image = UIImage(cgImage: output)
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        showPhotoEditor = false
    }
    private func togglePanoramaSweep() {
        if panoramaCapturing {
            panoramaTimer?.invalidate()
            panoramaTimer = nil
            panoramaCapturing = false
            // Allow the last asynchronous photo callback to finish before stitching.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                engine.finishPanorama()
            }
        } else {
            panoramaCapturing = true
            engine.captureForMode("PANO")
            panoramaTimer?.invalidate()
            panoramaTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: true) { timer in
                if engine.panoramaCount >= 10 {
                    timer.invalidate()
                    panoramaTimer = nil
                    panoramaCapturing = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        engine.finishPanorama()
                    }
                } else {
                    engine.captureForMode("PANO")
                }
            }
        }
    }

    private var shutterButton: some View {
        Button {
            if [0, 1, 2, 3].contains(mode) {
                engine.toggleRecording(kind: modes[mode])
            }
            else if mode == 6 { togglePanoramaSweep() }
            else { startPhotoCountdown() }
        } label: {
            Circle()
                .fill(([0, 1, 2, 3].contains(mode) || (mode == 6 && panoramaCapturing)) ? Color.red : Color.white)
                .frame(width: 72, height: 72)
                .overlay { Circle().stroke(.white, lineWidth: 3).frame(width: 84, height: 84) }
                .overlay { if engine.recording || (mode == 6 && panoramaCapturing) { RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 23, height: 23) } }
        }
        .frame(width: 92, height: 92)
    }

    private var zoomDial: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let radius = width * 0.56
            let center = CGPoint(x: width / 2, y: radius + 8)
            ZStack(alignment: .topLeading) {
                // The semicircular scale stays fixed in position while its
                // graduations move beneath the yellow center pointer.
                Path { path in
                    path.addArc(center: center, radius: radius,
                                startAngle: .degrees(180), endAngle: .degrees(360),
                                clockwise: false)
                    path.addLine(to: CGPoint(x: width, y: geometry.size.height))
                    path.addLine(to: CGPoint(x: 0, y: geometry.size.height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [Color.black.opacity(0.015), Color.black.opacity(0.045)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

                ForEach(0..<146, id: \.self) { index in
                    let tickZoom = 0.5 + CGFloat(index) * 0.1
                    let angle = Double((tickZoom - engine.zoom) * 12)
                    let radians = (angle - 90) * .pi / 180
                    let x = center.x + radius * CGFloat(cos(radians))
                    let y = center.y + radius * CGFloat(sin(radians))
                    if abs(angle) <= 90 {
                        Capsule()
                            .fill(Color.white.opacity(index % 5 == 0 ? 0.9 : 0.48))
                            .frame(width: index % 5 == 0 ? 1.5 : 1, height: index % 5 == 0 ? 18 : 9)
                            .rotationEffect(.degrees(angle))
                            .position(x: x, y: y)
                    }
                }

                ForEach([0.5, 1.0, 3.0, 5.0, 10.0, 15.0], id: \.self) { value in
                    let angle = Double((value - engine.zoom) * 12)
                    let radians = (angle - 90) * .pi / 180
                    let labelRadius = radius - 43
                    // Never draw a scale label under the yellow selection pointer;
                    // the live zoom readout below is the only center value.
                    if abs(angle) <= 76 && abs(angle) > 15 {
                        Text(value == 0.5 ? "0.5" : String(format: "%.0f", value))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .position(x: center.x + labelRadius * CGFloat(cos(radians)),
                                      y: center.y + labelRadius * CGFloat(sin(radians)))
                    }
                }

                Image(systemName: "triangle.fill")
                    .font(.system(size: 11))
                    .rotationEffect(.degrees(180))
                    .foregroundStyle(.yellow)
                    .position(x: center.x, y: center.y - radius + 10)

                Text(String(format: "%.1f×", Double(engine.zoom)))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.yellow)
                    .position(x: center.x, y: 49)
            }
            .frame(width: width, height: geometry.size.height)
            .clipped()
        }
        .frame(height: 160)
        .allowsHitTesting(false)
    }

    private var portraitDial: some View {
        VStack(spacing: 2) {
            Text(portraitLights[portraitLighting])
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            GeometryReader { proxy in
                let radius = min(proxy.size.width * 0.30, CGFloat(115))
                ZStack {
                    ForEach(0..<73, id: \.self) { tick in
                        let angle = Double(tick - 36 - portraitLighting * 10) * 2.0
                        Capsule()
                            .fill(tick % 6 == 0 ? .white.opacity(0.85) : .white.opacity(0.4))
                            .frame(width: 1.5, height: tick % 6 == 0 ? 15 : 8)
                            .offset(y: -radius + 16)
                            .rotationEffect(.degrees(angle))
                            .opacity(abs(angle) < 85 ? 1 : 0)
                    }
                    Image(systemName: "triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.yellow)
                        .rotationEffect(.degrees(180)).offset(y: -radius + 8)
                    Text(portraitLights[portraitLighting])
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.yellow)
                }
                .frame(width: proxy.size.width, height: 78)
                .contentShape(Rectangle())
            }.frame(height: 78)
            HStack(spacing: 13) {
                ForEach(portraitLights.indices, id: \.self) { index in
                    Button { withAnimation { portraitLighting = index; showPortraitDial = true } } label: {
                        Circle().fill(index == portraitLighting ? .yellow : .white.opacity(0.45))
                            .frame(width: index == portraitLighting ? 12 : 8, height: index == portraitLighting ? 12 : 8)
                    }
                }
            }
        }
        .frame(height: 108)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { gesture in
                    if portraitDragStart == nil { portraitDragStart = CGFloat(portraitLighting) }
                    let initial = portraitDragStart ?? 0
                    let value = Int((initial - gesture.translation.width / 30).rounded())
                    portraitLighting = max(0, min(portraitLights.count - 1, value))
                    showPortraitDial = true
                }
                .onEnded { _ in
                    portraitDragStart = nil
                    withAnimation(.easeOut(duration: 0.2)) { showPortraitDial = false }
                }
        )
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
                                    if mode == 6 && index != 6 {
                                        panoramaTimer?.invalidate()
                                        panoramaTimer = nil
                                        panoramaCapturing = false
                                        if engine.panoramaCount >= 2 { engine.finishPanorama() }
                                    }
                                    mode = index
                                    showZoomDial = false
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
                                        if mode == index {
                                            Capsule().fill(.ultraThinMaterial).opacity(0.60)
                                                .overlay { Capsule().stroke(.white.opacity(0.36), lineWidth: 0.7) }
                                        }
                                    }
                            }
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    .frame(width: proxy.size.width / 3)
                }
            }
            .background { Capsule().fill(.ultraThinMaterial).opacity(0.53).overlay { Capsule().fill(Color.black.opacity(0.22)) } }
            .overlay { Capsule().stroke(.white.opacity(0.24), lineWidth: 0.6) }
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
    private func topControl(_ name: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Group {
            if !isControlHidden(name) {
                Button {
                    if !editingControls { action() }
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(active ? Color.yellow : Color.white)
                        .frame(width: 30, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onLongPressGesture(minimumDuration: 0.5) { editingControls = true }
                .overlay(alignment: .topTrailing) {
                    if editingControls {
                        Button { withAnimation { hideControl(name) } } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.red, .white)
                        }
                        .offset(x: 2, y: -5)
                    }
                }
            }
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
                                .frame(width: 55, height: 55)
                                .background(.black.opacity(0.24), in: Circle())
                                .overlay { Circle().stroke(.white.opacity(0.15), lineWidth: 0.6) }
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
                quickTile("LIVE", icon: "livephoto", active: liveRequested) { liveRequested.toggle(); engine.setLivePhotoEnabled(liveRequested) }
                quickTile("ASPECT", icon: "aspectratio", active: aspect != "4:3") {
                    aspect = aspect == "4:3" ? "16:9" : (aspect == "16:9" ? "1:1" : "4:3")
                    engine.photoAspect = aspect
                }
            }
            HStack {
                quickTile("TIMER \(timer == 0 ? "OFF" : "\(timer)s")", icon: "timer", active: timer != 0) { timer = timer == 0 ? 3 : (timer == 3 ? 10 : 0) }
                quickTile("EXPOSURE", icon: "plusminus.circle", active: abs(engine.exposureBias) > 0.1) { showExposure.toggle() }
                quickTile("STYLES", icon: "square.stack.3d.up", active: style != 0) { style = (style + 1) % styles.count; engine.photoStyle = styles[style] }
            }
            HStack {
                quickTile("FILTER", icon: "camera.filters", active: filter != "None") { withAnimation { showFilters.toggle(); showQuickControls = false } }
                quickTile("NIGHT", icon: "moon.stars", active: nightGuide) { nightGuide.toggle(); engine.setNightProcessing(nightGuide) }
                quickTile("FORMAT", icon: "photo", active: preferHEIF) { preferHEIF.toggle(); engine.errorMessage = "Format preference saved. This build uses the native photo output format." }
            }
            quickTile("MACRO", icon: "camera.macro", active: engine.macroEnabled) { engine.setMacro(!engine.macroEnabled) }
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
        }
        .padding(.vertical, 16)
        .background { RoundedRectangle(cornerRadius: 26).fill(.ultraThinMaterial).opacity(0.43) }
        .overlay { RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.20), lineWidth: 0.8) }
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


// Full-screen camera album. Swipe horizontally through Photos and tap Close to return to camera.
struct CameraAlbumView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var assets: [PHAsset] = []
    @State private var selectedIndex: Int? = nil
    @State private var accessDenied = false

    var body: some View {
        NavigationStack {
            Group {
                if assets.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "photo.on.rectangle.angled").font(.largeTitle)
                        Text(accessDenied ? "Allow Photos access in Settings" : "No photos found")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                            ForEach(assets.indices, id: \.self) { index in
                                Button { selectedIndex = index } label: {
                                    CameraAlbumThumbnail(asset: assets[index])
                                        .frame(maxWidth: .infinity)
                                        .aspectRatio(1, contentMode: .fit)
                                        .clipped()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .background(Color.black)
            .foregroundStyle(.white)
            .navigationTitle("Albums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Camera") { dismiss() }
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedIndex != nil },
                set: { if !$0 { selectedIndex = nil } }
            )) {
                TabView(selection: Binding(
                    get: { selectedIndex ?? 0 },
                    set: { selectedIndex = $0 }
                )) {
                    ForEach(assets.indices, id: \.self) { i in
                        CameraAlbumPage(asset: assets[i]).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .background(Color.black)
                .navigationTitle("\((selectedIndex ?? 0) + 1) / \(assets.count)")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .preferredColorScheme(.dark)
        .task { await loadPhotos() }
    }

    @MainActor private func loadPhotos() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { accessDenied = true; return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 500
        let fetched = PHAsset.fetchAssets(with: .image, options: options)
        var items: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in items.append(asset) }
        assets = items
    }
}

struct CameraAlbumThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geo in
            Group {
                if let image = image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.gray.opacity(0.25))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .task(id: asset.localIdentifier) {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 350, height: 350), contentMode: .aspectFill, options: options) { result, _ in
                DispatchQueue.main.async { image = result }
            }
        }
    }
}

struct CameraAlbumPage: View {
    let asset: PHAsset
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: asset.localIdentifier) {
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            let target = CGSize(width: 1800, height: 2400)
            PHImageManager.default().requestImage(for: asset, targetSize: target,
                                                  contentMode: .aspectFit, options: options) { result, _ in
                DispatchQueue.main.async { image = result }
            }
        }
    }
}

private struct ScanExportItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
