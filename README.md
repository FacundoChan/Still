<p align="center">
  <img src="docs/images/icon.png" width="160" alt="Still app icon: yellow trim brackets around a white dot">
</p>

<h1 align="center">Still</h1>

<p align="center">
  <strong>Turn any moment of a video into a real Live Photo.</strong><br>
  Trim, retime, and crop a few seconds of video on your Mac, then save a Live Photo that Photos plays like one shot on iPhone.
</p>

<p align="center">
  <a href="https://github.com/FacundoChan/Still/actions/workflows/build.yml"><img src="https://github.com/FacundoChan/Still/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white" alt="macOS 26 or later">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/universal-Apple%20silicon%20%2B%20Intel-555555" alt="Universal binary">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

<p align="center">
  <img src="docs/images/editor.webp" width="880" alt="Still's editor: a coastline video on the stage, yellow trim brackets on both timeline strips with a Make Key Photo bubble, and the inspector with speed, duration, crop, sound, and Key Photo controls">
</p>

## Features

- **Genuine Live Photos.** Still writes the same paired JPEG and MOV the iPhone camera does, with a shared content identifier and a still-image marker, so Photos treats the result as a real Live Photo. It isn't a GIF or a plain video.
- **Make Key Photo, like on iPhone.** Scrub to any frame and click the bubble. If the frame is outside the selection, the selection comes to it.
- **Trim with brackets.** Yellow brackets trim directly. A two-level timeline lets you place a 3-second clip precisely in a 10-minute video.
- **Speed without chipmunks.** Play at 0.5×–2× with pitch-preserved, frame-accurate sound. Speed keeps the moment you picked, and Still shows the motion frame rate and estimated file size before you export.
- **Crop to any shape.** Choose a preset (1:1, 4:5, 9:16, …), a custom ratio, or freeform, and reposition with direct handles or exact pixel values.
- **What you see is what you save.** The preview, the Key Photo, and the export all render through one composition. The LIVE badge plays the actual result in the system Live Photo player.
- **HDR handled.** iPhone Dolby Vision, HLG, and HDR10 are converted to consistent SDR.
- **Mac-native.** It's built with SwiftUI, with:
  - one window per video, full undo and redo, and keyboard shortcuts for every edit;
  - drag and drop from Finder or Photos;
  - light and dark mode, and Liquid Glass on macOS 26.
- **Private by design.** Photos access is add-only and requested only when you save. Everything is processed on your Mac.

## Download

Download the latest DMG from [Releases](https://github.com/FacundoChan/Still/releases), open it, and drag **Still** to Applications. Releases are signed with Developer ID and notarized by Apple. Every CI run also attaches a build to its summary page.

## Using Still

1. **Open a video.** Drop it on the window, or choose **Open Video…** (⌘O) or **Choose from Photos…** (⇧⌘O).
2. **Find the moment.** Scrub the timeline, then click **Make Key Photo**.
3. **Shape it.** Drag the yellow brackets, pick a speed, or crop. Hover over **LIVE** to preview the real Live Photo.
4. **Save.** Click **Save to Photos** (⌘S) or **Export Files…** (⇧⌘E) for a matched JPEG and MOV.

### Keyboard shortcuts

| Key | Action |
|---|---|
| Space | Play or pause: the selection as it will export, or the source at 1× outside it |
| K or Return | Make Key Photo at the playhead |
| I / O | Trim the start / end to the playhead |
| ← / → (⇧ for 10) | Step one frame; in Crop mode, nudge the crop |
| C | Crop mode |
| L | Preview the Live Photo |
| ⌘S / ⇧⌘E | Save to Photos / Export Files… |
| ⌘. | Cancel an export |
| ⌘Z / ⇧⌘Z | Undo / Redo |

## How it works

A Live Photo is two files tied together by a shared UUID:

| | Key Photo | Paired video |
|---|---|---|
| Format | JPEG, sRGB | HEVC MOV at a constant 30 fps, with AAC sound |
| Identifier | Apple MakerNote key 17 | `com.apple.quicktime.content.identifier` |
| Timing | — | A timed metadata track, `com.apple.quicktime.still-image-time`, on the Key Photo's frame |

Still builds one AVFoundation composition from your edit: trim, speed, orientation, crop, and HDR-to-SDR conversion. Preview playback, the Key Photo, and the export all read from it, so they match by construction.

A single AVAssetReader → AVAssetWriter pass encodes the movie and captures the Key Photo from the exact frame it encodes. Sound is retimed offline with `AVAudioUnitTimePitch`, which keeps it within 5 ms of the picture; AVFoundation's built-in time-pitch lags up to 92 ms at speed-ups. Finally `PHAssetCreationRequest` saves the pair as one asset.

The details, measurements, and trade-offs are in the [decision log](docs/decisions.md). The full product specification is [goal.md](goal.md).

## Compatibility

- **Runs on** macOS 26 Tahoe or later, as a universal binary.
- **Tested on** macOS 27.0 on Apple silicon.
- **Opens** anything AVFoundation can decode, at any frame rate, including variable frame rate and 120 fps or more. That includes H.264, HEVC, ProRes, Dolby Vision, HLG, and HDR10, in MOV, MP4, and other movie containers.
- **Produces** Live Photos with HEVC video, which needs macOS 10.13 or iOS 11 or later to play.

See the [acceptance report](docs/acceptance.md) for exactly what has been verified, and what hasn't yet.

## Building from source

### Requirements

- macOS 26 or later with **Xcode 27.1** or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) and ffmpeg (for the test fixtures)

