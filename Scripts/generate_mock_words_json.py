#!/usr/bin/env python3
"""Generate mock approximate words.json for timing pipeline checks."""

from pathlib import Path
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from alignment.approximate import write_words_json


def main() -> None:
    text = "Offline voiceover with word synced subtitles is coming together."
    output_path = Path("BuildArtifacts/mock_words.json")
    write_words_json(output_path, text=text, audio_duration=4.2)
    print(output_path)


if __name__ == "__main__":
    main()

