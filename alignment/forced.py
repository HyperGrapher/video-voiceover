"""Optional Whisper word-timestamp alignment backend."""

import re
from difflib import SequenceMatcher

from .approximate import approximate_word_timings, tokenize_words
from .base import TimedWord


WORD_NORMALIZER = re.compile(r"[\W_]+", re.UNICODE)


class ForcedWordAligner:
    def __init__(self, model_name: str = "tiny.en"):
        try:
            import whisper_timestamped as whisper
        except Exception as exc:
            raise RuntimeError(
                "Forced alignment requires whisper-timestamped. "
                "Install requirements and repackage the backend."
            ) from exc

        self.whisper = whisper
        self.model = whisper.load_model(model_name)

    def align(self, transcript: str, audio_duration: float, audio_path: str | None = None) -> list[TimedWord]:
        if audio_path is None:
            raise ValueError("audio_path is required for forced alignment")

        result = self.whisper.transcribe(
            self.model,
            audio_path,
            language="en",
            vad=False,
            beam_size=1,
            best_of=1,
        )
        detected_words = [
            word
            for segment in result.get("segments", [])
            for word in segment.get("words", [])
            if word.get("text")
        ]
        return merge_detected_words_with_transcript(transcript, audio_duration, detected_words)


def merge_detected_words_with_transcript(
    transcript: str,
    audio_duration: float,
    detected_words: list[dict],
) -> list[TimedWord]:
    transcript_tokens = tokenize_words(transcript)
    if not transcript_tokens:
        return []
    if not detected_words:
        return approximate_word_timings(transcript, audio_duration)

    approximate = approximate_word_timings(transcript, audio_duration)
    detected_tokens = [_normalize(word.get("text", "")) for word in detected_words]
    transcript_normalized = [_normalize(token) for token in transcript_tokens]
    timings_by_index: dict[int, TimedWord] = {}

    matcher = SequenceMatcher(a=transcript_normalized, b=detected_tokens, autojunk=False)
    for opcode, transcript_start, transcript_end, detected_start, detected_end in matcher.get_opcodes():
        if opcode not in {"equal", "replace"}:
            continue

        transcript_range = range(transcript_start, transcript_end)
        detected_range = range(detected_start, detected_end)
        for transcript_index, detected_index in zip(transcript_range, detected_range):
            detected = detected_words[detected_index]
            start = float(detected.get("start", approximate[transcript_index].start))
            end = float(detected.get("end", approximate[transcript_index].end))
            if end <= start:
                end = approximate[transcript_index].end

            timings_by_index[transcript_index] = TimedWord(
                index=transcript_index,
                word=transcript_tokens[transcript_index],
                start=round(max(0.0, start), 4),
                end=round(min(audio_duration, end), 4),
                confidence=float(detected.get("confidence", 0.82) or 0.82),
            )

    merged = []
    for index, fallback in enumerate(approximate):
        merged.append(timings_by_index.get(index, fallback))

    return _smooth_missing_timings(merged, audio_duration)


def _smooth_missing_timings(words: list[TimedWord], audio_duration: float) -> list[TimedWord]:
    smoothed = []
    previous_end = 0.0

    for index, word in enumerate(words):
        start = max(previous_end, word.start)
        end = max(start + 0.01, word.end)
        if index == len(words) - 1:
            end = min(max(end, start + 0.01), audio_duration)
        smoothed.append(TimedWord(
            index=word.index,
            word=word.word,
            start=round(start, 4),
            end=round(min(end, audio_duration), 4),
            confidence=word.confidence,
        ))
        previous_end = smoothed[-1].end

    return smoothed


def _normalize(word: str) -> str:
    return WORD_NORMALIZER.sub("", word).lower()

