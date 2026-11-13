# Strata

An Apple Silicon-native media workstation for lossless remuxing, hardware encoding, and track mastering on macOS. Built with Swift, SwiftUI, and AppKit.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B%20Sonoma%20%2F%20Sequoia-black?style=flat-square&logo=apple)
![Apple Silicon](https://img.shields.io/badge/Architecture-Apple%20Silicon%20(arm64)-FF9500?style=flat-square)
![Hardware Accel](https://img.shields.io/badge/Hardware%20Accel-Apple%20VideoToolbox-0071e3?style=flat-square&logo=apple)
![UI](https://img.shields.io/badge/UI-SwiftUI%20%26%20AppKit-0A84FF?style=flat-square&logo=swift)
![Swift](https://img.shields.io/badge/Swift-5.10%2B%20%2F%20Swift%206-F05138?style=flat-square&logo=swift)
![Engine](https://img.shields.io/badge/Engine-FFmpeg%20%26%20FFprobe-007808?style=flat-square&logo=ffmpeg)
![Codecs](https://img.shields.io/badge/Codecs-ProRes%20%C2%B7%20AV1%20%C2%B7%20HEVC-5856D6?style=flat-square)
![Audio](https://img.shields.io/badge/Audio-EBU%20R128%20Loudness-BF5AF2?style=flat-square)
![Updates](https://img.shields.io/badge/Updates-Sparkle%202%20(EdDSA)-30B0C7?style=flat-square)
![License](https://img.shields.io/badge/License-Source--Available%20%2F%20Freeware-AF52DE?style=flat-square)

---

## Overview

**StrataCore** is the core media processing engine powering **Strata**, an Apple Silicon-native media workstation for lossless remuxing, hardware encoding, and track mastering on macOS.

This public repository serves two purposes:
1. **Engine Source**: Hosts the core Swift media processing engine (`RemuxEngine`, `ExecutionPlanner`, `NativeVideoToolboxEngine`, `PerceptualQCRunner`, `ProbePipeline`, `HardwareCapabilities`, `FFmpegLocator`, `BatchEngine`, and stream models) for inspection, auditing, and building.
2. **Release Distribution**: Provides pre-compiled application releases of **Strata.app** for macOS Apple Silicon under [Releases](https://github.com/beaudamion/StrataCore/releases).

All media probing, remuxing, and transcoding operations run 100% locally on-device. The engine contains no network code, telemetry, or remote dependencies.

---

## Supported Formats

Strata handles the primary media containers and codecs supported by FFmpeg:

- **Containers**: MP4, MKV, MOV, M4V, WebM with per-codec compatibility checks and one-click container switching (input inspection also supports AVI, TS, M2TS, FLV, OGG)
- **Video Codecs**: Passthrough for H.264, HEVC (with automatic `hev1` → `hvc1` Apple compatibility tagging), Apple ProRes, AV1, VP9, VP8, and others; VideoToolbox hardware encoding for H.264, HEVC (8/10-bit, alpha, 4:2:2), and Apple ProRes (`Automatic`, Proxy through 4444 XQ) with automatic software fallback; plus **AV1** (SVT-AV1, 8/10-bit) and **Uncompressed 4:2:2** (8/10-bit)
- **Audio Codecs**: Passthrough and extraction for AAC, AC-3, E-AC-3, DTS, TrueHD, FLAC, ALAC, Opus, MP3, and PCM; encoding to **AAC** (True VBR / CBR / ABR / CVBR), **AC3**, **E-AC3 (Dolby Digital+)**, **ALAC**, **FLAC**, **Opus**, **MP3 (LAME)**, **WAV**, and **AIFF** (up to 32-bit PCM / float)
- **Subtitles**: SRT, ASS/SSA, WebVTT, `mov_text`, PGS, and VobSub

---

## Features

### Lossless Remuxing & Track Control
- **Direct Stream Copy**: Repackage containers (MP4, MKV, MOV, M4V, WebM) without re-encoding video streams (`-c copy`), using dynamic `.remuxed` and `.encoded` output suffixes.
- **Multi-Track Multiplexing**: Reorder tracks via drag-and-drop, disable unwanted streams, and import external audio, subtitle, or secondary video tracks with instant compatibility banners and one-click container switching.
- **MP4 Web & Metadata Controls**: Relocate the `moov` header (`+faststart`), strip global metadata or chapters, and convert text subtitles to `mov_text` when targeting MP4/M4V.

### Hardware Acceleration, AV1 & Pro Encoding
- **VideoToolbox & Native 2-Pass VBR**: Accelerate decoding and H.264, HEVC, and Apple ProRes encoding via macOS VideoToolbox — including native 2-pass hardware VBR for MP4/M4V/MOV and automatic software fallback (`x264`, `x265`, `prores_ks`) when profiles or settings require it.
- **Segmented Parallel Exports**: Detect physical Apple Silicon Media Engines and active VideoToolbox sessions via IOKit, splitting eligible single-file exports at keyframe boundaries across idle hardware engines while keeping audio sample-accurate.
- **AV1 & Uncompressed Workflows**: Encode software **AV1** (`libsvtav1` speed presets `2–8`, 8/10-bit, Constant Quality or Average Bitrate) for MP4, M4V, MKV, and WebM, or output broadcast-grade **Uncompressed 4:2:2** (10-bit `v210` / 8-bit `2vuy`) to MOV and MKV.
- **Automatic Defaults & Full Video Controls**: Options default to **Automatic** to match your source untouched unless customized (with one-click reset). Configure quality presets (`Compact` to `Master`), bitrate limits, frame rate, color space (Rec. 709 / 601 / Rec. 2020 HLG & PQ), aspect-preserving resize (`720p`–`4K`), rotation/flip, deinterlacing, B-frames, keyframe interval, alpha preservation, and Dolby Vision RPU protection warnings.

### Audio Encoding, Loudness & Stem Extraction
- **Non-Destructive Audio Conversion**: Encode to AAC, AC3, E-AC3 (Dolby Digital+), ALAC, FLAC, Opus, MP3 (LAME), WAV, or AIFF. Channels, sample rates (up to 192 kHz), 24/32-bit lossless depths, and adaptive or source-matched bitrates default to **Automatic**, with full manual control when needed.
- **2-Pass Loudness Normalization**: Built-in EBU R128 loudness leveling for Streaming (`-14 LUFS`), Apple/Podcast (`-16 LUFS`), and Broadcast (`-23 LUFS`).
- **Standalone Track Extraction & Pattern Naming**: Export individual video, audio, or subtitle streams directly, or format filenames with tokens (`{filename}`, `{title}`, `{lang}`, `{codec}`, `{index}`, `{channels}`) and live previews.

### Media Inspector, Quality Check & Native macOS UI
- **Stream Telemetry Inspector**: View container, chapter, bitrate, color, HDR10/HLG, mastering display, and Dolby Vision metadata for loaded files with one-click spec copying.
- **Post-Export Quality Check**: Optionally score finished video exports against the original file using **XPSNR** or **VMAF**.
- **Liquid Glass Interface & Plain-English Mode**: Built with macOS vibrancy, Liquid Glass refraction controls, toggleable hover tooltips, and approachable **Plain-English** descriptions by default (with a **Technical Engine & CLI Details** toggle in Settings → Appearance).

### Batch Queue & Automation
- **Queue Processing**: Convert or remux multiple files sequentially with live per-item progress, speed multiplier, elapsed time, and ETA.
- **Single-to-Queue & Presets**: Configure custom track layouts in Single mode and push them into the queue, or apply batch-wide container, audio, metadata, FastStart, and subtitle presets.

### Flexible Engine Setup
- **Bundled, Homebrew, or Custom Binaries**: Ships with self-contained arm64 FFmpeg and FFprobe binaries for macOS 14+ (verified automatically on launch), or switches to Homebrew/custom paths with built-in FFmpeg installation and update controls.

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
