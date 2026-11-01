"""アイランドのキャラを動かすためのフォントを作る。

ライブアクティビティは、アプリが書き換えないかぎり止まっている（しかも iOS 18 からは、
書き換えに間隔と回数の制限がある）。ただし経過時間の表示（Text(timerInterval:)）だけは、
iOS 自身が毎秒書き換える。そこで、数字 0〜9 の形をキャラのコマにしたフォントを作って
時計の表示に使う。秒の 1 の位が 1 秒ごとに進むので、コマも 1 秒ごとに進む。

  - 最後の 1 桁だけが見えるように、後ろに数字かコロンが続く文字は幅 0 の空白に置き換える（calt）
  - Claude のコマは Shared/Character.swift の ClawdPose・ClawdShape と同じ決まりで描く
  - 色はフォントに持たせられないので、体（Claude の色）と飾り（白・オレンジ）を別のフォントにして重ねる

  python -E tools/make_frame_fonts.py          Shared/Fonts/ に .ttf を書き出し、Info.plist の UIAppFonts もそろえる
  python -E tools/make_frame_fonts.py --check  HarfBuzz で置き換えを確かめ、全コマの見本画像（dist/）を作る

fonttools と uharfbuzz が要る（pip install --user fonttools uharfbuzz。-I だとユーザー領域を読まないので -E で動かす）
"""

import math
import sys
from pathlib import Path

from fontTools.feaLib.builder import addOpenTypeFeaturesFromString
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Shared" / "Fonts"

EM = 1400          # 文字の高さ = フォントの大きさ
U = 100            # 1 ドットの幅（Claude は 1 マスが幅 1 : 高さ 2 なので、高さは 2U）
CLAUDE_COLS = 22   # 体 18 マス + 右の飾り 4 マス
FRAMES = 10
DIGITS = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]


# ---------------------------------------------------------------- Claude（ClawdShape と同じ）

def clawd_pixels(eyes="center", arms="down", legs="stand"):
    on = {(x, y) for y in range(4) for x in range(3, 15)}
    holes = {
        "center": [(5, 1), (12, 1)],
        "left": [(4, 1), (11, 1)],
        "right": [(6, 1), (13, 1)],
        "squint": [(4, 1), (5, 1), (12, 1), (13, 1)],
    }
    on -= set(holes[eyes])
    left_down, right_down = [(1, 2), (2, 2)], [(15, 2), (16, 2)]
    left_up, right_up = [(2, 1), (1, 0)], [(15, 1), (16, 0)]
    on |= set({
        "down": left_down + right_down,
        "up": left_up + right_up,
        "leftUp": left_up + right_down,
        "rightUp": left_down + right_up,
    }[arms])
    on |= {(x, 4) for x in {"stand": [4, 6, 11, 13], "stepA": [3, 5, 10, 12], "stepB": [5, 7, 12, 14]}[legs]}
    return on


def cell_rects(cells, lift=0):
    """マス（幅 1 : 高さ 2、上 2 段は浮いたとき用の余白）を、横につながる分だけまとめた長方形にする"""
    rows = {}
    for x, y in cells:
        rows.setdefault(y + 2 - lift, []).append(x)
    rects = []
    for row, xs in rows.items():
        xs.sort()
        start = prev = xs[0]
        for x in xs[1:] + [None]:
            if x is not None and x == prev + 1:
                prev = x
                continue
            top = EM - row * 2 * U
            rects.append((start * U, top - 2 * U, (prev + 1) * U, top))
            if x is not None:
                start = prev = x
    return rects


def dot_rects(dots):
    """正方形のドット（14 段）。(x, y, 幅, 高さ) で指定する"""
    return [(x * U, EM - (y + h) * U, (x + w) * U, EM - y * U) for x, y, w, h in dots]


def pose(eyes="center", arms="down", legs="stand", lift=0):
    return cell_rects(clawd_pixels(eyes, arms, legs), lift)


# 飾り。体の右上（マス 17〜21）に置く
def claude_dots(n):
    return dot_rects([(17 + 2 * i, 2, 1, 2) for i in range(n)])


CLAUDE_BANG = dot_rects([(19, 0, 2, 5), (19, 6, 2, 2)])
CLAUDE_CURSOR = dot_rects([(18, 12, 4, 2)])

TYPING = [0, 1, 2, 3, 3]   # 「…」が 1 つずつ増えて、少し止まる（10 コマで 2 回）


