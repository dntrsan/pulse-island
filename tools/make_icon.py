"""アプリアイコン（1024x1024、透過なし）を作る。黒いアイランドの中に、Claude のドット絵の子を置く。

使い方: python tools/make_icon.py
出力先: App/Assets.xcassets/AppIcon.appiconset/icon-1024.png
"""
import pathlib

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
OUT = pathlib.Path(__file__).resolve().parent.parent / "App/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
ORANGE = (217, 120, 87)


def clawd_pixels():
    # Shared/Character.swift の ClawdShape と同じ形（正面・腕は下・立ち）
    on = {(x, y) for y in range(4) for x in range(3, 15)}
    on -= {(5, 1), (12, 1)}
    on |= {(1, 2), (2, 2), (15, 2), (16, 2)}
    on |= {(x, 4) for x in (4, 6, 11, 13)}
    return on


def main():
    img = Image.new("RGB", (SIZE, SIZE))
    px = img.load()
    top, bottom = (40, 26, 52), (18, 14, 30)
    for y in range(SIZE):
        t = y / SIZE
        c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(SIZE):
            px[x, y] = c

    # オレンジのぼんやりした光
    glow = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(glow).ellipse((212, 260, 812, 860), fill=150)
    glow = glow.filter(ImageFilter.GaussianBlur(140))
    img = Image.composite(Image.new("RGB", (SIZE, SIZE), ORANGE), img, glow)

    d = ImageDraw.Draw(img)
    # アイランド（黒いカプセル）
    d.rounded_rectangle((132, 352, 892, 672), radius=160, fill=(4, 4, 6))

    # ドット絵の子（1 マスは縦長 1:2）
    w, h = 22, 44
    ox = SIZE // 2 - 18 * w // 2
    oy = 512 - 5 * h // 2
    for x, y in clawd_pixels():
        d.rectangle((ox + x * w, oy + y * h, ox + x * w + w - 1, oy + y * h + h - 1), fill=ORANGE)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT)
    print(OUT)


if __name__ == "__main__":
    main()
