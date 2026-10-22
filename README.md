# Strata

A native macOS GUI and engine for remuxing media, managing tracks, and extracting audio/subtitle streams using FFmpeg. Built with Swift and SwiftUI for Apple Silicon.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B%20Sonoma%20%2F%20Sequoia-black?style=flat-square&logo=apple)
![Apple Silicon](https://img.shields.io/badge/Architecture-Apple%20Silicon%20(arm64)-orange?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-5.10%2B%20%2F%20Swift%206-F05138?style=flat-square&logo=swift)
![FFmpeg](https://img.shields.io/badge/Engine-FFmpeg%20%26%20FFprobe-007808?style=flat-square&logo=ffmpeg)
![License](https://img.shields.io/badge/License-Source--Available%20%2F%20Freeware-purple?style=flat-square)

---

## Overview

**StrataCore** is the core media processing and remuxing engine powering **Strata**.

This public repository serves two purposes:
1. **Engine Source**: Hosts the core engine source code (`RemuxEngine`, `ProbePipeline`, `FFmpegLocator`, `BatchEngine`, and stream models) for inspection, auditing, and building.
2. **Release Distribution**: Provides pre-compiled application releases of **Strata.app** for macOS Apple Silicon under [Releases](https://github.com/beaudamion/StrataCore/releases).

All media probing, remuxing, and transcoding operations run 100% locally on-device. The engine contains no network code, telemetry, or remote dependencies.

---

## Supported Formats

Strata handles the primary media containers and codecs supported by FFmpeg:

- **Containers**: MKV, MP4, MOV, M4V, WebM (input support also includes AVI, TS, M2TS, FLV, OGG)
- **Video Codecs**: Passthrough for H.264, HEVC, Apple ProRes, AV1, VP9, VP8, and others; hardware encoding for H.264, HEVC, and ProRes via VideoToolbox
- **Audio Codecs**: Passthrough and extraction for AAC, AC-3, E-AC-3, DTS, TrueHD, FLAC, ALAC, Opus, MP3, and PCM (WAV, AIFF); transcoding to AAC, ALAC, FLAC, Opus, MP3, and uncompressed PCM
- **Subtitles**: SRT, ASS/SSA, WebVTT, mov_text, PGS, and VobSub

---

## Features

### Lossless Remuxing
- **Direct Stream Copy**: Repackage containers (MKV, MP4, MOV, WebM) without re-encoding video streams (`-c copy`).
- **MP4 Subtitle Handling**: Converts text subtitles to `mov_text` when targeting MP4/M4V containers.
- **FastStart & Metadata**: Relocates the `moov` atom to the start of MP4 files for streaming (`+faststart`) and strips global metadata (`-map_metadata -1`).

### Audio & Stream Extraction
- **Audio Transcoding**: Convert audio streams to AAC, ALAC, FLAC, Opus, MP3, or uncompressed PCM (WAV/AIFF). Configure bitrates, sample rates (44.1 kHz to 192 kHz), and channel layouts (Mono, Stereo, 5.1).
- **Stem Extraction**: Export individual audio or subtitle tracks directly to standalone files without remuxing the full container.
- **Custom Output Naming**: Name exports with pattern tokens (`{filename}`, `{title}`, `{lang}`, `{codec}`, `{channels}`) with real-time path previews.

### Multi-Track Multiplexing
- **Import External Tracks**: Add external audio commentary, dubs, subtitles, or secondary video tracks into an existing file.
- **Container Validation**: Enforces single-video stream constraints for MP4 containers while allowing multi-video tracks in MKV.

### VideoToolbox Encoding
- **Hardware Acceleration**: Re-encode video using Apple Silicon VideoToolbox encoders (H.264, HEVC, and ProRes) when passthrough is not suitable.
- **Stream Passthrough**: Video tracks default to stream copy to avoid unnecessary re-encoding or quality loss.

### Batch Processing
- **Queue System**: Process multiple files sequentially with progress reporting (percentage, speed multiplier, elapsed time, ETA).
- **Single-to-Queue**: Configure stream selections and audio options in single mode and dispatch them to the batch queue.
- **Queue Presets**: Apply batch-wide container rules, audio conversion strategies, and subtitle filtering.

### Engine Options
- **Bundled Binaries**: Includes self-contained arm64 FFmpeg and FFprobe binaries.
- **Homebrew & Custom Paths**: Option to use system FFmpeg from `/opt/homebrew` or a custom path, with an in-app check and updater for Homebrew installations.

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
