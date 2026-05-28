"""Fast offline approximate word timing generation."""

import json
import re
from pathlib import Path

from .base import TimedWord


WORD_PATTERN = re.compile(r"\S+", re.UNICODE)
SAMPLE_RATE = 24_000


def tokenize_words(text: str) -> list[str]:
    """Split on whitespace while preserving punctuation attached to displayed words."""
    return WORD_PATTERN.findall(text)


def approximate_word_timings(text: str, audio_duration: float) -> list[TimedWord]:
    """Distribute an audio duration over words using character-length weights."""
    words = tokenize_words(text)
    if not words:
        return []
    if audio_duration <= 0:
        raise ValueError("audio_duration must be positive")

    weights = [max(1, len(word.strip())) for word in words]
    total_weight = sum(weights)
    current = 0.0
    timings: list[TimedWord] = []

    for index, word in enumerate(words):
        if index == len(words) - 1:
            end = audio_duration
        else:
            word_duration = audio_duration * weights[index] / total_weight
            end = min(audio_duration, current + word_duration)

        timings.append(
            TimedWord(
                index=index,
                word=word,
                start=round(current, 4),
                end=round(end, 4),
                confidence=0.4,
            )
        )
        current = end

    return timings


def build_words_document(
    text: str,
    audio_duration: float,
    sample_rate: int = SAMPLE_RATE,
) -> dict:
    """Build the canonical words.json document described in the PRD."""
    timings = approximate_word_timings(text, audio_duration)
    return {
        "text": text,
        "sampleRate": sample_rate,
        "duration": audio_duration,
        "words": [timing.to_dict() for timing in timings],
    }


def write_words_json(
    path: str | Path,
    text: str,
    audio_duration: float,
    sample_rate: int = SAMPLE_RATE,
) -> Path:
    """Write canonical approximate word timings as JSON."""
    output_path = Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    document = build_words_document(text, audio_duration, sample_rate)
    output_path.write_text(json.dumps(document, indent=2, ensure_ascii=False), encoding="utf-8")
    return output_path


class ApproximateWordAligner:
    def align(self, transcript: str, audio_duration: float, audio_path: str | None = None) -> list[TimedWord]:
        return approximate_word_timings(transcript, audio_duration)
