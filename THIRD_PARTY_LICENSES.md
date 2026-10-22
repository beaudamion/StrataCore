# Third-Party Notices & Licenses

Strata incorporates or interfaces with third-party open-source software as described below.

---

## FFmpeg & FFprobe

* **Project:** FFmpeg / FFprobe
* **Website:** [https://ffmpeg.org](https://ffmpeg.org)
* **Source Code:** [https://ffmpeg.org/download.html](https://ffmpeg.org/download.html)
* **License:** GNU Lesser General Public License (LGPL) version 2.1 or later / GNU General Public License (GPL) version 2.0 or later (depending on enabled codecs and build options).

### Architecture & Separation Notice
Strata interfaces with FFmpeg and FFprobe exclusively via independent process execution (`Foundation.Process`) using standard command-line flags and inter-process communication pipes. Strata's native Swift codebase is not linked against, nor does it share process memory with, the FFmpeg C library binaries.

In compliance with the LGPL/GPL:
1. FFmpeg is the intellectual property of the FFmpeg developers. Strata does not claim ownership of FFmpeg.
2. You can freely inspect, modify, and recompile FFmpeg from its official source code at:
   `https://git.ffmpeg.org/ffmpeg.git`
3. Users of Strata may swap or replace the FFmpeg and FFprobe executables at any time via **Strata > Settings > FFmpeg Engine & Binaries**, or by pointing Strata to custom builds or a system package manager (such as Homebrew).