def claude_animations():
    """名前 → (10 コマぶんの長方形の並び)。ClawdPose.make の動きを 1 秒 1 コマに直したもの"""
    alt = lambda a, b: [a if f % 2 == 0 else b for f in range(FRAMES)]
    a = {}
    a["ClaudeThink"] = alt(pose(lift=1), pose())
    a["ClaudeThinkAccent"] = [claude_dots(TYPING[f % 5]) for f in range(FRAMES)]
    # 左右を見て、最後にまばたき
    a["ClaudeRead"] = [pose(eyes=e) for e in ["left", "left", "right", "right", "left", "left", "right", "right", "squint", "center"]]
    a["ClaudeSearch"] = [pose(eyes=["left", "center", "right", "center"][f % 4]) for f in range(FRAMES)]
    a["ClaudeEdit"] = alt(pose(arms="leftUp"), pose(arms="rightUp"))
    a["ClaudeShell"] = alt(pose(legs="stepA"), pose(legs="stepB"))
    a["ClaudeShellAccent"] = alt(CLAUDE_CURSOR, [])
    a["ClaudeWeb"] = alt(pose(legs="stepA", lift=1), pose(legs="stepB", lift=1))
    a["ClaudeAgent"] = alt(pose(arms="up", lift=1), pose())
    a["ClaudePlan"] = [pose(eyes="squint" if f in (3, 8) else "center") for f in range(FRAMES)]
    a["ClaudeAsk"] = alt(pose(arms="up", lift=2), pose())
    a["ClaudeAskAccent"] = [CLAUDE_BANG] * FRAMES
    a["ClaudeOther"] = alt(pose(lift=1), pose())
    return a


# ---------------------------------------------------------------- Codex（端末の四角の中の記号、14 × 14 ドット）

def ring(fill_left):
    dots = []
    for y in range(14):
        for x in range(14):
            d = math.hypot(x + 0.5 - 7, y + 0.5 - 7)
            if 3.4 <= d < 4.9 or (d < 3.4 and (x < 7) == fill_left):
                dots.append((x, y, 1, 1))
    return dot_rects(dots)


CHEVRON = dot_rects([(3, 4, 2, 1), (4, 5, 2, 1), (5, 6, 2, 2), (4, 8, 2, 1), (3, 9, 2, 1)])
UNDERSCORE = dot_rects([(8, 9, 4, 1)])


def codex_animations():
    alt = lambda a, b: [a if f % 2 == 0 else b for f in range(FRAMES)]
    minus = [(3, 6, 8, 2)]
    a = {}
    a["CodexThink"] = [dot_rects([(2 + 4 * i, 6, 2, 2) for i in range(TYPING[f % 5])]) for f in range(FRAMES)]
    a["CodexEdit"] = alt(dot_rects(minus + [(6, 3, 2, 3), (6, 8, 2, 3)]), dot_rects(minus))
    a["CodexRead"] = alt(ring(True), ring(False))
    a["CodexShell"] = alt(CHEVRON + UNDERSCORE, CHEVRON)
    a["CodexAsk"] = alt(dot_rects([(6, 2, 2, 7), (6, 10, 2, 2)]), [])
    return a


# ---------------------------------------------------------------- Antigravity（惑星のまわりを回る点）

ORBIT_R = 540
DOT_R = 125


def orbit_dot(f):
    t = math.radians(90 - 36 * f)   # 真上から時計回りに 1 秒 36°
    cx, cy = EM / 2 + ORBIT_R * math.cos(t), EM / 2 + ORBIT_R * math.sin(t)
    return [("poly", [(cx + DOT_R * math.cos(-math.radians(15 * k)), cy + DOT_R * math.sin(-math.radians(15 * k))) for k in range(24)])]


def antigravity_animations():
    return {"AntigravityOrbit": [orbit_dot(f) for f in range(FRAMES)]}


# ---------------------------------------------------------------- フォントにする

def glyph(shapes):
    pen = TTGlyphPen(None)
    for s in shapes:
        if s and s[0] == "poly":
            pts = [(round(x), round(y)) for x, y in s[1]]
        else:
            x0, y0, x1, y1 = s
            # 上下に 1 だけ重ねて、段のつなぎ目に細い線が出ないようにする（時計回り）
            pts = [(x0, y0 - 1), (x0, y1 + 1), (x1, y1 + 1), (x1, y0 - 1)]
        pen.moveTo(pts[0])
        for p in pts[1:]:
            pen.lineTo(p)
        pen.closePath()
    return pen.glyph()


FEATURES = """
languagesystem DFLT dflt;
languagesystem latn dflt;
@CLOCK = [zero one two three four five six seven eight nine colon];
feature calt {
    sub @CLOCK' @CLOCK by blank;
} calt;
"""


