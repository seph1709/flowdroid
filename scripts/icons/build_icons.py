"""Builds FlowDroid's icon font from the hand-drawn glyphs below.

Every glyph is drawn on a 24-unit grid with a 1.6 stroke, round caps and
joins, and the "port dot" (a small filled circle, like a node's connection
point on the canvas) where the glyph has a focal point.

    python scripts/icons/build_icons.py            # writes the font and lib/ui/icons.dart
    python scripts/icons/build_icons.py --preview out.png

Needs: fonttools, picosvg, skia-pathops (and cairosvg for --preview).
"""

from __future__ import annotations

import argparse
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
FONT = ROOT / "app/assets/fonts/FlowIcons.ttf"
DART = ROOT / "app/lib/ui/icons.dart"
FAMILY = "FlowIcons"
FIRST_CODEPOINT = 0xE000

S = 1.6  # stroke width


def dot(x: float, y: float, r: float = 1.5) -> str:
    return f'<circle class="f" cx="{x}" cy="{y}" r="{r}"/>'


def p(d: str) -> str:
    return f'<path d="{d}"/>'


def c(x: float, y: float, r: float) -> str:
    return f'<circle cx="{x}" cy="{y}" r="{r}"/>'


def rect(x: float, y: float, w: float, h: float, rx: float) -> str:
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}"/>'


def frect(x: float, y: float, w: float, h: float, rx: float) -> str:
    return f'<rect class="f" x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}"/>'


def fp(d: str) -> str:
    return f'<path class="f" d="{d}"/>'


BELL = "M5 18h14l-1.5-1.8V11a5.5 5.5 0 0 0-11 0v5.2z"
MAIL = "M3.5 8a3 3 0 0 1 3-3h11a3 3 0 0 1 3 3v8a3 3 0 0 1-3 3h-11a3 3 0 0 1-3-3z"
CLIP = rect(5, 5, 14, 16, 3) + rect(9, 3, 6, 4, 1.5)
BUBBLE = "M4 7a3 3 0 0 1 3-3h10a3 3 0 0 1 3 3v7a3 3 0 0 1-3 3h-6l-4.5 3.5V17A3 3 0 0 1 4 14z"
CIRCLE = c(12, 12, 8.5)

