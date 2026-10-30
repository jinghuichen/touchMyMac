#!/usr/bin/env python3
"""Generate the animated gesture demos used in the README.

Writes docs/images/gestures/<gesture>-<theme>.svg (one looping card per gesture) and
docs/images/hero-<lang>-<theme>.svg (a touchscreen monitor cycling through the main gestures).
The SVGs animate with CSS only, so they play when GitHub shows them as images.

Run from the repository root: python3 scripts/make_gesture_demos.py
"""

import os

OUT_DIR = "docs/images"

THEMES = {
    "light": {
        "card": "#F5F5F7", "screen_border": "#D2D2D7",
        "wall_a": ("#A9C8FF", "#E6D6FF"), "wall_b": ("#FFD0B0", "#FFB3C6"),
        "menubar": "rgba(255,255,255,0.55)",
        "window": "#FFFFFF", "window_stroke": "rgba(0,0,0,0.10)", "titlebar": "#F0F0F3",
        "line": "#D5D5DB", "line2": "#E6E6EB", "accent": "#0A84FF",
        "finger": "rgba(28,28,30,0.30)", "finger_ring": "#FFFFFF",
        "menu": "#FFFFFF", "dim": "rgba(0,0,0,0.18)",
        "kb": "#D1D3D9", "key": "#FFFFFF", "key_down": "#A6ABB5",
        "sky": "#8EC5FF", "sun": "#FFCF4D", "hill": "#58B984", "hill2": "#2F8F5B",
        "bezel": "#1D1D1F", "stand": "#C7C7CC", "label_bg": "#FFFFFF", "label_text": "#1D1D1F",
        "label_stroke": "rgba(0,0,0,0.08)",
    },
    "dark": {
        "card": "#1C1C1E", "screen_border": "#3A3A3C",
        "wall_a": ("#28407A", "#4F2F75"), "wall_b": ("#7A4030", "#73304F"),
        "menubar": "rgba(0,0,0,0.30)",
        "window": "#2C2C2E", "window_stroke": "rgba(255,255,255,0.10)", "titlebar": "#3A3A3C",
        "line": "#545458", "line2": "#444448", "accent": "#0A84FF",
        "finger": "rgba(255,255,255,0.32)", "finger_ring": "#FFFFFF",
        "menu": "#3A3A3C", "dim": "rgba(0,0,0,0.30)",
        "kb": "#2C2C2E", "key": "#4A4A4E", "key_down": "#6E6E73",
        "sky": "#3D6FA8", "sun": "#E8B83A", "hill": "#3E8F63", "hill2": "#2A6B47",
        "bezel": "#000000", "stand": "#48484A", "label_bg": "#2C2C2E", "label_text": "#F5F5F7",
        "label_stroke": "rgba(255,255,255,0.10)",
    },
}

HERO_LABELS = {
    "en": ["Drag to scroll, flick to glide", "Pinch to zoom",
           "Swipe with three fingers to switch desktops", "Swipe up with four fingers for the keyboard"],
    "zh": ["单指拖动滚动，轻甩带惯性", "双指捏合缩放", "三指左右滑切换桌面", "四指上滑呼出键盘"],
}

W, H = 300, 200  # the screen every scene is drawn on


class Timeline:
    """Maps a scene's local keyframe percentages into a longer cycle, and collects the CSS."""

    def __init__(self, prefix, start=0.0, span=100.0):
        self.prefix, self.start, self.span = prefix, start, span
        self.css = []

    def name(self, key):
        return f"{self.prefix}{key}"

    def at(self, pct):
        return self.start + pct * self.span / 100.0

    def anim(self, key, stops, extra=""):
        """stops: [(local_pct, "css declarations", optional timing function)]. Returns the class name."""
        cls = self.name(key)
        frames = []
        first, last = stops[0], stops[-1]
        if self.at(first[0]) > 0:
            frames.append((0.0, first[1], None))
        for stop in stops:
            frames.append((self.at(stop[0]), stop[1], stop[2] if len(stop) > 2 else None))
        if self.at(last[0]) < 100:
            frames.append((100.0, last[1], None))
        body = "".join(
            f"{p:.3f}%{{{decl}{';animation-timing-function:' + tf if tf else ''}}}" for p, decl, tf in frames)
        self.css.append(f"@keyframes {cls}{{{body}}}")
        self.css.append(f".{cls}{{animation:{cls} var(--cycle) linear infinite;{extra}}}")
        return cls


