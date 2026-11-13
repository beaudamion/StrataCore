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

**StrataCore** is the media processing engine powering **Strata**, a native macOS media workstation for lossless remuxing, hardware encoding, and track mastering on Apple Silicon.

This public repository serves two purposes:
1. **Engine Source**: Hosts the Swift media engine source code for transparency, privacy verification, and security auditing.
2. **Release Distribution**: Official compiled downloads of **Strata.app** for macOS under [Releases](https://github.com/beaudamion/StrataCore/releases).

All processing runs 100% on-device with zero telemetry and no remote dependencies.

---

## Supported Formats

Strata handles the most popular media formats and pro codecs:

- **Containers**: MP4, MKV, MOV, M4V, WebM (inspection also supports AVI, TS, M2TS, FLV, OGG)
- **Video**: H.264, HEVC / H.265 (8/10-bit, 4:2:2, alpha), Apple ProRes (Proxy through 4444 XQ), AV1 (SVT-AV1), VP9, and Uncompressed 4:2:2 (`v210` / `2vuy`)
- **Audio**: AAC, AC3, E-AC3 (Dolby Digital+), ALAC, FLAC, Opus, MP3, WAV, AIFF, TrueHD, and DTS
- **Subtitles**: SRT, ASS/SSA, WebVTT, `mov_text`, PGS, and VobSub

---

## Features

### Lossless Remuxing & Track Control
- **Instant Stream Copy**: Change containers (e.g. MKV to MP4) in seconds without re-compressing video or losing visual quality.
- **Track Management**: Drag and drop to reorder tracks, turn off unneeded streams, or add external video, audio, and subtitle files.
- **Web & Apple Device Optimization**: Turn on Web FastStart for instant browser playback, strip unnecessary metadata, and format subtitles for Apple devices.

### Apple Silicon Hardware Encoding & Pro Video
- **Hardware Acceleration**: Take full advantage of Apple Silicon Media Engines for fast H.264, HEVC, and ProRes encoding, with native 2-pass quality controls and automatic CPU fallback when needed.
- **Multi-Engine Parallel Exports**: Automatically splits and processes exports across multiple hardware encoding engines on Apple Silicon Pro, Max, and Ultra chips for faster export performance while audio stays perfectly sample-accurate.
- **Modern AV1 & Archival Video**: High-efficiency software AV1 encoding (8/10-bit) for streaming, plus broadcast-grade 10-bit Uncompressed 4:2:2 output for archival workflows.
- **Automatic Defaults with Full Control**: All settings default to **Automatic** to preserve your original file untouched unless you choose to customize. When you want to make adjustments, you have full control over quality presets, frame rates, color spaces (Rec. 709, Rec. 2020, HDR10, HLG), resolution scaling, rotation, and deinterlacing.

### Audio Transcoding & Loudness Mastering
- **Smart Audio Conversion**: Transcode audio tracks to AAC, AC3, Dolby Digital+, ALAC, FLAC, Opus, MP3, WAV, or AIFF. Bitrates, channels, and sample rates (up to 192 kHz) default to **Automatic** to mirror your original sound.
- **EBU R128 Loudness Normalization**: Level your audio with industry-standard targets for Streaming (`-14 LUFS`), Apple / Podcast (`-16 LUFS`), and Broadcast (`-23 LUFS`).
- **Individual Track Extraction**: Quickly export isolated video, dialogue, music stems, or subtitle tracks directly to their own standalone files.

### Media Inspector & Native macOS Design
- **Detailed File Inspector**: Inspect codecs, bitrates, color profiles, HDR10/HLG metadata, mastering display info, and Dolby Vision layers in one click.
- **Visual Quality Verification**: Optionally compare exported files against the original with industry-standard **XPSNR** or **VMAF** quality scoring.
- **Native Frosted Glass UI**: Designed for modern macOS (Sonoma+) with native dark vibrancy, Liquid Glass accents, and clear Plain-English descriptions (with an optional Technical Details mode for power users).

### Batch Processing & Automation
- **Queue Processing**: Convert, remux, or extract multiple media files in sequence with live speed, progress, and time estimates.
- **Batch Presets**: Apply container, audio, and metadata settings across dozens of files at once.

### Zero-Setup Portability
- **Self-Contained**: Ships with embedded media engines ready to go—no terminal commands, Homebrew, or external tools required. Power users can also link custom FFmpeg installations in Settings.

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
