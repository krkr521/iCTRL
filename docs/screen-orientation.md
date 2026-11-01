# Native18 screenshot orientation candidate

Base: Native17 source `94fded5c19337b89122592ac5f4d522b99aac3a3`.
Candidate branch: `sol/orientation-fix-20261101`.

## Change

The previous screenshot implementation captured a fresh UIImage but rendered it
into a session-cached `app.frame` width and height. A landscape image could be
stretched into the portrait dimensions first observed by the runner. Metadata
also described the requested floating-point dimensions rather than the encoded
bitmap's integer dimensions.

`ScreenCaptureGeometry` now derives oriented pixel dimensions from
`UIImage.size * UIImage.scale` and screen points from those pixels divided by the
device scale. UIImage.size already accounts for imageOrientation. UIKit drawing
applies its orientation metadata once; no device-angle guess or additional
90-degree swap is used. The output drawing uses a uniform scale. Only the bitmap
canvas is rounded to integral pixels, with at most a half-pixel edge difference.
JSON pixel dimensions come from the rendered CGImage. An encoding failure no
longer falls back to differently sized original bytes.

For example, a 402 x 874 point screen captured at 3x and requested at 2x returns
804 x 1748 pixels in portrait, and 1748 x 804 in landscape. The capture itself is
the authority for which geometry applies.

The point-size cache is cleared at each UI dispatch. The existing pre-action
capture is reused when present; other spatial calls obtain current capture
geometry on first access, falling back to a fresh AX frame if capture fails.
Screenshot and OCR refresh the cache from their own frame. Orientation-dependent
overlay, PiP and coverage caches are cleared when the point dimensions change.
This can add one capture to calls that previously reused a session-long size.

Vision and the screen-settle image paths normalize UIImage orientation before
reading its CGImage. OCR boxes use the same captured geometry, and screen_text
now returns point_width and point_height. Touch synthesis is unchanged; this
change does not assert a hardware-verified landscape touch transform.

An explicitly app-scoped screenshot keeps the captured window's aspect ratio
and reports `coordinate_space: captured_window_points`. Its hint asks the caller
to use a full-screen screenshot before mapping to global touch coordinates; an
unknown cropped-window origin is not silently treated as screen origin.

Apple's contracts for [UIImage.size](https://developer.apple.com/documentation/uikit/uiimage/size)
and [UIImage.Orientation](https://developer.apple.com/documentation/uikit/uiimage/orientation)
are the basis for the image geometry and normalization. Physical phone acceptance
remains separate from those API contracts and from simulator tests.

## Tests and build

The Swift package includes five geometry tests: portrait/landscape/portrait,
UIImage scale normalization, fractional output scale, invalid geometry, and
Vision's bottom-left to top-left conversion.

The independent `Tests/ScreenCaptureImage` Xcode project contains four UIKit
tests. It checks all eight UIImage orientations with four colored corners,
PNG/JPEG, 1x/2x output, OCR normalization, fractional encoded dimensions, and
invalid encoding parameters. It has no iCTRL app dependency, phone connection,
signing account, pairing material or long-running server test.

On a Mac with the existing Xcode and iPhone Simulator:

```sh
swift test
bash Scripts/test-screen-capture-image.sh
```

`Scripts/build-unsigned.sh` runs both suites and the existing package checks
before producing release/iCTRL.ipa, release/iCTRLUITests-Runner.ipa and the build
manifest. The existing manual workflow `.github/workflows/native-unsigned.yml`
uses Xcode 16.4 and now also uploads `screen-capture-image-tests.log`.
The simulator script selects an already installed iPhone Simulator; it does not
download a runtime or connect to a physical phone.

Local Windows validation on 2026-11-01: the 11 build-manifest Python tests passed;
the YAML files parsed, test source paths resolved, version metadata agreed on
1.98.18 / build 18, shell scripts passed `bash -n`, and `git diff --check` passed.
Swift, UIKit and xcodebuild were unavailable locally. The nine new Swift test
methods have therefore been authored but not run in this workspace. No build,
push, workflow dispatch, signing, install or phone interaction was performed.

## Installation and acceptance route

After a reviewed Native18 build succeeds, verify the workflow head SHA, artifact
hashes, build manifest and both IPA version plists. Use a new Native18 artifact
directory; retain the previously verified Native17 packages and manifest.

The existing installation route uses the original SideStore identity to re-sign
and overwrite Main first, then Runner, retaining the Share extension. The unsigned
IPAs are not directly installable signed packages. The repository also retains
the existing macOS `Scripts/sign-ipa.sh` route for an appropriate developer
identity and profile; no signing material is included in this change.

After installation, confirm Main and Runner build 18 and runtime version
1.98.18-krkr.native18. Capture portrait, landscape left, landscape right, and a
return to portrait. For each capture, compare decoded PNG/JPEG dimensions with
JSON metadata, verify the image is not stretched, and compare device_info and
screen_text point dimensions with the same orientation. Verify OCR locations
against visible text. Only an explicitly authorized harmless touch on the real
phone can establish the separate touch-coordinate behavior. Preserve screenshots
and results by build; a successful compile is not physical screen acceptance.
