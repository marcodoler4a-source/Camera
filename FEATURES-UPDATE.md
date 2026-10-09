# CameraClone Scopes and Foreground Removal Upgrade

- Replaces averaged luma waveform bars with spatial waveform point plotting.
- Replaces RGB histograms labeled parade with spatial per-channel RGB scope plotting.
- Adds Vision foreground segmentation to the Photo Editor on iOS 17+, followed by blurred-background approximate fill. This is NOT generative inpainting or a general-purpose brush object eraser.
- Preserves the existing AVFoundation cinematic video stabilization toggle; full Action Mode equivalent is not implemented.
- This source has not been built on macOS/Xcode or tested on iPhone.
