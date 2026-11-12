# Strata

An Apple Silicon-native media workstation for lossless remuxing, hardware encoding, and track mastering on macOS. Built with Swift, SwiftUI, and AppKit.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B%20Sonoma%20%2F%20Sequoia-black?style=flat-square&logo=apple)
![Apple Silicon](https://img.shields.io/badge/Architecture-Apple%20Silicon%20(arm64)-orange?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-5.10%2B%20%2F%20Swift%206-F05138?style=flat-square&logo=swift)
![FFmpeg](https://img.shields.io/badge/Engine-FFmpeg%20%26%20FFprobe-007808?style=flat-square&logo=ffmpeg)
![License](https://img.shields.io/badge/License-Source--Available%20%2F%20Freeware-purple?style=flat-square)

---

## Overview

**StrataCore** is the core media processing engine powering **Strata**, an Apple Silicon-native media workstation for lossless remuxing, hardware encoding, and track mastering on macOS.

This public repository serves two purposes:
1. **Engine Source**: Hosts the core Swift media processing engine (`RemuxEngine`, `ProbePipeline`, `FFmpegLocator`, `BatchEngine`, and stream models) for inspection, auditing, and building.
2. **Release Distribution**: Provides pre-compiled application releases of **Strata.app** for macOS Apple Silicon under [Releases](https://github.com/beaudamion/StrataCore/releases).

All media probing, remuxing, and transcoding operations run 100% locally on-device. The engine contains no network code, telemetry, or remote dependencies.

---

## Supported Formats

Strata handles the primary media containers and codecs supported by FFmpeg:

- **Containers**: MP4, MKV, MOV, M4V, WebM (input inspection also supports AVI, TS, M2TS, FLV, OGG)
- **Video Codecs**: Passthrough for H.264, HEVC, Apple ProRes, AV1, VP9, VP8, and others; VideoToolbox hardware encoding for H.264, HEVC (8/10-bit, alpha, 4:2:2), and Apple ProRes (Proxy through 4444 XQ) with automatic software fallback
- **Audio Codecs**: Passthrough and extraction for AAC, AC-3, E-AC-3, DTS, TrueHD, FLAC, ALAC, Opus, MP3, and PCM; encoding to AAC (Stereo / 5.1), ALAC, FLAC, Opus, MP3, AC-3, E-AC-3, WAV, and AIFF
- **Subtitles**: SRT, ASS/SSA, WebVTT, `mov_text`, PGS, and VobSub

---

## Features

### Lossless Remuxing & Track Control
- **Direct Stream Copy**: Repackage containers (MP4, MKV, MOV, M4V, WebM) without re-encoding video streams (`-c copy`).
- **Multi-Track Multiplexing**: Reorder tracks via drag-and-drop, disable unwanted streams, and import external audio, subtitle, or secondary video tracks with per-container validation.
- **MP4 Web & Metadata Controls**: Relocate the `moov` header (`+faststart`), strip global metadata or chapters, and convert text subtitles to `mov_text` when targeting MP4/M4V.

### VideoToolbox & Segmented Parallel Encoding
- **Hardware Acceleration**: Accelerate decoding and H.264, HEVC, and Apple ProRes encoding via macOS VideoToolbox, with automatic software fallback when profiles or hardware limits require it.
- **Segmented Parallel Exports**: Detect physical Apple Silicon Media Engines and active VideoToolbox sessions via IOKit, splitting eligible single-file exports at keyframe boundaries across idle hardware engines while keeping audio sample-accurate.
- **Per-Track Video Controls**: Configure bitrate, frame rate, color space (Rec. 709 / Rec. 601 / Rec. 2020 HLG & PQ), field order, profile, B-frame reordering, keyframe interval, alpha preservation, and 2-pass VBR (`x264` / `x265`).

### Audio Encoding & Stem Extraction
- **Audio Conversion**: Encode tracks to AAC, ALAC, FLAC, Opus, MP3, AC-3, E-AC-3, WAV, or AIFF with selectable bitrate, sample rate (up to 192 kHz), bit depth, and channel layouts.
- **Standalone Track Extraction**: Export individual video, audio, or subtitle streams without remuxing the full container.
- **Pattern Naming**: Format extracted filenames with tokens (`{filename}`, `{title}`, `{lang}`, `{codec}`, `{index}`, `{channels}`) and live previews.

### Media Inspector & Native macOS UI
- **Stream Telemetry Inspector**: View detailed container, chapter, bitrate, color, HDR, and codec metadata for loaded files with one-click spec copying.
- **Liquid Glass Interface**: Built with macOS vibrancy, hardware-backed Liquid Glass refraction controls, instant drag-and-drop overlays, and contextual hover tooltips.

### Batch Queue & Automation
- **Queue Processing**: Convert or remux multiple files sequentially with live per-item progress, speed multiplier, elapsed time, and ETA.
- **Single-to-Queue & Presets**: Configure custom track layouts in Single mode and push them into the queue, or apply batch-wide container, audio, metadata, FastStart, and subtitle presets.

### Flexible Engine Setup
- **Bundled, Homebrew, or Custom Binaries**: Ships with embedded arm64 FFmpeg and FFprobe binaries, or switches to Homebrew/custom paths with built-in FFmpeg installation and update controls.

---

## Installation

Pre-compiled releases for Apple Silicon are available on GitHub:

1. Download the latest `.dmg` from [Releases](https://github.com/beaudamion/StrataCore/releases).
2. Drag **Strata.app** into `/Applications`.
3. Launch Strata.

---

## System Requirements

- **Operating System**: macOS 14.0 (Sonoma) or macOS 15.0+ (Sequoia)
- **Architecture**: Apple Silicon Mac (arm64)
- **FFmpeg**: Bundled binaries are included; external Homebrew or custom binaries are optional

---

## License & Terms

Strata is source-available software:

- **Personal Use**: Core remuxing and single-file processing features are free for personal, non-commercial use.
- **Pro & Commercial**: Advanced features (Audio & Video Transcoding and Batch Processing) and commercial workflows require a license.
- **Source Code**: Core media engine source code is available in the [StrataCore](https://github.com/beaudamion/StrataCore) repository for personal inspection, security review, and testing. Derivative applications or competing commercial redistributions are not permitted without prior written permission. See [`LICENSE`](LICENSE) for terms.

### Third-Party Notices

Strata executes external FFmpeg and FFprobe binaries via command-line subprocesses. FFmpeg is licensed independently under the GNU LGPL v2.1+ / GPL v2.0+. See [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md) for details and source links.