EASE = "cubic-bezier(0.4,0,0.2,1)"
GLIDE = "cubic-bezier(0.05,0.55,0.25,1)"
ORIGIN_CENTER = "transform-box:fill-box;transform-origin:center;"


def finger(t, key, x, y, path, r=11):
    """A fingertip at (x, y). path: [(pct, dx, dy, opacity, scale)] relative to (x, y)."""
    stops = [(p, f"transform:translate({dx}px,{dy}px) scale({s});opacity:{o}", EASE) for p, dx, dy, o, s in path]
    cls = t.anim(key, stops, ORIGIN_CENTER)
    return (f'<g transform="translate({x},{y})"><g class="{cls}">'
            f'<circle r="{r}" fill="var(--finger)" stroke="var(--finger-ring)" stroke-width="2" filter="url(#{t.prefix}shadow)"/>'
            f'</g></g>')


def tap_path(p_on, p_off=None):
    """Appear, press and lift at pct p_on (and again at p_off)."""
    path = [(0, 0, 0, 0, 1)]
    for p in [p_on] + ([p_off] if p_off else []):
        path += [(p - 6, 0, 0, 0, 1.15), (p - 3, 0, 0, 1, 1), (p, 0, 0, 1, 0.82), (p + 3, 0, 0, 1, 1), (p + 7, 0, 0, 0, 1.1)]
    return path


def window(x, y, w, h, inner="", key_cls=""):
    return (f'<g class="{key_cls}"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="7" fill="var(--window)" stroke="var(--window-stroke)"/>'
            f'<path d="M{x} {y + 7}a7 7 0 0 1 7 -7h{w - 14}a7 7 0 0 1 7 7v9h-{w}z" fill="var(--titlebar)"/>'
            f'<circle cx="{x + 9}" cy="{y + 8}" r="2.6" fill="#FF5F57"/><circle cx="{x + 17}" cy="{y + 8}" r="2.6" fill="#FEBC2E"/>'
            f'<circle cx="{x + 25}" cy="{y + 8}" r="2.6" fill="#28C840"/>{inner}</g>')


def text_lines(x, y, widths, gap=10, color="var(--line)"):
    return "".join(f'<rect x="{x}" y="{y + i * gap}" width="{w}" height="4" rx="2" fill="{color}"/>' for i, w in enumerate(widths))


def wallpaper(t, which="a", x=0):
    gid = f"{t.prefix}wall{which}"
    return (f'<rect x="{x}" y="0" width="{W}" height="{H}" fill="url(#{gid})"/>'
            f'<rect x="{x}" y="0" width="{W}" height="9" fill="var(--menubar)"/>'
            f'<rect x="{x + 8}" y="3" width="4" height="3" rx="1" fill="var(--window)" opacity=".8"/>'
            f'<rect x="{x + 17}" y="3" width="14" height="3" rx="1.5" fill="var(--window)" opacity=".6"/>'
            f'<rect x="{x + 36}" y="3" width="10" height="3" rx="1.5" fill="var(--window)" opacity=".6"/>')


def defs(t, theme):
    th = THEMES[theme]
    return (f'<linearGradient id="{t.prefix}walla" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{th["wall_a"][0]}"/>'
            f'<stop offset="1" stop-color="{th["wall_a"][1]}"/></linearGradient>'
            f'<linearGradient id="{t.prefix}wallb" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{th["wall_b"][0]}"/>'
            f'<stop offset="1" stop-color="{th["wall_b"][1]}"/></linearGradient>'
            f'<filter id="{t.prefix}shadow" x="-50%" y="-50%" width="200%" height="200%">'
            f'<feDropShadow dx="0" dy="1" stdDeviation="1.5" flood-opacity=".35"/></filter>'
            f'<clipPath id="{t.prefix}screen"><rect width="{W}" height="{H}" rx="10"/></clipPath>')