def build(name, frames, advance):
    order = [".notdef", "blank", "space", "colon"] + DIGITS
    glyphs = {n: glyph([]) for n in [".notdef", "blank", "space", "colon"]}
    for n, shapes in zip(DIGITS, frames):
        glyphs[n] = glyph(shapes)

    fb = FontBuilder(EM, isTTF=True)
    fb.setupGlyphOrder(order)
    cmap = {0x30 + i: d for i, d in enumerate(DIGITS)}
    cmap.update({0x3A: "colon", 0x20: "space", 0xA0: "space", 0x2009: "space", 0x202F: "space", 0x2236: "colon"})
    fb.setupCharacterMap(cmap)
    fb.setupGlyf(glyphs)
    glyf = fb.font["glyf"]
    widths = {n: 0 for n in ["blank", "space", "colon"]}
    widths[".notdef"] = advance
    widths.update({d: advance for d in DIGITS})
    fb.setupHorizontalMetrics({n: (widths[n], getattr(glyf[n], "xMin", 0)) for n in order})
    fb.setupHorizontalHeader(ascent=EM, descent=0)
    family = "Pulse Frames " + name
    ps = "PulseFrames-" + name
    fb.setupNameTable({"familyName": family, "styleName": "Regular", "uniqueFontIdentifier": ps, "fullName": family, "psName": ps, "version": "Version 1.0"})
    fb.setupOS2(version=4, sTypoAscender=EM, sTypoDescender=0, sTypoLineGap=0, usWinAscent=EM, usWinDescent=0, fsSelection=0x40 | 0x80, achVendID="PULS")
    fb.setupPost()
    addOpenTypeFeaturesFromString(fb.font, FEATURES)
    path = OUT / f"{ps}.ttf"
    fb.save(str(path))
    return path


def all_fonts():
    fonts = {}
    for n, fr in claude_animations().items():
        fonts[n] = (fr, CLAUDE_COLS * U)
    for n, fr in {**codex_animations(), **antigravity_animations()}.items():
        fonts[n] = (fr, EM)
    return fonts


def check(paths):
    """HarfBuzz で時計の文字列を組んで、最後の 1 桁だけに幅が残るかを確かめる。全コマの見本も作る"""
    import uharfbuzz as hb
    from PIL import Image, ImageDraw

    for p in paths:
        face = hb.Face(p.read_bytes())
        font = hb.Font(face)
        for text, last in [("0:07", "seven"), ("12:34", "four"), ("1:02:59", "nine"), ("8", "eight")]:
            buf = hb.Buffer()
            buf.add_str(text)
            buf.guess_segment_properties()
            hb.shape(font, buf)
            names = [font.glyph_to_string(i.codepoint) for i in buf.glyph_infos]
            adv = [pos.x_advance for pos in buf.glyph_positions]
            ok = names[-1] == last and all(n == "blank" for n in names[:-1]) and sum(adv) == adv[-1] > 0
            if not ok:
                raise SystemExit(f"{p.name}: '{text}' → {names} {adv}")
    print(f"HarfBuzz: {len(paths)} 本とも、最後の 1 桁だけが残る")

    from fontTools.ttLib import TTFont
    from fontTools.pens.recordingPen import RecordingPen

    scale = 0.06
    rows = []
    for p in paths:
        f = TTFont(str(p))
        gs = f.getGlyphSet()
        adv = f["hmtx"][DIGITS[0]][0]
        w, h = int(adv * scale), int(EM * scale)
        im = Image.new("RGB", ((w + 8) * FRAMES + 260, h + 8), (20, 20, 24))
        d = ImageDraw.Draw(im)
        d.text((4, h // 2 - 6), p.stem.replace("PulseFrames-", ""), fill=(200, 200, 200))
        for i, g in enumerate(DIGITS):
            rec = RecordingPen()
            gs[g].draw(rec)
            ox = 260 + i * (w + 8)
            d.rectangle([ox, 4, ox + w - 1, 4 + h - 1], outline=(60, 60, 70))
            poly = []
            for op, args in rec.value:
                if op == "moveTo":
                    poly = [args[0]]
                elif op == "lineTo":
                    poly.append(args[0])
                elif op == "closePath":
                    d.polygon([(ox + x * scale, 4 + (EM - y) * scale) for x, y in poly], fill=(217, 120, 87))
        rows.append(im)
    sheet = Image.new("RGB", (max(r.width for r in rows), sum(r.height for r in rows)), (20, 20, 24))
    y = 0
    for r in rows:
        sheet.paste(r, (0, y))
        y += r.height
    out = ROOT / "dist" / "frames-preview.png"
    out.parent.mkdir(exist_ok=True)
    sheet.save(out)
    print(f"見本: {out}")


def register(paths):
    """アプリとウィジェットの Info.plist の UIAppFonts を、作ったフォントの一覧にそろえる"""
    import plistlib

    names = [p.name for p in paths]
    for rel in ["Config/App-Info.plist", "Config/Widget-Info.plist"]:
        plist = ROOT / rel
        data = plistlib.loads(plist.read_bytes())
        data["UIAppFonts"] = names
        plist.write_bytes(plistlib.dumps(data, sort_keys=False))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("PulseFrames-*.ttf"):
        old.unlink()
    paths = [build(n, fr, adv) for n, (fr, adv) in all_fonts().items()]
    register(paths)
    for p in paths:
        print(f"{p.name}  {p.stat().st_size} バイト")
    if "--check" in sys.argv:
        check(paths)


if __name__ == "__main__":
    main()
