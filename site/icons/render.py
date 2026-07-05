"""Render pub-search PWA icons (magnifier glyph on a dark tile). 4x supersample."""

from PIL import Image, ImageDraw

BG = (13, 13, 13, 255)
FG = (53, 181, 103, 255)  # #35b567


def render(size, cx, cy, r, ring_w, hx1, hy1, hx2, hy2, handle_w):
    s = 4  # supersample
    im = Image.new("RGBA", (size * s, size * s), BG)
    d = ImageDraw.Draw(im)

    def sc(v):
        return v * s

    # ring
    d.ellipse(
        [sc(cx - r), sc(cy - r), sc(cx + r), sc(cy + r)],
        outline=FG,
        width=int(ring_w * s),
    )
    # handle with round caps
    d.line([sc(hx1), sc(hy1), sc(hx2), sc(hy2)], fill=FG, width=int(handle_w * s))
    cap = handle_w / 2
    for (x, y) in ((hx1, hy1), (hx2, hy2)):
        d.ellipse([sc(x - cap), sc(y - cap), sc(x + cap), sc(y + cap)], fill=FG)

    return im.resize((size, size), Image.LANCZOS)


# "any" geometry (512 reference), scaled per output size
def any_icon(size):
    k = size / 512
    return render(
        size,
        216 * k, 216 * k, 128 * k, 34 * k,
        308 * k, 308 * k, 404 * k, 404 * k, 34 * k,
    )


# maskable: glyph pulled into the safe zone
def maskable_icon(size):
    k = size / 512
    return render(
        size,
        228 * k, 228 * k, 96 * k, 26 * k,
        296 * k, 296 * k, 364 * k, 364 * k, 26 * k,
    )


any_icon(192).save("icon-192.png")
any_icon(512).save("icon-512.png")
maskable_icon(512).save("icon-maskable.png")
print("wrote icon-192.png icon-512.png icon-maskable.png")
