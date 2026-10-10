# Instant

Live speech translation for macOS and iOS — hear a language, read it in yours. Starting with Japanese → Traditional Chinese, on-device with Apple's SpeechAnalyzer and Translation frameworks.

## Layout

```
App/                    SwiftUI app (one multiplatform target: macOS + iOS)
Packages/InstantCore/   Pipeline: Audio → Transcription → Session (segmentation) → Translation
  Sources/instant-lab/  CLI that plays audio files through the pipeline for end-to-end runs
project.yml             XcodeGen spec for Instant.xcodeproj
script/e2e.sh           End-to-end runs on real speech, with a report
```

## Speakers

Instant tells speakers apart with [FluidAudio](https://github.com/FluidInference/FluidAudio)'s streaming Sortformer (up to 4 speakers, ~1s behind the audio), running on CPU+GPU next to recognition. Each caption is attributed to whoever spoke most during it; right-click a speaker label to name them (giving two labels the same name merges them). The model (~240 MB, [NVIDIA Open Model License](https://developer.nvidia.com/open-model-license)) downloads on first use; turn speakers off in the toolbar to skip it.

## Develop

Requirements: Xcode 27, macOS 26+, an Apple ID signed in under Xcode › Settings › Accounts.

```bash
open Instant.xcodeproj      # pick "My Mac" or an iPhone, then ⌘R
```

After editing `project.yml`, regenerate the project with [XcodeGen](https://github.com/yonaskolb/XcodeGen): `xcodegen generate`.

Signing uses the Personal Team in `project.yml` (`DEVELOPMENT_TEAM`); change it to your own team ID if you fork. With a stable Apple Development signature macOS remembers microphone and screen-recording permission across builds.

## Test end-to-end

```bash
./script/e2e.sh             # all samples
./script/e2e.sh podcast     # one sample
```

Plays real Japanese speech through the full pipeline at real-time speed and prints latency, segmentation, translation and speaker stats plus every caption line. Each run leaves a trace in `/tmp/instant-e2e-*.jsonl`. Speaker accuracy on the podcast is scored against reference turns from FluidAudio's offline diarizer (`instant-lab reference`), generated on first run.

## Trace

Every pipeline stage records events (`audio.*`, `asr.*`, `seg.update`, `mt.*`, `session.*`) to the unified log (subsystem `io.github.chyyynh.instant`) and, when `INSTANT_TRACE=<file>` is set, to that file as JSON lines. Summarize one with:

```bash
Packages/InstantCore/.build/out/Products/Debug/instant-lab report <trace.jsonl>
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).
