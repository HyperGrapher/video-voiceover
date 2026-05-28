#!/usr/bin/env python3
"""Generate a mock ASS subtitle file for manual FFmpeg rendering checks."""

from pathlib import Path
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from alignment.approximate import approximate_word_timings
from subtitles.ass_renderer import write_ass
from subtitles.grouping import WordTiming


def main() -> None:
    text = "Offline voiceover with word synced subtitles is coming together."
    words = [
        WordTiming(word=timing.word, start=timing.start, end=timing.end)
        for timing in approximate_word_timings(text, audio_duration=4.2)
    ]
    output_path = Path("BuildArtifacts/mock_word_subtitles.ass")
    write_ass(output_path, words)
    print(output_path)


if __name__ == "__main__":
    main()
