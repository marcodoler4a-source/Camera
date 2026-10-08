# Camera Clone — iPhone 17-inspired starter app

A SwiftUI/AVFoundation camera app for iPhone. Includes a live camera preview, photo capture, video recording with audio, photo/video save to Photos, front/rear switching, tap focus/exposure, zoom shortcuts, flash control, grid, level guide, timer, and settings.

**Not a full clone of Apple's Camera app.** iPhone 17-only hardware capabilities (48 MP Fusion sensors, 18 MP Center Stage sensor, hardware-specific Cinematic/Action/ProRes RAW/Apple Log 2 features) cannot be added to an older iPhone by software. Preview style selection is not baked into captures. Zoom shortcuts are digital zoom of the active lens, not guaranteed optical lens switching. The app has not been compiled on Xcode here; build on Codemagic and resolve any platform-specific diagnostics before signing.

## GitHub and Codemagic
1. Extract the ZIP and upload its contents, preserving the `CameraClone.xcodeproj` folder.
2. Connect the GitHub repository to Codemagic.
3. Run workflow `ios-unsigned`.
4. Download `CameraClone-unsigned.ipa`, then sign with your own valid provisioning profile/certificate and sideload. An unsigned IPA cannot install directly.

Camera and microphone access are requested at runtime. Photos add-only permission is requested when saving. Minimum deployment target is iOS 16.

## Dual Camera update
Front + back simultaneous live previews using AVCaptureMultiCamSession. Switch PiP and split layouts. Dual recording is NOT implemented in this build. Photo and video preference controls marked as planned do not yet affect output. Device-specific Apple Camera features cannot all be cloned.

## Dual-camera recording
Dual Camera now records front and rear feeds into one H.264 MOV, saved to Photos. Select PiP or split view and tap the record button. The current implementation is **video-only (no microphone audio)**. Recording resolution is 720×1280 and performance depends on available MultiCam resources. Build and device testing are required.

## Customizable camera controls
Long-press a quick control to enter edit mode. Tap the red minus badge to hide that control from the camera screen. Tap Done to finish. Settings > Quick Controls lets you re-enable individual controls or restore all.

## Hardware support
The app runs on supported iOS devices but cannot add iPhone 17 Pro camera sensors, 48MP hardware, Center Stage hardware, 40x zoom optics, Camera Control hardware, ProRes RAW, Apple Log 2 or Genlock to an iPhone 13 Pro Max. Advanced capture features require device-specific implementation and capability checks; this build does not claim to implement those modes. Some current UI settings are preview-only.


## Shooting modes update
- Photo and Video retained.
- Slo-Mo: selects a 120 fps capable capture format when available, records and retimes the result to quarter speed. Availability depends on active lens and device.
- Time-Lapse: records video and exports it at 8x playback speed (not intermittent frame acquisition).
- Portrait: requests depth data in the captured photo where AVFoundation supports it. Does not apply Apple Camera's background blur automatically.
- Pano: takes multiple overlapping frames; Finish Pano saves a basic horizontal image strip. This is NOT perspective-aware panorama stitching.
- Cinematic: listed in the selector but deliberately shows an unsupported message instead of silently saving ordinary video. Cinematic depth-of-field rendering is not implemented.

This update has NOT been compiled with Xcode; run Codemagic and share any compiler errors.