# ---------------------------------------------------------------- scenes

def scene_tap(t):
    knob = t.anim("knob", [(0, "transform:translateX(0)"), (14, "transform:translateX(0)", EASE), (19, "transform:translateX(14px)"),
                           (59, "transform:translateX(14px)", EASE), (64, "transform:translateX(0)")])
    track = t.anim("track", [(0, "fill:var(--line)"), (14, "fill:var(--line)"), (19, "fill:var(--accent)"),
                             (59, "fill:var(--accent)"), (64, "fill:var(--line)")])
    ripple = t.anim("ripple", [(0, "transform:scale(.3);opacity:0"), (14, "transform:scale(.3);opacity:.45", EASE),
                               (30, "transform:scale(2.2);opacity:0"), (59, "transform:scale(.3);opacity:.45", EASE),
                               (75, "transform:scale(2.2);opacity:0")], ORIGIN_CENTER)
    body = (text_lines(78, 62, [110, 84, 96]) + text_lines(78, 128, [56], color="var(--line)")
            + f'<rect class="{track}" x="160" y="122" width="34" height="18" rx="9"/>'
            + f'<g class="{knob}"><circle cx="170" cy="131" r="7" fill="#FFFFFF" stroke="rgba(0,0,0,.12)"/></g>')
    return (wallpaper(t) + window(62, 38, 176, 124, body)
            + f'<circle class="{ripple}" cx="177" cy="131" r="12" fill="var(--accent)"/>'
            + finger(t, "f", 177, 131, tap_path(14, 59)))


def scene_scroll(t):
    pitch, rows = 24, 34
    row_parts = []
    for i in range(rows):
        y = 48 + i * pitch
        a, b = [(96, 64), (80, 52), (104, 70), (72, 58), (90, 40)][i % 5]
        row_parts.append(f'<rect x="80" y="{y}" width="16" height="16" rx="4" fill="var(--line)"/>'
                         + text_lines(102, y + 2, [a, b], gap=8))
    content = t.anim("content", [(0, "transform:translateY(0)"), (12, "transform:translateY(0)"),
                                 (32, "transform:translateY(-72px)", GLIDE), (78, "transform:translateY(-240px)"),
                                 (100, "transform:translateY(-240px)")])
    clip = f"{t.prefix}scrollclip"
    body = (f'<clipPath id="{clip}"><rect x="70" y="40" width="160" height="152"/></clipPath>'
            f'<g clip-path="url(#{clip})"><g class="{content}">{"".join(row_parts)}</g></g>')
    path = [(0, 0, 0, 0, 1), (7, 0, 0, 0, 1.15), (11, 0, 0, 1, 1), (12, 0, 0, 1, 1), (32, 0, -72, 1, 1), (36, 0, -86, 0, 1.1)]
    return wallpaper(t) + window(70, 24, 160, 168, body) + finger(t, "f", 150, 160, path)


def scene_hold_drag(t):
    ring = t.anim("ring", [(0, "stroke-dashoffset:100;opacity:0"), (10, "stroke-dashoffset:100;opacity:1"),
                           (24, "stroke-dashoffset:0;opacity:1"), (52, "stroke-dashoffset:0;opacity:1"),
                           (56, "stroke-dashoffset:0;opacity:0")])
    move = [(0, "transform:translate(0,0)"), (24, "transform:translate(0,0)", EASE), (50, "transform:translate(-80px,24px)"),
            (78, "transform:translate(-80px,24px)", EASE), (94, "transform:translate(0,0)")]
    win = t.anim("win", move)
    ring_move = t.anim("ringmove", move)
    front = window(128, 46, 146, 108, text_lines(140, 72, [110, 92, 120, 70]), win)
    path = [(0, 0, 0, 0, 1), (5, 0, 0, 0, 1.15), (9, 0, 0, 1, 1), (24, 0, 0, 1, 0.92), (50, -80, 24, 1, 0.92),
            (52, -80, 24, 1, 1), (57, -80, 24, 0, 1.1)]
    return (wallpaper(t) + window(26, 34, 150, 110, text_lines(38, 60, [120, 100, 84, 110, 64])) + front
            + f'<g class="{ring_move}"><circle class="{ring}" cx="200" cy="54" r="17" fill="none" stroke="var(--accent)" '
              f'stroke-width="3" pathLength="100" stroke-dasharray="100" transform="rotate(-90 200 54)"/></g>'
            + finger(t, "f", 200, 54, path))


