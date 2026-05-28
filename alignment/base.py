"""Shared word alignment interface and timing schema."""

from dataclasses import asdict, dataclass
from typing import Protocol


@dataclass(frozen=True)
class TimedWord:
    index: int
    word: str
    start: float
    end: float
    confidence: float

    def to_dict(self) -> dict:
        return asdict(self)


class WordAligner(Protocol):
    def align(self, transcript: str, audio_duration: float) -> list[TimedWord]:
        """Return word-level timings for transcript over audio_duration seconds."""

