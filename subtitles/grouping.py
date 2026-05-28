"""Word grouping for readable karaoke subtitle events."""

from dataclasses import dataclass
from typing import Iterable, Sequence


@dataclass(frozen=True)
class WordTiming:
    word: str
    start: float
    end: float


def group_words(
    words: Sequence[WordTiming] | Iterable[WordTiming],
    max_words: int = 6,
    max_chars: int = 42,
    max_duration: float = 3.5,
) -> list[list[WordTiming]]:
    """Group timed words into short subtitle lines."""
    if max_words < 1:
        raise ValueError("max_words must be at least 1")
    if max_chars < 1:
        raise ValueError("max_chars must be at least 1")
    if max_duration <= 0:
        raise ValueError("max_duration must be positive")

    groups: list[list[WordTiming]] = []
    current: list[WordTiming] = []

    for word in words:
        if not word.word.strip():
            continue

        candidate = [*current, word]
        candidate_text = " ".join(item.word for item in candidate)
        candidate_duration = candidate[-1].end - candidate[0].start

        if current and (
            len(candidate) > max_words
            or len(candidate_text) > max_chars
            or candidate_duration > max_duration
        ):
            groups.append(current)
            current = [word]
        else:
            current = candidate

    if current:
        groups.append(current)

    return groups