def scene_two_finger_tap(t):
    menu = t.anim("menu", [(0, "opacity:0;transform:scale(.9)"), (17, "opacity:0;transform:scale(.9)", EASE),
                           (22, "opacity:1;transform:scale(1)"), (76, "opacity:1;transform:scale(1)"),
                           (82, "opacity:0;transform:scale(1)")], "transform-box:fill-box;transform-origin:0 0;")
    hl = t.anim("hl", [(0, "opacity:0"), (34, "opacity:0"), (38, "opacity:1"), (100, "opacity:1")])
    menu_svg = (f'<g class="{menu}"><rect x="156" y="104" width="92" height="76" rx="7" fill="var(--menu)" stroke="var(--window-stroke)" '
                f'filter="url(#{t.prefix}shadow)"/>'
                f'<rect class="{hl}" x="160" y="127" width="84" height="15" rx="4" fill="var(--accent)"/>'
                + text_lines(166, 114, [52, 44, 60], gap=16)
                + f'<rect x="162" y="160" width="80" height="1" fill="var(--line2)"/>' + text_lines(166, 168, [38]) + '</g>')
    path_a = tap_path(14)
    return (wallpaper(t) + window(40, 30, 220, 148, text_lines(54, 58, [180, 150, 168, 120, 160, 96, 140]))
            + menu_svg + finger(t, "fa", 140, 112, path_a) + finger(t, "fb", 166, 102, path_a))


def scene_pinch(t):
    zoom = t.anim("zoom", [(0, "transform:scale(1)"), (10, "transform:scale(1)", EASE), (32, "transform:scale(1.8)"),
                           (56, "transform:scale(1.8)", EASE), (78, "transform:scale(1)")],
                  "transform-box:view-box;transform-origin:150px 112px;")
    clip = f"{t.prefix}photoclip"
    photo = (f'<clipPath id="{clip}"><rect x="64" y="44" width="172" height="134" rx="3"/></clipPath>'
             f'<g clip-path="url(#{clip})"><g class="{zoom}">'
             f'<rect x="64" y="44" width="172" height="134" fill="var(--sky)"/>'
             f'<circle cx="190" cy="80" r="14" fill="var(--sun)"/>'
             f'<path d="M64 150 L110 104 L146 136 L176 112 L236 158 V178 H64Z" fill="var(--hill2)"/>'
             f'<path d="M64 166 Q120 134 170 156 T236 150 V178 H64Z" fill="var(--hill)"/></g></g>')
    out = [(0, 0, 0, 0, 1), (5, 0, 0, 0, 1.15), (9, 0, 0, 1, 1), (10, 0, 0, 1, 1), (32, -28, 28, 1, 1), (36, -28, 28, 0, 1.1),
           (51, -28, 28, 0, 1.15), (55, -28, 28, 1, 1), (56, -28, 28, 1, 1), (78, 0, 0, 1, 1), (82, 0, 0, 0, 1.1)]
    mirror = [(p, -dx, -dy, o, s) for p, dx, dy, o, s in out]
    return (wallpaper(t) + window(56, 26, 188, 160, photo)
            + finger(t, "fa", 138, 124, out) + finger(t, "fb", 162, 100, mirror))