# name: (description, svg body)
ICONS: dict[str, tuple[str, str]] = {
    # ---- interface ----
    "add": ("Plus", p("M12 5v14M5 12h14")),
    "addStep": ("Add a step", rect(4, 4, 16, 16, 4.5) + p("M12 8.5v7M8.5 12h7")),
    "back": ("Back", p("M19 12H5M11 6l-6 6 6 6")),
    "forward": ("Forward", p("M5 12h14M13 6l6 6-6 6")),
    "up": ("Up", p("M12 19V5M6 11l6-6 6 6")),
    "chevronRight": ("Chevron right", p("M9.5 6l6 6-6 6")),
    "chevronDown": ("Chevron down", p("M6 9.5l6 6 6-6")),
    "close": ("Close", p("M6.5 6.5l11 11M17.5 6.5l-11 11")),
    "copy": ("Copy", rect(8, 8, 12, 12, 3) + p("M16 8V6.5A2.5 2.5 0 0 0 13.5 4h-7A2.5 2.5 0 0 0 4 6.5v7A2.5 2.5 0 0 0 6.5 16H8")),
    "paste": ("Paste", CLIP + p("M9 12h6M9 16h4")),
    "pasteIn": ("Read clipboard", CLIP + p("M12 10.5v6.5M9 14l3 3 3-3")),
    "insert": ("Insert", p("M4 12h10M10 8l4 4-4 4M18.5 5v14")),
    "braces": (
        "Braces",
        p("M8.5 4.5C6.5 4.5 6 5.5 6 7v2.5C6 10.7 5.2 12 4 12c1.2 0 2 1.3 2 2.5V17c0 1.5.5 2.5 2.5 2.5")
        + p("M15.5 4.5c2 0 2.5 1 2.5 2.5v2.5c0 1.2.8 2.5 2 2.5-1.2 0-2 1.3-2 2.5V17c0 1.5-.5 2.5-2.5 2.5")
        + dot(12, 12, 1.4),
    ),
    "code": ("Code", p("M8.5 7.5L4 12l4.5 4.5M15.5 7.5L20 12l-4.5 4.5M13.5 5.5l-3 13")),
    "delete": (
        "Delete",
        p("M4.5 6.5h15M9.5 6.5V5A1.5 1.5 0 0 1 11 3.5h2A1.5 1.5 0 0 1 14.5 5v1.5")
        + p("M6.5 6.5l.8 11.6a2.5 2.5 0 0 0 2.5 2.4h4.4a2.5 2.5 0 0 0 2.5-2.4l.8-11.6M10.3 10.5v6M13.7 10.5v6"),
    ),
    "edit": ("Edit", p("M4.5 19.5l1-4L15.8 5.2a2 2 0 0 1 2.8 0l.2.2a2 2 0 0 1 0 2.8L8.5 18.5zM13.5 7.5l3 3")),
    "more": ("More", dot(5.5, 12, 1.6) + dot(12, 12, 1.6) + dot(18.5, 12, 1.6)),
    "search": ("Search", c(10.5, 10.5, 6) + p("M15 15l5 5")),
    "tune": ("Settings", p("M4 8h9M17 8h3M4 16h3M11 16h9") + c(15, 8, 2) + c(9, 16, 2)),
    "undo": ("Undo", p("M9 6.5l-4 4 4 4M5 10.5h9.5a4.5 4.5 0 0 1 0 9H11")),
    "redo": ("Redo", p("M15 6.5l4 4-4 4M19 10.5H9.5a4.5 4.5 0 0 0 0 9H13")),
    "history": ("History", p("M4.5 12a7.5 7.5 0 1 0 2.2-5.3M4.5 4v3.5H8M12 8.5V12l2.5 2")),
    "restore": ("Restore", p("M19.5 12a7.5 7.5 0 1 1-2.2-5.3M19.5 4v3.5H16") + dot(12, 12, 1.6)),
    "fit": (
        "Fit to screen",
        p("M4 9V6.5A2.5 2.5 0 0 1 6.5 4H9M15 4h2.5A2.5 2.5 0 0 1 20 6.5V9M20 15v2.5a2.5 2.5 0 0 1-2.5 2.5H15M9 20H6.5A2.5 2.5 0 0 1 4 17.5V15")
        + dot(12, 12, 1.7),
    ),
    "expand": ("Open full screen", p("M14 4h6v6M20 4l-6 6M10 20H4v-6M4 20l6-6")),
    "fold": ("Fold", p("M8 4.5l4 3.5 4-3.5M8 19.5l4-3.5 4 3.5M5 12h14")),
    "unfold": ("Unfold", p("M8 8l4-3.5L16 8M8 16l4 3.5 4-3.5M5 12h14")),
    "play": ("Run", fp("M8 5.6v12.8a1.2 1.2 0 0 0 1.8 1l10-6.4a1.2 1.2 0 0 0 0-2L9.8 4.6A1.2 1.2 0 0 0 8 5.6z")),
    "playCircle": ("Enable", CIRCLE + p("M10.3 9.2v5.6l4.4-2.8z")),
    "pauseCircle": ("Disable", CIRCLE + p("M10 9.5v5M14 9.5v5")),
    "check": ("Done", p("M5 12.5l4.5 4.5L19 7.5")),
    "checkCircle": ("Succeeded", CIRCLE + p("M8.5 12.2l2.4 2.4 4.6-4.8")),
    "error": ("Error", CIRCLE + p("M12 7.5V13") + dot(12, 16.2, 1.1)),
    "warning": ("Warning", p("M10.3 4.4L3.4 16.6a2 2 0 0 0 1.7 2.9h13.8a2 2 0 0 0 1.7-2.9L13.7 4.4a2 2 0 0 0-3.4 0zM12 9.5v4") + dot(12, 16.3, 1.05)),
    "download": ("Download", p("M12 4v11M7.5 10.5L12 15l4.5-4.5M5 19.5h14")),
    "saveFile": ("Save to a file", p("M12 4v10M8 10l4 4 4-4M4.5 15v2.5a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2V15")),
    "share": ("Share", p("M12 14V4M8 7.5l4-4 4 4M8.5 10.5h-2a2 2 0 0 0-2 2v5a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2v-5a2 2 0 0 0-2-2h-2")),
    "link": ("Link", p("M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1")),
    "unlink": ("Disconnect", p("M15.5 12.5L18 10a3.5 3.5 0 0 0-5-5l-2.5 2.5M8.5 11.5L6 14a3.5 3.5 0 0 0 5 5l2.5-2.5M4.5 4.5l15 15")),
    "eye": ("Show", p("M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z") + c(12, 12, 3)),
    "eyeOff": (
        "Hide",
        p("M4 4l16 16M9.9 5.8A9.6 9.6 0 0 1 12 5.5c6 0 9.5 6.5 9.5 6.5a16 16 0 0 1-2.6 3.4")
        + p("M6.6 7.4C4 9.1 2.5 12 2.5 12S6 18.5 12 18.5c1.7 0 3.2-.5 4.5-1.2M9.9 9.9a3 3 0 0 0 4.2 4.2"),
    ),
    "key": ("Credential", c(8, 15.5, 4) + p("M10.9 12.6L19 4.5M16 7.5l2.5 2.5M13.8 9.7l1.8 1.8")),
    "pin": ("Pin", p("M9 4.5h6M10 4.5v5L7 13h10l-3-3.5v-5M12 13v6.5")),
    "external": ("Open link", p("M13.5 4.5h6v6M19.5 4.5L11 13M17.5 14v3.5a2 2 0 0 1-2 2h-9a2 2 0 0 1-2-2v-9a2 2 0 0 1 2-2H10")),
    "sort": ("Sort", p("M4 7h9M4 12h6.5M4 17h4M17.5 5v14M14.5 16l3 3 3-3")),
    "filter": ("Filter", p("M4.5 5.5h15l-5.8 7v5.3l-3.4 1.7v-7z")),
    "terminal": ("Terminal", rect(3.5, 5, 17, 14, 3) + p("M7.5 10l2.5 2.5L7.5 15M12.5 15.5h4")),
    "phone": ("Phone", rect(6.5, 3, 11, 18, 2.8) + p("M10.5 18h3")),
    "server": ("Ubuntu", rect(4, 4.5, 16, 6.5, 2) + rect(4, 13, 16, 6.5, 2) + dot(7.5, 7.75, 1) + dot(7.5, 16.25, 1) + p("M11.5 7.75h5M11.5 16.25h5")),
    "connect": ("Connect", c(6, 6, 2.5) + dot(18, 18, 2.4) + p("M8.5 6H15a3 3 0 0 1 3 3v6")),
    "node": ("Step", rect(4.5, 6.5, 11, 11, 3) + p("M15.5 12h2.5") + dot(19.5, 12, 1.6)),
    "sweep": ("Clear", p("M4 7h11M4 12h8M4 17h5M14.5 14.5l5 5M19.5 14.5l-5 5")),
    "curl": ("Import cURL", rect(3.5, 5, 17, 14, 3) + p("M7 12h5.5M10 9.5l2.5 2.5-2.5 2.5") + dot(16.2, 12, 1.4)),
    "format": ("Format", p("M4 5.5h16M10 10h10M10 14h10M4 18.5h16M4 9.5L6.5 12 4 14.5")),
    "result": ("Result", p("M6 5v6.5a3 3 0 0 0 3 3h10M15.5 11l3.5 3.5-3.5 3.5")),
    "moon": ("Quiet", p("M19.5 14.5a7.5 7.5 0 0 1-10-10 7.5 7.5 0 1 0 10 10z")),
    "variable": ("Variables", p("M8 4.5C6 4.5 5.5 6 5.5 8v1.5c0 1.5-1 2.5-2 2.5 1 0 2 1 2 2.5V16c0 2 .5 3.5 2.5 3.5M16 4.5c2 0 2.5 1.5 2.5 3.5v1.5c0 1.5 1 2.5 2 2.5-1 0-2 1-2 2.5V16c0 2-.5 3.5-2.5 3.5M9.5 9.5l5 5M14.5 9.5l-5 5")),
    "workflow": ("Workflow", rect(3.5, 4, 7, 6, 2) + rect(13.5, 14, 7, 6, 2) + p("M7 10v4a3 3 0 0 0 3 3h3.5") + dot(17, 7, 1.6) + p("M10.5 7h4.9")),
    "keyboard": ("Keyboard", rect(2.5, 6, 19, 12.5, 3) + dot(6.5, 10, 1) + dot(10, 10, 1) + dot(13.5, 10, 1) + dot(17.5, 10, 1) + dot(6.5, 13.5, 1) + dot(17.5, 13.5, 1) + p("M9.5 14.5h5")),
    "keyboardHide": ("Hide keyboard", rect(2.5, 3.5, 19, 11, 3) + dot(6.5, 7.5, 1) + dot(10, 7.5, 1) + dot(13.5, 7.5, 1) + dot(17.5, 7.5, 1) + p("M9.5 11h5M9 18l3 3 3-3")),
    # ---- node types ----
    "tap": ("Manual", dot(12, 12.5, 2.6) + p("M7.4 17.1a6.5 6.5 0 1 1 9.2 0M4.6 19.9a10.5 10.5 0 1 1 14.8 0")),
    "clock": ("Schedule", CIRCLE + p("M12 7.5V12l3 2") + dot(12, 12, 1.3)),
    "webhook": ("Webhook", c(12, 6.5, 2.5) + c(6.5, 17, 2.5) + dot(17.5, 17, 2.5) + p("M10.8 8.7l-3 6.1M13.2 8.7l3 6.1M9 17h6")),
    "send": ("Send", p("M20 4L3.5 10.5l6.5 2.5 2.5 6.5zM20 4l-10 9")),
    "branch": ("If", p("M12 20v-6M12 14L6.5 7M12 14l5.5-7") + dot(5.8, 6, 1.9) + c(18.2, 6, 1.9)),
    "route": ("Switch", p("M12 20v-5M12 15L5.8 8.5M12 15V6.5M12 15l6.2-6.5") + dot(5, 7.5, 1.6) + dot(12, 4.6, 1.6) + dot(19, 7.5, 1.6)),
    "merge": ("Merge", p("M5.5 4.5L12 12.5v5.3M18.5 4.5L12 12.5") + dot(12, 19.6, 1.9)),
    "noop": ("No Op", c(12, 12, 7.5) + p("M9 15l6-6")),
    "hourglass": ("Wait", p("M7 4h10M7 20h10M8 4v2.5a4 4 0 0 0 1.6 3.2L12 12l2.4-2.3A4 4 0 0 0 16 6.5V4M8 20v-2.5a4 4 0 0 1 1.6-3.2L12 12l2.4 2.3a4 4 0 0 1 1.6 3.2V20")),
    "reply": ("Respond", p("M10 6l-5.5 5.5L10 17M4.5 11.5H14a5.5 5.5 0 0 1 5.5 5.5v1.5")),
    "fields": ("Edit Fields", p("M4.5 7h9M4.5 12h6M4.5 17h4.5M13 19.5l.6-2.6 5.2-5.2a1.4 1.4 0 0 1 2 2l-5.2 5.2z")),
    "split": ("Split Out", p("M9 12h10.5M9 12c3 0 3-5.5 6-5.5h4.5M9 12c3 0 3 5.5 6 5.5h4.5M7 12H5.5") + dot(4.5, 12, 1.7)),
    "gather": ("Aggregate", p("M15 12H4.5M15 12c-3 0-3-5.5-6-5.5H4.5M15 12c-3 0-3 5.5-6 5.5H4.5M17 12h1.5") + dot(19.5, 12, 1.7)),
    "dedupe": ("Remove Duplicates", p("M15 9V6.5A2.5 2.5 0 0 0 12.5 4h-6A2.5 2.5 0 0 0 4 6.5v6A2.5 2.5 0 0 0 6.5 15H9") + rect(9, 9, 11, 11, 2.5) + p("M12 14.5l2 2 3.2-3.3")),
    "limit": ("Limit", p("M4.5 5h15M12 19.5V9M8 13l4-4 4 4")),
    "globe": ("HTTP", CIRCLE + p("M3.5 12h17M12 3.5C9.5 5.8 8.5 8.7 8.5 12s1 6.2 3.5 8.5M12 3.5c2.5 2.3 3.5 5.2 3.5 8.5s-1 6.2-3.5 8.5")),
    "bell": ("Notification", p(BELL) + dot(12, 20.6, 1.4)),
    "bellDot": ("Notification trigger", p(BELL) + dot(12, 20.6, 1.4) + dot(18.3, 5.7, 2.3)),
    "speak": ("Speak", p("M4.5 9.5v5h3l4.5 4v-13l-4.5 4zM15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11")),
    "vibrate": ("Vibrate", rect(8, 4, 8, 16, 2.2) + p("M4.8 8.5v7M19.2 8.5v7M2.5 10.5v3M21.5 10.5v3")),
    "battery": ("Battery", rect(3.5, 7.5, 15, 9, 2.5) + p("M21 10.5v3") + frect(6, 10, 7, 4, 1)),
    "batteryCharging": ("Charging", rect(3.5, 7.5, 15, 9, 2.5) + p("M21 10.5v3M11.8 9.3l-2.3 2.9h3l-2.3 2.9")),
    "locate": ("Location", c(12, 12, 6.5) + p("M12 2.8v3M12 18.2v3M2.8 12h3M18.2 12h3") + dot(12, 12, 2)),
    "place": ("Place", p("M12 20.5s-6.5-5.6-6.5-10.5a6.5 6.5 0 0 1 13 0c0 4.9-6.5 10.5-6.5 10.5z") + dot(12, 10, 2.2)),
    "sparkle": (
        "AI",
        p("M11 3.5c.6 4.3 2.2 5.9 6.5 6.5-4.3.6-5.9 2.2-6.5 6.5-.6-4.3-2.2-5.9-6.5-6.5 4.3-.6 5.9-2.2 6.5-6.5z")
        + fp("M18 14.2c.35 1.9.9 2.45 2.8 2.8-1.9.35-2.45.9-2.8 2.8-.35-1.9-.9-2.45-2.8-2.8 1.9-.35 2.45-.9 2.8-2.8z"),
    ),
    "agent": ("AI Agent", rect(5, 8, 14, 11, 3.5) + p("M12 8V5.6M3 12.5V15M21 12.5V15") + dot(12, 4.5, 1.4) + dot(9.5, 13.5, 1.25) + dot(14.5, 13.5, 1.25)),
    "chat": (
        "Chat",
        p("M4 6.5A2.5 2.5 0 0 1 6.5 4h7A2.5 2.5 0 0 1 16 6.5v4a2.5 2.5 0 0 1-2.5 2.5h-4l-3 2.5V13A2.5 2.5 0 0 1 4 10.5z")
        + p("M19 9.6a2.4 2.4 0 0 1 1 1.9v4a2.5 2.5 0 0 1-2.5 2.5V20l-3-2h-3a2.5 2.5 0 0 1-2-1"),
    ),
    "message": ("SMS", p(BUBBLE) + dot(8.5, 10.5, 1) + dot(12, 10.5, 1) + dot(15.5, 10.5, 1)),
    "database": ("Database", p("M5 6.5c0-1.7 3.1-3 7-3s7 1.3 7 3-3.1 3-7 3-7-1.3-7-3zM5 6.5v11c0 1.7 3.1 3 7 3s7-1.3 7-3v-11M5 12c0 1.7 3.1 3 7 3s7-1.3 7-3")),
    "table": ("Table", rect(4, 5, 16, 14, 2.5) + p("M4 10h16M10 10v9")),
    "document": ("Document", p("M14 3.5H7.5A2.5 2.5 0 0 0 5 6v12a2.5 2.5 0 0 0 2.5 2.5h9A2.5 2.5 0 0 0 19 18V8.5zM14 3.5v5h5M8.5 13h7M8.5 16.5H13")),
    "rows": ("Phone Table", rect(4, 4, 16, 4.2, 2) + rect(4, 9.9, 16, 4.2, 2) + rect(4, 15.8, 16, 4.2, 2)),
    "sheet": ("Sheets", rect(4.5, 3.5, 15, 17, 2.5) + p("M4.5 9h15M4.5 14.5h15M10 9v11.5")),
    "mail": ("Email", p(MAIL + "M4.5 7.5l7.5 5.5 7.5-5.5")),
    "mailDot": ("Email trigger", p("M15 6H6.5a3 3 0 0 0-3 3v7.5a3 3 0 0 0 3 3h11a3 3 0 0 0 3-3V11M4.5 8.5l7.5 5.2 3.4-2.4") + dot(19.2, 5.8, 2.4)),
    "mailSend": ("Send Email", p("M20 12.5V8a3 3 0 0 0-3-3H6.5a3 3 0 0 0-3 3v7.5a3 3 0 0 0 3 3H13M4.5 7.5l7.3 5.2 7.2-5.2M15.5 18.5h5.5M18.5 16l2.5 2.5-2.5 2.5")),
    "calendar": ("Calendar", rect(4, 5.5, 16, 14.5, 3) + p("M4 10h16M8.5 3.5v4M15.5 3.5v4") + dot(15.5, 15, 1.5)),
    "enter": ("Called by a workflow", p("M3.5 12h9M9.5 8.5L13 12l-3.5 3.5M13.5 4.5h3.5a3 3 0 0 1 3 3v9a3 3 0 0 1-3 3h-3.5")),
    "alarm": ("Error trigger", p("M8.5 3.5h7l5 5v7l-5 5h-7l-5-5v-7zM12 8v5") + dot(12, 16, 1.1)),
    "phoneEvent": ("Phone event", rect(6.5, 3, 11, 18, 2.8) + p("M10.5 18h3") + c(12, 10.5, 2.6) + dot(12, 10.5, 0.9)),
    "toggle": ("Quick Settings tile", rect(3.5, 7.5, 17, 9, 4.5) + dot(16, 12, 2.5)),
    "rss": ("RSS", dot(6, 18, 1.8) + p("M5 11a8 8 0 0 1 8 8M5 5a14 14 0 0 1 14 14")),
    "loop": ("Loop", p("M17 4.5L19.5 7 17 9.5M19.5 7H9a4.5 4.5 0 0 0-4.5 4.5v.5M7 19.5L4.5 17 7 14.5M4.5 17H15a4.5 4.5 0 0 0 4.5-4.5V12")),
    "folder": ("Files", p("M3.5 7.5A2.5 2.5 0 0 1 6 5h3.6l2 2.2H18a2.5 2.5 0 0 1 2.5 2.5v7.8A2.5 2.5 0 0 1 18 20H6a2.5 2.5 0 0 1-2.5-2.5z")),
    "cloud": ("Drive", p("M7 18.5a4.5 4.5 0 0 1-.6-9 6 6 0 0 1 11.4 1.5 3.75 3.75 0 0 1-.55 7.5zM12 15.5v-5M9.8 12.6l2.2-2.2 2.2 2.2")),
}


