"""Advanced SubStation Alpha subtitle renderer with word highlighting."""

from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

from .colors import hex_to_ass_color
from .grouping import WordTiming, group_words


@dataclass(frozen=True)
class SubtitleStyle:
    font_name: str = "Helvetica"
    font_size: int = 54
    primary_color: str = "#FFFFFF"
    highlight_color: str = "#FFD84D"
    outline_color: str = "#000000"
    back_color: str = "#000000"
    margin_v: int = 58


def render_ass(
    words: Sequence[WordTiming] | Iterable[WordTiming],
    width: int = 1920,
    height: int = 1080,
    style: SubtitleStyle | None = None,
) -> str:
    """Render timed words into ASS subtitles using per-word karaoke tags."""
    style = style or SubtitleStyle()
    groups = group_words(words)
    events = "\n".join(_render_event(group) for group in groups)

    return "\n".join(
        [
            "[Script Info]",
            "ScriptType: v4.00+",
            "WrapStyle: 0",
            "ScaledBorderAndShadow: yes",
            f"PlayResX: {width}",
            f"PlayResY: {height}",
            "",
            "[V4+ Styles]",
            "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, "
            "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, "
            "Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
            "Style: Default,"
            f"{style.font_name},{style.font_size},"
            f"{hex_to_ass_color(style.primary_color)},"
            f"{hex_to_ass_color(style.highlight_color)},"
            f"{hex_to_ass_color(style.outline_color)},"
            f"{hex_to_ass_color(style.back_color)},"
            f"1,0,0,0,100,100,0,0,1,4,0,2,80,80,{style.margin_v},1",
            "",
            "[Events]",
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
            events,
            "",
        ]
    )


def write_ass(
    path: str | Path,
    words: Sequence[WordTiming] | Iterable[WordTiming],
    width: int = 1920,
    height: int = 1080,
    style: SubtitleStyle | None = None,
) -> Path:
    """Write an ASS subtitle file and return its path."""
    output_path = Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(render_ass(words, width=width, height=height, style=style), encoding="utf-8")
    return output_path


def _render_event(group: Sequence[WordTiming]) -> str:
    start = _format_ass_time(group[0].start)
    end = _format_ass_time(group[-1].end)
    text = "".join(_render_word(index, word) for index, word in enumerate(group))
    return f"Dialogue: 0,{start},{end},Default,,0,0,0,,{text}"


def _render_word(index: int, word: WordTiming) -> str:
    duration_cs = max(1, round((word.end - word.start) * 100))
    escaped = _escape_ass_text(word.word)
    prefix = " " if index > 0 else ""
    return f"{prefix}{{\\k{duration_cs}}}{escaped}"


def _format_ass_time(seconds: float) -> str:
    centiseconds = max(0, round(seconds * 100))
    hours = centiseconds // 360000
    centiseconds %= 360000
    minutes = centiseconds // 6000
    centiseconds %= 6000
    whole_seconds = centiseconds // 100
    centiseconds %= 100
    return f"{hours}:{minutes:02d}:{whole_seconds:02d}.{centiseconds:02d}"


def _escape_ass_text(text: str) -> str:
    return text.replace("\\", "\\\\").replace("{", "\\{").replace("}", "\\}")