def scene_mission_control(t):
    def spread(key, dx, dy, scale):
        return t.anim(key, [(0, "transform:translate(0,0) scale(1)"), (20, "transform:translate(0,0) scale(1)", EASE),
                            (36, f"transform:translate({dx}px,{dy}px) scale({scale})"),
                            (64, f"transform:translate({dx}px,{dy}px) scale({scale})", EASE),
                            (78, "transform:translate(0,0) scale(1)")], ORIGIN_CENTER)
    a = spread("wa", -42, 4, .6)
    b = spread("wb", 38, -26, .6)
    c = spread("wc", 6, 22, .6)
    dim = t.anim("dim", [(0, "opacity:0"), (20, "opacity:0"), (36, "opacity:1"), (64, "opacity:1"), (78, "opacity:0")])
    bar = t.anim("bar", [(0, "opacity:0;transform:translateY(-8px)"), (24, "opacity:0;transform:translateY(-8px)", EASE),
                         (38, "opacity:1;transform:translateY(0)"), (62, "opacity:1;transform:translateY(0)"),
                         (70, "opacity:0;transform:translateY(-8px)")])
    up = [(0, 0, 0, 0, 1), (5, 0, 0, 0, 1.15), (9, 0, 0, 1, 1), (10, 0, 0, 1, 1), (26, 0, -70, 1, 1), (30, 0, -84, 0, 1.1)]
    tap = [(0, 0, 0, 0, 1), (52, 0, 0, 0, 1.15), (55, 0, 0, 1, 1), (58, 0, 0, 1, 0.82), (61, 0, 0, 1, 1), (65, 0, 0, 0, 1.1)]
    thumbs = "".join(f'<rect x="{100 + i * 36}" y="14" width="30" height="20" rx="3" fill="var(--window)" opacity=".85"/>'
                     for i in range(3))
    return (wallpaper(t) + f'<rect class="{dim}" width="{W}" height="{H}" fill="var(--dim)"/>'
            + f'<g class="{bar}">{thumbs}</g>'
            + window(34, 38, 150, 104, text_lines(46, 62, [120, 96, 110, 80]), a)
            + window(118, 64, 150, 104, text_lines(130, 88, [110, 124, 90, 100]), b)
            + window(78, 100, 128, 84, text_lines(90, 124, [90, 104, 70]), c)
            + finger(t, "fa", 125, 172, up) + finger(t, "fb", 150, 168, up) + finger(t, "fc", 175, 172, up)
            + finger(t, "ft", 231, 90, tap))


def scene_desktops(t):
    desks = t.anim("desks", [(0, "transform:translateX(0)"), (12, "transform:translateX(0)", EASE),
                             (34, f"transform:translateX(-{W}px)"), (58, f"transform:translateX(-{W}px)", EASE),
                             (80, "transform:translateX(0)")])
    left = [(0, 0, 0, 0, 1), (5, 0, 0, 0, 1.15), (9, 0, 0, 1, 1), (10, 0, 0, 1, 1), (28, -110, 0, 1, 1), (32, -124, 0, 0, 1.1)]
    right = [(0, 0, 0, 0, 1), (51, 0, 0, 0, 1.15), (55, 0, 0, 1, 1), (56, 0, 0, 1, 1), (74, 110, 0, 1, 1), (78, 124, 0, 0, 1.1)]
    d1 = wallpaper(t, "a") + window(40, 34, 200, 126, text_lines(54, 60, [160, 130, 150, 110, 140, 90]))
    d2 = (wallpaper(t, "b", W) + window(W + 30, 30, 132, 96, text_lines(W + 42, 56, [100, 80, 92, 64]))
          + window(W + 140, 70, 130, 108, text_lines(W + 152, 96, [96, 110, 84, 100])))
    return (f'<g class="{desks}">{d1}{d2}</g>'
            + "".join(finger(t, f"l{i}", x, 112, left) for i, x in enumerate((178, 203, 228)))
            + "".join(finger(t, f"r{i}", x, 112, right) for i, x in enumerate((72, 97, 122))))


