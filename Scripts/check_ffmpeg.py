#!/usr/bin/env python3
"""Check local FFmpeg availability and ASS subtitle filter support."""

from pathlib import Path
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from video.ffmpeg_runner import check_libass_support, require_ffmpeg


def main() -> None:
    tools = require_ffmpeg()
    check_libass_support(tools)
    print(f"ffmpeg={tools.ffmpeg}")
    print(f"ffprobe={tools.ffprobe}")
    print("libass=available")


if __name__ == "__main__":
    main()