```bash
brew install xcodegen ffmpeg
```

### Build and run

```bash
git clone https://github.com/FacundoChan/Still.git
```

```bash
cd Still && xcodegen generate && open Still.xcodeproj
```

Choose the **Still** scheme and press ⌘R. `Still.xcodeproj` is generated from [`project.yml`](project.yml); edit the YAML, not the project.

The project signs with the maintainer's team. To build under your own Apple ID, set `DEVELOPMENT_TEAM` in `project.yml` to your team ID, or sign ad hoc from the command line:

```bash
xcodebuild -project Still.xcodeproj -scheme Still -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- build
```

### Package a release

```bash
Scripts/package.sh --dmg
```

This builds a universal Release copy, signs it, and writes a zip and a DMG to `build/dist/`. Add `--notarize` with `SIGN_IDENTITY="Developer ID Application"` and notarization credentials to produce a build anyone can open. The script's header lists the variables.

## Testing

The tests render real exports and measure them, so they need media. Generate the synthetic fixtures first:

```bash
Scripts/make-fixtures.sh
```

```bash
xcodebuild test -project Still.xcodeproj -scheme Still -destination 'platform=macOS' -derivedDataPath build/DerivedData
```

What the 55 tests cover:

- **Editing rules.** Speed, trimming, Make Key Photo, crop, size estimates, and every example in the specification.
- **Live Photo export.** Every fixture is exported, read back, and paired by Photos (`PHLivePhoto`), with a negative control.
- **Render correctness.** Export vs preview (40–55 dB PSNR), crop geometry, Key Photo fidelity, A/V sync, pitch, and mute.
- **Frame timing.** Frame-coded clips prove that every output frame shows the source frame the time model predicts.
- **Export recovery.** Cancellation cleans up within 300 ms, and delivery to a folder is all-or-nothing.

Clips recorded on the maintainer's iPhone add real-world cases when they're present in `Fixtures/real/`. They aren't committed, because they carry location metadata, and the tests skip them when they're missing. Outputs stay in `build/test-output/` for inspection.

<details>
<summary>Debug launch arguments</summary>

Debug builds accept these, for exercising failure paths by hand:

```bash
open build/DerivedData/Build/Products/Debug/Still.app --args -StillSimulateFailure diskFull -StillExportFrameDelay 0.04
```

- `-StillSimulateFailure photosDenied | photosFailed | diskFull | render` raises that failure during the next export.
- `-StillExportFrameDelay <seconds>` slows rendering, so there's time to press Cancel.
- `-StillAppearance dark | light` forces an appearance.

</details>

## Project structure

| Path | Contents |
|---|---|
| [`StillCore/`](StillCore) | Framework: editing model, render pipeline, Live Photo export and inspection, Photos saving |
| [`Still/App`](Still/App) | App entry, window routing, close and quit confirmation, temporary files |
| [`Still/Editor`](Still/Editor) | Per-window model: editing, undo, playback, background renders, export stages and recovery |
| [`Still/Views`](Still/Views) | Stage, crop overlay, timeline, inspector, drop target |
| [`Still/AppIcon.icon`](Still/AppIcon.icon) | App icon, an Icon Composer file with SVG layers |
| [`StillCoreTests/`](StillCoreTests) | Swift Testing suites |
| [`Scripts/`](Scripts) | Fixture generation and release packaging |
| [`docs/`](docs) | Decision log, acceptance report, manual test checklist |

## Continuous integration

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs on every push and pull request. On GitHub's Xcode 27.1 runner it:
1. generates the fixtures (cached);
2. runs the test suite;
3. packages a universal build, and uploads it as an artifact.

Tags named `v*` also create a draft release with the DMG.

Signing and notarization switch on when these repository secrets exist. Until then, builds are signed ad hoc:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | A *Developer ID Application* certificate with its private key, exported as .p12 and base64-encoded |
| `DEVELOPER_ID_P12_PASSWORD` | The password chosen when exporting the .p12 |
| `NOTARY_KEY_P8_BASE64` | An App Store Connect API key (.p8), base64-encoded |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the keys in App Store Connect |

## Roadmap

- Verify on macOS 26, on Intel, and with iPhone slow-motion (240 fps) footage
- A full VoiceOver audit
- HDR output: Live Photos that keep HDR, with a gain-map Key Photo and an HDR video
- Batch: several Live Photos from one video in a single pass

## Contributing

Issues and pull requests are welcome. Before a pull request:

- Run the test suite.
- Keep the code in the style of its surroundings. The project uses Swift 6 strict concurrency, SwiftUI with AppKit where it helps, and no third-party dependencies.
- Explain behavior changes against [goal.md](goal.md), the product contract.

Larger design decisions belong in [docs/decisions.md](docs/decisions.md).

## Acknowledgments

- [LivePhoto](https://github.com/LimitPoint/LivePhoto) by LimitPoint, an early reference for the Live Photo file format.
- Apple's [PHAssetCreationRequest](https://developer.apple.com/documentation/photos/phassetcreationrequest) and AVFoundation documentation.

## License

Still is released under the [MIT License](LICENSE).