def scene_keyboard(t):
    kb = t.anim("kb", [(0, "transform:translateY(112px)"), (10, "transform:translateY(112px)", EASE),
                       (26, "transform:translateY(0)"), (68, "transform:translateY(0)", EASE),
                       (84, "transform:translateY(112px)")])
    keys, key_w, gap = [], 16, 2.5
    key_cls = {}
    pressed = {(1, 3): 34, (1, 8): 42, (2, 5): 50}
    for row, (count, x0) in enumerate([(12, 46), (11, 55), (10, 64)]):
        for i in range(count):
            x, y = x0 + i * (key_w + gap), 124 + row * 18
            fill = "var(--key)"
            cls = ""
            if (row, i) in pressed:
                p = pressed[(row, i)]
                cls = t.anim(f"k{row}{i}", [(0, "fill:var(--key)"), (p - 1, "fill:var(--key)"), (p, "fill:var(--key-down)"),
                                            (p + 3, "fill:var(--key)")])
                key_cls[(row, i)] = (x + key_w / 2, y + 7)
            keys.append(f'<rect class="{cls}" x="{x}" y="{y}" width="{key_w}" height="14" rx="3" fill="{fill}"/>')
    keys.append(f'<rect x="98" y="178" width="104" height="14" rx="3" fill="var(--key)"/>')
    keyboard = (f'<g class="{kb}"><rect x="38" y="116" width="224" height="82" rx="8" fill="var(--kb)" '
                f'filter="url(#{t.prefix}shadow)"/>{"".join(keys)}</g>')
    chars = ""
    for n, p in enumerate((34, 42, 50)):
        c = t.anim(f"c{n}", [(0, "opacity:0"), (p, "opacity:0"), (p + 1, "opacity:1"), (90, "opacity:1"), (96, "opacity:0")])
        chars += f'<rect class="{c}" x="{120 + n * 9}" y="66" width="7" height="9" rx="1.5" fill="var(--label-text)" opacity="0"/>'
    caret_x = t.anim("caret", [(0, "transform:translateX(0)"), (34, "transform:translateX(0)"), (35, "transform:translateX(9px)"),
                               (42, "transform:translateX(9px)"), (43, "transform:translateX(18px)"), (50, "transform:translateX(18px)"),
                               (51, "transform:translateX(27px)"), (96, "transform:translateX(27px)"), (97, "transform:translateX(0)")])
    up = [(0, 0, 0, 0, 1), (4, 0, 0, 0, 1.15), (8, 0, 0, 1, 1), (9, 0, 0, 1, 1), (22, 0, -56, 1, 1), (26, 0, -64, 0, 1.1)]
    down = [(0, 0, 0, 0, 1), (60, 0, 0, 0, 1.15), (64, 0, 0, 1, 1), (65, 0, 0, 1, 1), (80, 0, 56, 1, 1), (84, 0, 64, 0, 1.1)]
    (x1, y1), (x2, y2), (x3, y3) = key_cls[(1, 3)], key_cls[(1, 8)], key_cls[(2, 5)]
    typing = [(0, 0, 0, 0, 1), (29, 0, 0, 0, 1.15), (32, 0, 0, 1, 1), (34, 0, 0, 1, .82), (36, 0, 0, 1, 1),
              (40, x2 - x1, y2 - y1, 1, 1), (42, x2 - x1, y2 - y1, 1, .82), (44, x2 - x1, y2 - y1, 1, 1),
              (48, x3 - x1, y3 - y1, 1, 1), (50, x3 - x1, y3 - y1, 1, .82), (52, x3 - x1, y3 - y1, 1, 1), (56, x3 - x1, y3 - y1, 0, 1.1)]
    page = window(44, 24, 212, 92, text_lines(58, 48, [150, 120]) + f'<rect x="58" y="68" width="56" height="4" rx="2" fill="var(--line)"/>'
                  + chars + f'<g class="{caret_x}"><rect x="119" y="64" width="1.5" height="12" fill="var(--accent)"/></g>')
    return (wallpaper(t) + page + keyboard
            + "".join(finger(t, f"u{i}", x, 186, up) for i, x in enumerate((100, 125, 150, 175)))
            + "".join(finger(t, f"d{i}", x, 132, down) for i, x in enumerate((100, 125, 150, 175)))
            + finger(t, "ty", x1, y1, typing))


SCENES = {
    "tap": scene_tap, "scroll": scene_scroll, "hold-drag": scene_hold_drag, "two-finger-tap": scene_two_finger_tap,
    "pinch": scene_pinch, "mission-control": scene_mission_control, "desktops": scene_desktops, "keyboard": scene_keyboard,
}
HERO_SCENES = ["scroll", "pinch", "desktops", "keyboard"]


