"""FFmpeg command runner for burned-in subtitle exports."""

from dataclasses import dataclass
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid


class FFmpegError(RuntimeError):
    def __init__(self, message: str, stderr: str = ""):
        super().__init__(message)
        self.stderr = stderr


@dataclass(frozen=True)
class FFmpegTools:
    ffmpeg: str = "ffmpeg"
    ffprobe: str = "ffprobe"


@dataclass(frozen=True)
class ExportResult:
    output_path: Path
    work_dir: Path
    ffmpeg_log: str


def require_ffmpeg(tools: FFmpegTools | None = None) -> FFmpegTools:
    """Return usable FFmpeg tool paths or raise a descriptive error."""
    tools = tools or FFmpegTools()
    ffmpeg_path = shutil.which(tools.ffmpeg) or _local_tool_path(tools.ffmpeg)
    ffprobe_path = shutil.which(tools.ffprobe) or _local_tool_path(tools.ffprobe)

    missing = []
    if ffmpeg_path is None:
        missing.append("ffmpeg")
    if ffprobe_path is None:
        missing.append("ffprobe")
    if missing:
        raise FFmpegError(f"Missing required tool(s): {', '.join(missing)}")

    return FFmpegTools(ffmpeg=ffmpeg_path, ffprobe=ffprobe_path)


def check_libass_support(tools: FFmpegTools | None = None) -> str:
    """Verify the available FFmpeg binary exposes the ass subtitle filter."""
    resolved_tools = require_ffmpeg(tools)
    result = subprocess.run(
        [resolved_tools.ffmpeg, "-hide_banner", "-filters"],
        capture_output=True,
        text=True,
        check=False,
    )
    output = f"{result.stdout}\n{result.stderr}"
    if result.returncode != 0:
        raise FFmpegError("Could not inspect FFmpeg filters", output)
    if " ass " not in output and " ass" not in output:
        raise FFmpegError("FFmpeg was found, but the ass subtitle filter/libass support was not detected", output)
    return output


def create_export_work_dir(root: str | Path | None = None) -> Path:
    """Create a safe temporary export job directory."""
    base = Path(root) if root is not None else Path(tempfile.gettempdir()) / "speechapp-exports"
    work_dir = base / f"export-{uuid.uuid4()}"
    work_dir.mkdir(parents=True, exist_ok=False)
    return work_dir


def export_video_with_subtitles(
    input_video: str | Path,
    narration_audio: str | Path,
    subtitles_ass: str | Path,
    output_path: str | Path,
    tools: FFmpegTools | None = None,
) -> ExportResult:
    """Replace input audio with narration and burn ASS subtitles into final MP4."""
    resolved_tools = require_ffmpeg(tools)
    input_video = Path(input_video)
    narration_audio = Path(narration_audio)
    subtitles_ass = Path(subtitles_ass)
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    command = [
        resolved_tools.ffmpeg,
        "-y",
        "-hide_banner",
        "-i",
        str(input_video),
        "-i",
        str(narration_audio),
        "-vf",
        f"ass={_escape_filter_path(subtitles_ass)}",
        "-map",
        "0:v:0",
        "-map",
        "1:a:0",
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "18",
        "-c:a",
        "aac",
        "-shortest",
        str(output_path),
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    log = f"{result.stdout}\n{result.stderr}"
    if result.returncode != 0:
        raise FFmpegError("FFmpeg export failed", log)

    return ExportResult(
        output_path=output_path,
        work_dir=output_path.parent,
        ffmpeg_log=log,
    )


def _local_tool_path(tool_name: str) -> str | None:
    repo_root = Path(__file__).resolve().parents[1]
    candidates = [
        repo_root / "Sources" / "speechapp" / "Resources" / tool_name,
        repo_root / tool_name,
    ]
    for candidate in candidates:
        if candidate.exists() and candidate.is_file():
            return str(candidate)
    return None


def _escape_filter_path(path: Path) -> str:
    text = str(path.resolve())
    return text.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")

