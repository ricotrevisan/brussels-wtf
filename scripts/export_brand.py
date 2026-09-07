# /// script
# requires-python = ">=3.11"
# dependencies = ["cairosvg==2.9.0", "pillow==12.1.1"]
# ///
"""Derive all production brand assets from the native SVG master. Run with uv."""

from copy import deepcopy
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
STATIC = ROOT / "priv/static/images/brand"
KIT = ROOT / "output/brand"
NS = "{http://www.w3.org/2000/svg}"
ET.register_namespace("", NS[1:-1])
MASTER = ET.parse(ROOT / "assets/brand/master.svg").getroot()


def element(name, **attrs):
    return ET.Element(NS + name, {key: str(value) for key, value in attrs.items()})


def artwork(kind, dark=False, background=None):
    size = {"icon": (1024, 1024), "horizontal": (1000, 240), "stacked": (750, 1120)}[kind]
    svg = element("svg", width=size[0], height=size[1], viewBox=f"0 0 {size[0]} {size[1]}")
    svg.set("role", "img")
    ET.SubElement(svg, NS + "title").text = "brussels.wtf"
    if background:
        svg.append(element("rect", width="100%", height="100%", fill=background))
    mark = deepcopy(MASTER.find(f"{NS}g[@id='mark']"))
    wordmark = deepcopy(MASTER.find(f"{NS}g[@id='wordmark']"))
    if dark:
        outline = deepcopy(mark.find(f"{NS}path[@id='contour']"))
        outline.attrib.pop("id")
        outline.set("fill", "none")
        outline.set("stroke", "#FFFFFF")
        outline.set("stroke-width", "22")
        outline.set("stroke-linejoin", "round")
        mark.insert(0, outline)
        wordmark.set("fill", "#FFFFFF")
    if kind == "icon":
        # Extra safe space for circular avatars and home-screen masks.
        mark.set("transform", "translate(70 140) scale(.7)")
        svg.append(mark)
    elif kind == "horizontal":
        mark.set("transform", "translate(-45 -2) scale(.24)")
        wordmark.set("transform", "translate(-23 -957)")
        svg.extend([mark, wordmark])
    else:
        group = element("g", transform="translate(-250 -50)")
        group.extend([mark, wordmark])
        svg.append(group)
    return svg


def write_svg(name, svg):
    ET.indent(svg)
    path = STATIC / name
    ET.ElementTree(svg).write(path, encoding="unicode", xml_declaration=True)
    return path


def render(svg, path, width, height, background=None):
    cairosvg.svg2png(
        bytestring=ET.tostring(svg), write_to=str(path),
        output_width=width, output_height=height, background_color=background,
    )


def card(width, height, dark=False):
    svg = element("svg", width=width, height=height, viewBox=f"0 0 {width} {height}")
    svg.append(element("rect", width=width, height=height, fill="#111111" if dark else "#FFFFFF"))
    logo = artwork("horizontal", dark)
    logo.set("x", str(width * .1))
    logo.set("y", str((height - width * .8 * .24) / 2))
    logo.set("width", str(width * .8))
    logo.set("height", str(width * .8 * .24))
    svg.append(logo)
    return svg


def main():
    STATIC.mkdir(parents=True, exist_ok=True)
    (KIT / "web").mkdir(parents=True, exist_ok=True)
    for kind in ["icon", "horizontal", "stacked"]:
        for dark in [False, True]:
            name = ("icon" if kind == "icon" else f"logo-{kind}") + ("-dark" if dark else "-light")
            svg = artwork(kind, dark)
            path = write_svg(name + ".svg", svg)
            (KIT / path.name).write_bytes(path.read_bytes())
            dims = {"icon": (1024, 1024), "horizontal": (2000, 480), "stacked": (750, 1120)}[kind]
            render(svg, KIT / (name + ".png"), *dims)

    # The small favicon uses more of its canvas than the avatar.
    favicon = artwork("icon", dark=True)
    favicon.find(f"{NS}g").set("transform", "translate(-58 12) scale(.9)")
    write_svg("favicon.svg", favicon)
    for size in [16, 32, 48]:
        render(favicon, STATIC / f"favicon-{size}.png", size, size)
        (KIT / f"web/favicon-{size}.png").write_bytes((STATIC / f"favicon-{size}.png").read_bytes())
    # Multi-resolution ICO, generated from the same SVG rather than a resized concept.
    render(favicon, STATIC / "favicon-256.png", 256, 256)
    with Image.open(STATIC / "favicon-256.png") as image:
        image.save(ROOT / "priv/static/favicon.ico", sizes=[(16, 16), (32, 32), (48, 48), (256, 256)])
    (STATIC / "favicon-256.png").unlink()
    (KIT / "web/favicon.ico").write_bytes((ROOT / "priv/static/favicon.ico").read_bytes())
    (KIT / "web/favicon.svg").write_bytes((STATIC / "favicon.svg").read_bytes())

    for name, size in [("apple-touch-icon", 180), ("app-icon-192", 192), ("app-icon-512", 512), ("avatar-400", 400)]:
        svg = artwork("icon", dark=True, background="#111111")
        render(svg, STATIC / (name + ".png"), size, size)
        destination = KIT / (("" if name == "avatar-400" else "web/") + name + ".png")
        destination.write_bytes((STATIC / (name + ".png")).read_bytes())
    for name, width, height, dark in [("social-card-1200x630", 1200, 630, False), ("banner-1500x500", 1500, 500, True)]:
        svg = card(width, height, dark)
        render(svg, STATIC / (name + ".png"), width, height)
        (KIT / (name + ".png")).write_bytes((STATIC / (name + ".png")).read_bytes())
    (KIT / "master.svg").write_bytes((ROOT / "assets/brand/master.svg").read_bytes())
    (KIT / "web/site.webmanifest").write_bytes((STATIC / "site.webmanifest").read_bytes())
    (ROOT / "priv/static/images/logo.svg").write_bytes((STATIC / "icon-light.svg").read_bytes())
    with zipfile.ZipFile(ROOT / "output/brussels-wtf-brand-kit.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(KIT.rglob("*")):
            if path.is_file():
                info = zipfile.ZipInfo(str(path.relative_to(KIT.parent)))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                archive.writestr(info, path.read_bytes())


if __name__ == "__main__":
    main()