def svg_doc(body: str) -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">'
        f'<g fill="none" stroke="#000" stroke-width="{S}" stroke-linecap="round" stroke-linejoin="round">'
        + body.replace('class="f"', 'fill="#000" stroke="none"')
        + "</g></svg>"
    )


def outline(body: str):
    """The glyph as one filled pathops.Path in 24-unit space (strokes expanded)."""
    import pathops
    from picosvg.svg import SVG

    pico = SVG.fromstring(svg_doc(body)).topicosvg()
    paths = []
    for shape in pico.shapes():
        path = pathops.Path()
        from fontTools.svgLib.path import parse_path
        from fontTools.pens.basePen import BasePen

        class _Into(BasePen):
            def _moveTo(self, pt):
                path.moveTo(*pt)

            def _lineTo(self, pt):
                path.lineTo(*pt)

            def _curveToOne(self, a, b, c_):
                path.cubicTo(*a, *b, *c_)

            def _qCurveToOne(self, a, b):
                path.quadTo(*a, *b)

            def _closePath(self):
                path.close()

            def _endPath(self):
                path.close()

        parse_path(shape.d, _Into(None))
        paths.append(path)
    out = pathops.Path()
    pathops.union(paths, out.getPen())
    return out


def build_font() -> None:
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.cu2quPen import Cu2QuPen
    from fontTools.pens.reverseContourPen import ReverseContourPen
    from fontTools.pens.transformPen import TransformPen
    from fontTools.pens.ttGlyphPen import TTGlyphPen

    upm = 960
    scale = upm / 24
    names = list(ICONS)
    glyph_order = [".notdef", *names]
    glyphs = {".notdef": TTGlyphPen(None).glyph()}
    for name in names:
        pen = TTGlyphPen(None)
        # SVG y points down; font y points up. Flipping reverses winding, so reverse back.
        flipped = TransformPen(ReverseContourPen(Cu2QuPen(pen, 0.5, reverse_direction=False)), (scale, 0, 0, -scale, 0, upm * 0.875))
        outline(ICONS[name][1]).draw(flipped)
        glyphs[name] = pen.glyph()

    fb = FontBuilder(upm, isTTF=True)
    fb.setupGlyphOrder(glyph_order)
    fb.setupCharacterMap({FIRST_CODEPOINT + i: n for i, n in enumerate(names)})
    fb.setupGlyf(glyphs)
    # The left side bearing must equal each glyph's xMin, or Android's
    # rasterizer moves the glyph left by that much and icons sit off-center.
    glyf = fb.font["glyf"]
    metrics = {}
    for n in glyph_order:
        g = glyf[n]
        g.recalcBounds(glyf)
        metrics[n] = (upm, getattr(g, "xMin", 0))
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=int(upm * 0.875), descent=-int(upm * 0.125))
    fb.setupNameTable({"familyName": FAMILY, "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=int(upm * 0.875), sTypoDescender=-int(upm * 0.125), usWinAscent=int(upm * 0.875), usWinDescent=int(upm * 0.125))
    fb.setupPost()
    FONT.parent.mkdir(parents=True, exist_ok=True)
    fb.save(str(FONT))


def write_dart() -> None:
    lines = [
        "// Generated by scripts/icons/build_icons.py. Do not edit by hand.",
        "import 'package:flutter/widgets.dart';",
        "",
        "/// FlowDroid's own icons: drawn on a 24-unit grid, 1.6 stroke, round ends,",
        "/// with a small filled \"port dot\" like a node's connection point.",
        "abstract final class AppIcons {",
        f"  static const _family = '{FAMILY}';",
        "",
    ]
    for i, (name, (desc, _)) in enumerate(ICONS.items()):
        lines.append(f"  /// {desc}.")
        lines.append(f"  static const {name} = IconData(0x{FIRST_CODEPOINT + i:X}, fontFamily: _family);")
    lines.append("}")
    DART.write_text("\n".join(lines) + "\n")


def preview(out: str) -> None:
    import cairosvg

    cols = 10
    names = list(ICONS)
    rows = (len(names) + cols - 1) // cols
    cell = 72
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{cols * cell}" height="{rows * cell}"><rect width="100%" height="100%" fill="#fff"/>']
    for i, name in enumerate(names):
        x, y = (i % cols) * cell, (i // cols) * cell
        inner = re.sub(r"^<svg[^>]*>|</svg>$", "", svg_doc(ICONS[name][1]))
        parts.append(f'<g transform="translate({x + 12},{y + 6}) scale(2)">{inner}</g>')
        parts.append(f'<text x="{x + cell / 2}" y="{y + cell - 6}" font-size="9" text-anchor="middle" font-family="sans-serif" fill="#666">{name}</text>')
    parts.append("</svg>")
    cairosvg.svg2png(bytestring="".join(parts).encode(), write_to=out)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview")
    args = ap.parse_args()
    if args.preview:
        preview(args.preview)
    else:
        build_font()
        write_dart()
        print(f"{len(ICONS)} icons -> {FONT.relative_to(ROOT)}, {DART.relative_to(ROOT)}")