def css_vars(theme):
    th = THEMES[theme]
    names = ["window", "window_stroke", "titlebar", "line", "line2", "accent", "finger", "finger_ring", "menu", "dim",
             "kb", "key", "key_down", "sky", "sun", "hill", "hill2", "menubar", "label_text"]
    return ";".join(f"--{n.replace('_', '-')}:{th[n]}" for n in names)


def style(cycle, theme, css):
    return (f"<style>svg{{--cycle:{cycle}s;{css_vars(theme)}}}"
            "@media (prefers-reduced-motion:reduce){*{animation:none!important}}"
            + "".join(css) + "</style>")


def card(name, theme):
    t = Timeline("s")
    scene = SCENES[name](t)
    th = THEMES[theme]
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 220" width="320" height="220" role="img" '
            f'aria-label="{name.replace("-", " ")} gesture">{style(5, theme, t.css)}<defs>{defs(t, theme)}</defs>'
            f'<rect width="320" height="220" rx="16" fill="{th["card"]}"/>'
            f'<g transform="translate(10 10)"><g clip-path="url(#sscreen)">{scene}</g>'
            f'<rect width="{W}" height="{H}" rx="10" fill="none" stroke="{th["screen_border"]}"/></g></svg>')


def hero(lang, theme):
    th = THEMES[theme]
    css, parts, labels = [], [], []
    span = 100 / len(HERO_SCENES)
    label_font = "-apple-system,BlinkMacSystemFont,'SF Pro Text','Helvetica Neue','PingFang SC','Hiragino Sans GB',sans-serif"
    for i, name in enumerate(HERO_SCENES):
        t = Timeline(f"h{i}", start=i * span, span=span)
        scene = SCENES[name](t)
        vis = t.anim("vis", [(0, "opacity:1"), (100, "opacity:1")])
        # visible only inside its own slot
        t.css.pop(); t.css.pop()
        lo, hi = i * span, (i + 1) * span
        frames = (f"0%{{opacity:{1 if i == 0 else 0}}}" + (f"{lo:.2f}%{{opacity:0}}" if i else "")
                  + f"{lo + 0.01:.2f}%{{opacity:1}}{hi - 0.01:.2f}%{{opacity:1}}" + (f"{hi:.2f}%{{opacity:0}}100%{{opacity:0}}" if hi < 100 else "100%{opacity:1}"))
        t.css.append(f"@keyframes {vis}{{{frames}}}.{vis}{{animation:{vis} var(--cycle) linear infinite}}")
        css += t.css
        parts.append(f'<defs>{defs(t, theme)}</defs><g class="{vis}"><g clip-path="url(#{t.prefix}screen)">{scene}</g></g>')
        labels.append(f'<text class="{vis}" x="480" y="694" text-anchor="middle" font-family="{label_font}" font-size="22" '
                      f'font-weight="500" fill="{th["label_text"]}">{HERO_LABELS[lang][i]}</text>')
    scale = 2.8
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 730" width="960" height="730" role="img" '
            f'aria-label="TouchMyMac gestures on a touchscreen monitor">{style(20, theme, css)}'
            f'<rect x="420" y="606" width="120" height="44" fill="{th["stand"]}"/>'
            f'<rect x="350" y="644" width="260" height="10" rx="5" fill="{th["stand"]}"/>'
            f'<rect x="40" y="10" width="880" height="600" rx="22" fill="{th["bezel"]}"/>'
            f'<g transform="translate(60 30) scale({scale})">{"".join(parts)}</g>'
            f'<rect x="190" y="666" width="580" height="42" rx="21" fill="{th["label_bg"]}" stroke="{th["label_stroke"]}"/>'
            + "".join(labels) + '</svg>')


def main():
    os.makedirs(f"{OUT_DIR}/gestures", exist_ok=True)
    for theme in THEMES:
        for name in SCENES:
            with open(f"{OUT_DIR}/gestures/{name}-{theme}.svg", "w") as f:
                f.write(card(name, theme))
        for lang in HERO_LABELS:
            with open(f"{OUT_DIR}/hero-{lang}-{theme}.svg", "w") as f:
                f.write(hero(lang, theme))


if __name__ == "__main__":
    main()
