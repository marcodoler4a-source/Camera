# CameraClone — SideStore-ready unsigned IPA

This project preserves the existing camera features and large semicircular zoom dial.

## Build on Codemagic
1. Upload/commit this project to GitHub.
2. Run the `ios-unsigned` workflow in Codemagic.
3. Download the generated `CameraClone-unsigned.ipa` artifact.

## Install with SideStore
1. Open SideStore on your iPhone, with its required VPN and Wi-Fi connected.
2. Use the **My Apps** / **+** option to select `CameraClone-unsigned.ipa` from Files.
3. Allow SideStore to sign and install the app with your configured Apple account.
4. Refresh the app in SideStore before its signing period expires.

## About AppleJR's 'Error Password'
That error is associated with the selected signing certificate and its .p12 password.
This ZIP does **not** include a signing certificate or password and cannot repair AppleJR's
server-side signing credentials. Use a working certificate/password in AppleJR, or SideStore.

## Notes
The IPA is intentionally unsigned; it is not directly installable without signing.
Codemagic and device compilation have not been run in this environment.


Panorama sweep: in PANO mode tap shutter once to begin periodic overlapping captures, sweep steadily, then tap again to stitch and save. This is a basic sequential-frame panorama, not optical-flow guided Apple Camera panorama.
