# QuietNeighbor

Per-app volume mixer for Mac — quiet the loud neighbor without touching the rest.

QuietNeighbor is a native SwiftUI menu bar app. Each slider is **relative gain** versus the current system output, so the Mac’s volume keys still act as the master. Example: YouTube (browser) at 50%, Discord at 100%, speakers still follow the system volume.

## Requirements

- **macOS 14.2 or later** (Apple Silicon or Intel). Process taps (`AudioHardwareCreateProcessTap` / `CATapDescription`) shipped in 14.2.
- Xcode 16 or later to build (14.2 SDK or newer).
- Audio capture / microphone permission when macOS prompts.
- **Not App Store sandboxed.** Core Audio process taps are unreliable inside the App Store sandbox. Ship a Developer ID signed, notarized build instead.

This repository was authored so the Xcode project is complete and CI-compilable. **Live audio cannot be verified on a Linux cloud VM** — open the project on a Mac to confirm taps, permissions, and playback.

## Install and run

1. Clone this repo on a Mac and open `QuietNeighbor.xcodeproj`.
2. Select the **QuietNeighbor** scheme and your Apple Development team (Signing & Capabilities).
3. Build and run (⌘R). QuietNeighbor is a menu bar extra (`LSUIElement`) — look for the slider icon in the menu bar, not the Dock. The mixer starts at launch so saved levels apply before you open the menu.
4. Click the icon. The mixer lists apps that are producing audio, or recently did.
5. When you first move a slider or mute an app, macOS asks for **audio capture** (sometimes labeled Microphone). Allow it. Without that permission, the list still works but gain cannot be applied. Saved non-100% / mute levels restore on the next launch once capture is allowed.
6. **Mute** is a 36×36 toggle (not a tiny glyph). Accessibility Inspector should see `quietNeighbor.mute.<bundle-id>` with label Mute/Unmute and value Muted/Unmuted. Toggling writes `isMuted` to `UserDefaults` (`quietNeighbor.volumeByApp`) and starts the existing process tap at gain 0 so only that app is silenced.
7. Optional: QuietNeighbor → Settings (gear) → **Open at login**.

The menu-bar extra uses the system slider symbol. The **App Icon** is the yellow bird shush already on `main` (`QuietNeighbor/Assets.xcassets/AppIcon.appiconset`).

Command-line build:

```bash
xcodebuild \
  -project QuietNeighbor.xcodeproj \
  -scheme QuietNeighbor \
  -destination 'platform=macOS' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  build
```

## How it works

macOS has no public `setAppVolume` API. QuietNeighbor uses the modern HAL path:

1. **Discover** audio clients with `kAudioHardwarePropertyProcessObjectList` and `kAudioProcessPropertyIsRunningOutput`. Helper / GPU / WebKit processes are grouped under the owning app (bundle id) so Chrome or Safari appear as one row.
2. **List** those apps in the menu bar mixer, with icon, name, 0–100% slider, and a 36×36 mute toggle (`quietNeighbor.mute.<bundle-id>`).
3. **Intercept only when needed.** At 100% and unmuted, the app plays normally. If you lower the slider or mute, QuietNeighbor:
   - creates a private `CATapDescription` mixdown of that app’s process objects
   - sets `muteBehavior = .mutedWhenTapped` so the original hardware path is silenced (no double audio)
   - wraps the tap plus the default output in a **private aggregate device**
   - runs an `AudioDeviceIOProc` that copies tap samples to the output with the chosen gain
4. **System volume stays master** because playback goes through the current default output device.
5. **Persist** volume and mute in `UserDefaults`, keyed by bundle identifier (or a stable executable-path fallback).

Orphaned aggregates from a previous crash (`com.lonnylot.QuietNeighbor.agg.*`) are destroyed on launch.

## Permissions and entitlements

| Need | Why |
| --- | --- |
| `NSAudioCaptureUsageDescription` | Apple’s required disclosure for Core Audio taps |
| `NSMicrophoneUsageDescription` | Same TCC prompt is often labeled Microphone |
| `com.apple.security.device.audio-input` / `microphone` | Hardened Runtime audio capture |
| **No App Sandbox** | Taps on other processes fail or are incomplete when sandboxed |

QuietNeighbor does **not** ask for Accessibility or Screen Recording. If a tap fails, the row shows the Core Audio error; use **Open Privacy Settings** in the mixer or Settings pane.

For distribution: sign with Developer ID Application, enable Hardened Runtime (already on), notarize, and staple. Do not enable App Sandbox for an App Store build unless Apple later documents a sandboxed tap entitlement that actually works.

## Known limitations

- **Browsers share a process.** YouTube, another tab, and often picture-in-picture share Chrome / Safari / Arc. One slider covers that process tree.
- **Some apps never appear.** Protected, DRM, or exclusive-mode clients may not publish a process object, or a tap may be refused.
- **First adjustment can glitch.** Creating the muted tap and aggregate takes a moment; you may hear a short dropout.
- **Bluetooth HFP.** Aggregates that include the output device can stall if AirPods jump to a 16/24 kHz call mode. Disconnect the call or pick another output, then refresh.
- **Recently played, not “has an audio session.”** `IsRunningOutput` can stay true briefly after pause. Rows stay for about 10 minutes after last playback.
- **Unsigned CI binaries** compile, but real taps usually need a signed local or Developer ID build.
- **Live audio was not verified in this Linux environment.** Confirm on a Mac with two apps playing (for example Music + a browser).

## Project layout

```
QuietNeighbor.xcodeproj          Shared QuietNeighbor scheme (used by CI)
QuietNeighbor/
  QuietNeighborApp.swift         Menu bar extra + Settings
  MixerController.swift          UI state, persistence, tap lifecycle
  Audio/                         Process monitor, tap + aggregate + IOProc
  Persistence/VolumeStore.swift  Bundle-id keyed UserDefaults
  UI/                            Mixer popover, mute toggle, settings
  QuietNeighbor.entitlements     Audio capture; sandbox off
```

## CI

`.github/workflows/ci.yml` runs `xcodebuild` build + `QuietNeighborTests` on `macos-latest` for the QuietNeighbor scheme with signing disabled. The old “skip if no Xcode project” path is gone — the project is required. Tests cover `VolumePreference` / `VolumeStore` persistence (including mute-only), `TapGain` relative gain, and mute AX identifier strings. Live mute still needs a Mac.

## License

Private repository. All rights reserved unless a license file is added later.
