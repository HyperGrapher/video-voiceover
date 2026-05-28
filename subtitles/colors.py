"""Color conversion helpers for Advanced SubStation Alpha subtitles."""

import re


HEX_COLOR_PATTERN = re.compile(r"^#?([0-9a-fA-F]{6})$")


def hex_to_ass_color(hex_color: str) -> str:
    """Convert #RRGGBB to opaque ASS &H00BBGGRR color format."""
    match = HEX_COLOR_PATTERN.match(hex_color.strip())
    if not match:
        raise ValueError(f"Invalid hex color: {hex_color!r}")

    value = match.group(1)
    red = value[0:2]
    green = value[2:4]
    blue = value[4:6]
    return f"&H00{blue}{green}{red}".upper()
