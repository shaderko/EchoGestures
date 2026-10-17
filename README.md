# EchoGestures

**Teach your Mac hand gestures using sound, then turn them into keyboard shortcuts.**

EchoGestures is a native macOS experiment in camera-free interaction. The built-in speakers emit near-ultrasonic sweeps; three microphone channels listen to the reflections. Two speakers × three microphones give six acoustic response paths. Show the app a pose or a short movement, teach a few examples, and assign a shortcut.

No camera, AirPods, external sensors, cloud service, or third-party packages are required.

> Research prototype. Recognition can work well for some gestures, but still misses movements and confuses others. It responds to acoustic patterns, including reflections from arms and bodies. Precise hand position, individual fingers, and reliable general-purpose gesture control are not established.

## What it does

- Learns your own **held poses** and **quick movements** through automatic, four-repetition lessons.
- Maps gestures to keys and modifiers, with optional separate shortcuts on entry and release.
- Learns **ignored movements**, such as shoulder shifts, as no-command examples.
- Previews guesses and rejection reasons before commands are enabled.
- Shows six echo plots, microphone-channel checks, timing diagnostics, and an experimental guided hand-workspace calibration.
- Runs locally, with menu-bar controls to pause commands or stop listening.

## Requirements

- macOS 14 or later and Xcode Command Line Tools with Swift 5.9 or later.
- Built-in stereo Mac speakers and three native microphone channels at matching input/output sample rates of 48 kHz or higher.
- Microphone permission to listen; Accessibility permission only to send shortcuts.

Three-channel capture was tested on a **14-inch M4 MacBook Pro (Mac16,1), running macOS 27.0.1**. Compatibility with other models and macOS versions is unverified. The bundled helper requests the array through public Core Audio APIs; capture stops if three channels are unavailable. Administrator access and driver modifications are not required.

## Build and run

Install Apple's developer tools if needed:

```sh
xcode-select --install
```

Then:

```sh
git clone https://github.com/shaderko/EchoGestures.git
cd EchoGestures
./build.sh
open build/EchoGestures.app
```

`build.sh` builds the Swift app and C microphone helper, creates the app bundle, and signs it. It uses an available Apple Development identity or falls back to ad-hoc signing. To select an identity explicitly, set `ECHOGESTURES_SIGN_IDENTITY`; set it to `-` for ad-hoc signing. The app is built locally; this repository does not provide a notarized installer.

You can open `Package.swift` in Xcode to edit the project. `swift build` checks the package executables, but use `build.sh` to create the app bundle with its helper and microphone permission description.

## Teach a gesture

1. Unmute the Mac's built-in speakers at a low, comfortable volume. The app does not change system volume or the device sample rate.
2. Add a gesture. Choose **Hold a pose** for a shape you keep still, or **Make a movement** for a quick action.
3. Click **Teach gesture** and allow microphone access. Keep your hand away while the initial background is measured, then follow the automatic rest / prepare / perform prompts. A lesson takes about 26 seconds after audio startup.
4. For movement lessons, make one quick motion per prompt, then settle. For pose lessons, hold the shape until the prompt ends.
5. Test in preview. If body movements cause false matches, use **Teach ignored movement** with your hand resting.
6. Assign a shortcut. To send it, enable EchoGestures in **System Settings → Privacy & Security → Accessibility**, enable commands in the app, and switch to the application you want to control.

Commands start paused on every launch. Teaching, binding changes, and array inspection also pause them. A movement triggers after its completed sequence is verified; a pose needs stable evidence. Repeating the same gesture requires release, and there is an 800 ms command cooldown.

For held actions, enable **Run another shortcut on exit**. Entry runs once, and release sends the exit shortcut to the same application that received entry. Two toggle keys do not inspect or guarantee playback state. Closing the main window keeps the menu-bar app running; **Quit EchoGestures** stops capture.

## Understand the preview

A nearly full bar means strong model evidence against background, **not trigger confidence or an accuracy percentage**. Competing gestures, proximity to taught examples, the movement sequence, and the command gate still need to pass.

- **Closest echo**: a pattern resembles a movement; no verified completed movement is available.
- **Last movement**: the latest completed candidate's decision, including rejection for another gesture or an ignored example.
- **Posted to…**: macOS received the keyboard event request. The target application's focus and shortcut handling determine the resulting action.

Under **Signal diagnostics**, **Save diagnostics** saves signal timing and the most recent 360 recognition decisions locally. **Inspect microphone array** shows all six response paths and can run automatic hand/shoulder comparisons or marked-workspace lessons. These are diagnostic experiments; workspace guesses do not control shortcuts or establish microphone capsule coordinates.

## How it works

Sequential 512-sample sweeps span 20.2–22.8 kHz within a 4096-sample period. At 48 kHz, that gives about 11.7 observations per second; left/right probes are sequential, not simultaneous.

Matched filters estimate each speaker-to-microphone response. A frozen background is subtracted, then six response blocks become 402 echo features. A class-balanced ridge model uses recent shape and signed temporal changes to compare rest, ignored movement, poses, and movements. Recorded-example support and dynamic time warping verify movement candidates before a separate command lifecycle dispatches keys.

The array inspector additionally preserves shared-reference complex profiles and constrains receiver timing offsets. The experimental workspace map uses separate teaching and check rounds. Position repeatability remains weak; it is not a precise 3D tracker.

See [architecture](Docs/Architecture.md), [held commands](Docs/HeldCommands.md), and [validation](Docs/Validation.md) for implementation details and limits.

## Privacy and local data

The app implements no networking. Raw microphone audio is processed transiently and is not saved. Learned numeric echo features, gesture names, shortcut bindings, lesson archives, and diagnostic measurements stay under:

```text
~/Library/Application Support/EchoGestures/
```

Deleting a gesture retains a recoverable archive; completed and partial lessons are archived independently. This repository contains source and synthetic tests, with no personal gesture recordings, calibration captures, diagnostic sessions, or pre-trained user model.

## Tests and source layout

```sh
./test.sh
swift build --configuration debug
```

Core tests run without microphone or Accessibility permission. They cover DSP, automatic lessons, gesture learning, sequence checks, event lifecycles, capture freshness, and persistence. Passing them does not establish physical recognition accuracy.

| Folder | Purpose |
|---|---|
| `Sources/Audio` | Core Audio capture, playback, and helper lifecycle |
| `Sources/DSP` | Matched filtering, timing, background, and array measurements |
| `Sources/Gestures` | Lessons, features, classifier, sequence matching, and lifecycle |
| `Sources/Commands` | Keys, modifiers, target tracking, and dispatch |
| `Sources/Storage` | Validated local library and archives |
| `Sources/App`, `Sources/UI` | App orchestration and native interface |
| `Native` | Input-only microphone-array requester |
| `Tests` | Synthetic core checks |

## Known limitations

Hardware support is narrow and unverified beyond the development Mac. Room reflections, display angle, hand orientation, arm position, and background changes affect the signal. Multiple gestures can overlap; quick movements may be missed by the burst detector. Held-out recorded examples still show misses, and false triggers remain possible. More examples do not guarantee better discrimination.

Start with distinct gestures, test them in preview, and treat this as an acoustic interaction experiment rather than a replacement for a mouse or trackpad.
