# Murmur

Push-to-talk dictation for macOS. Hold a key, talk, let go, and your words are pasted
wherever the cursor is. Transcription runs entirely on the Mac (Distil-Whisper Large v3
Turbo on the Neural Engine, via WhisperKit). Nothing is sent anywhere.

Rebuilt in October 2026 from the July "Bolt" version, with a Material 3 (Google-style)
interface set in Google Sans Flex.

## Using it

| Do this | To |
|---|---|
| Double-tap **⇧**, keep holding, talk, let go | Dictate. Text is pasted on release. |
| Triple-tap **⇧**, talk, tap **⇧** once | Dictate hands-free, as long as you like. |
| **esc** while recording | Throw the recording away. |
| Double-tap **⌃** and hold | Ask AI: say a request, the answer is pasted (Apple Intelligence). |
| Say "new line", "new paragraph" | Line breaks. "Scratch that" on its own discards. |

The shortcut key is configurable (Shift, Control, Option, Command). Murmur lives in the
menu bar; the window opens from there, or by opening the app again.

## Requirements

- Apple Silicon Mac, macOS 26 or newer
- Swift 6.2 toolchain (Xcode or the Command Line Tools) to build
- About 3 GB of disk: build cache plus the 1.4 GB model, downloaded on first launch

## Build and install

```bash
./scripts/build-app.sh --install
```

That builds `build/Murmur.app`, copies it to `/Applications` and launches it. Then, in the
Murmur window, allow the **Microphone** and **Accessibility** (Accessibility is what lets
it hear the shortcut in other apps and paste for you).

**Permissions after rebuilding.** Without a stable signing identity the app is ad-hoc
signed, and macOS treats every rebuild as a new app: Accessibility then shows as on but
doesn't work. Fix it by removing Murmur from System Settings › Privacy & Security ›
Accessibility and adding it again. To avoid this altogether, create a local signing
certificate once (Keychain Access › Certificate Assistant › Create a Certificate, name
`Murmur Local Signing`, type Code Signing); the build script uses it automatically.

## Checks

```bash
swift run murmur-check        # gesture state machine and text rules
```

Dev hooks, run against the debug binary (`swift build`):

```bash
# Transcribe a file with the real engine
MURMUR_SELFTEST=clip.wav .build/debug/Murmur
# Render every page (light and dark) and HUD state to PNGs for design review
MURMUR_RENDER=/tmp/murmur-render .build/debug/Murmur
```

## How it's put together

`Sources/MurmurCore` is pure logic with no dependencies, verified by `murmur-check`:

- `TapGesture.swift`: the double-tap-hold / triple-tap-lock state machine, with time
  injected. Recording starts on the second press so first words aren't clipped; a quick
  second tap keeps recording for 0.4 s in case a third tap (lock) follows, otherwise the
  audio is discarded. Any other key during a sequence resets it, so typing capitals with
  Shift can't trigger a recording.
- `TextTools.swift`: voice commands, corrections, smart spacing, Whisper clean-up.
- `SoundsLike.swift`: vocabulary. Distil-Whisper ignores prompt tokens (tested), so near-misses
  are corrected after transcription: same consonant skeleton and ≥70% similar spelling once
  sounds are normalised ("acupinol" → Acupanel, "Casero" → Kasaro, but not "kisser").

`Sources/Murmur` is the app:

| File | Does |
|---|---|
| `AppState.swift` | Coordinator: gesture → recorder → transcriber → insertion, HUD, menu bar |
| `KeyMonitor.swift` | Core Graphics event tap; swallows Esc only while recording |
| `AudioRecorder.swift` | 16 kHz capture, chunking at pauses (30–60 s), level meter, mic selection, survives device changes |
| `AudioDevices.swift` | Core Audio input list |
| `Transcriber.swift` | Model download with progress, Neural Engine load, warm-up |
| `TextInserter.swift` | Paste with full clipboard restore, typing fallback, Accessibility context |
| `HUD.swift` | The floating pill |
| `MainWindow.swift` | The window: Home, General, Dictation, Vocabulary, Ask AI |
| `Material.swift` | Design system: Material 3 colour tokens, Google Sans type scale, controls |
| `Services.swift` | Permissions, login item, sounds, history, vocabulary, Ask AI |

Design decisions kept from the original:

- Chunks of 30–60 s cut at a pause. Shorter chunks measurably hurt accuracy.
- Neural Engine compute (~2.5× faster than GPU for this model).
- No Metal in the HUD. The original's Metal orb leaked render work over long sessions.
  Animations here are SwiftUI `TimelineView`s that only exist while the pill is on screen.

Data lives in `~/Library/Application Support/Murmur/` (model, history, vocabulary).

## Fonts

Google Sans Flex is © The Google Sans Flex Authors, under the SIL Open Font License 1.1
(`assets/fonts/OFL.txt`), from [google/fonts](https://github.com/google/fonts/tree/main/ofl/googlesansflex).
