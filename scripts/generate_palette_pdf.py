#!/usr/bin/env python3
"""
Generate a palette reference PDF for engine-driven gtex62 Conky suites.

Only suites that opt into the engine palette contract are considered:

  [theme]
  default_palette = "amber"
  palette_catalog = "theme/osa-palettes.lua"
  palette_format = "role3"

Supported formats:
  role3: suite-local palettes with bg/fg/ink roles.
  tone5: suite-local palettes with tone0..tone4 ramps.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python < 3.11 fallback
    tomllib = None

from PIL import Image, ImageDraw, ImageFont


PAGE_W = 1654
PAGE_H = 2339
MARGIN_X = 90
MARGIN_Y = 90
HEADER_H = 90
GROUP_H = 48
ROW_H = 136
SWATCH_W = 120
SWATCH_H = 72
SWATCH_GAP = 18
TEXT_COLOR = (18, 18, 18)
SUBTLE = (96, 96, 96)
BG = (250, 250, 248)
RULE = (214, 214, 210)


@dataclass(frozen=True)
class Suite:
    suite_id: str
    name: str
    root: Path
    default_palette: str
    palette_catalog: Path
    palette_format: str


def rgb_from_floats(values: Iterable[str]) -> tuple[int, int, int]:
    return tuple(max(0, min(255, round(float(v) * 255))) for v in values)


def hex_from_rgb(rgb: tuple[int, int, int]) -> str:
    return "#{:02X}{:02X}{:02X}".format(*rgb)


def load_fonts() -> dict[str, ImageFont.ImageFont]:
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
    ]
    bold_candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf",
    ]

    def first_font(paths: list[str], size: int) -> ImageFont.ImageFont:
        for path in paths:
            if Path(path).exists():
                return ImageFont.truetype(path, size=size)
        return ImageFont.load_default()

    return {
        "title": first_font(bold_candidates, 34),
        "group": first_font(bold_candidates, 24),
        "name": first_font(bold_candidates, 20),
        "text": first_font(candidates, 16),
        "small": first_font(candidates, 14),
    }


def parse_simple_toml(path: Path) -> dict:
    out: dict = {}
    section: str | None = None
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        section_match = re.match(r"^\[([A-Za-z0-9_.-]+)\]$", line)
        if section_match:
            section = section_match.group(1)
            cursor = out
            for part in section.split("."):
                cursor = cursor.setdefault(part, {})
            continue
        key_match = re.match(r"^([A-Za-z0-9_-]+)\s*=\s*(.+)$", line)
        if not key_match:
            continue
        key, value = key_match.groups()
        value = value.strip().strip('"').strip("'")
        if section:
            cursor = out
            for part in section.split("."):
                cursor = cursor.setdefault(part, {})
            cursor[key] = value
        else:
            out[key] = value
    return out


def load_toml(path: Path) -> dict:
    if tomllib is not None:
        with path.open("rb") as fh:
            return tomllib.load(fh)
    return parse_simple_toml(path)


def discover_suites(conky_root: Path) -> list[Suite]:
    suites: list[Suite] = []
    for suite_toml in sorted(conky_root.glob("*/suite.toml")):
        root = suite_toml.parent
        data = load_toml(suite_toml)
        theme = data.get("theme") or {}
        catalog = theme.get("palette_catalog")
        palette_format = theme.get("palette_format")
        if not catalog or not palette_format:
            continue

        catalog_path = root / catalog
        if not catalog_path.is_file():
            continue

        suites.append(
            Suite(
                suite_id=str(data.get("suite_id") or root.name),
                name=str(data.get("name") or root.name),
                root=root,
                default_palette=str(theme.get("default_palette") or ""),
                palette_catalog=catalog_path,
                palette_format=str(palette_format),
            )
        )
    return suites


def choose_suite(suites: list[Suite]) -> Suite:
    if not suites:
        raise SystemExit("No engine palette suites found.")
    if len(suites) == 1:
        return suites[0]

    print("Engine palette suites:")
    for idx, suite in enumerate(suites, start=1):
        print(f"{idx}) {suite.name}")

    raw = input(f"Select suite [1-{len(suites)}]: ").strip()
    if not raw.isdigit():
        raise SystemExit("Invalid selection.")
    choice = int(raw)
    if choice < 1 or choice > len(suites):
        raise SystemExit("Invalid selection.")
    return suites[choice - 1]


def suite_by_arg(suites: list[Suite], requested: str | None) -> Suite:
    if requested is None:
        return choose_suite(suites)

    normalized = requested.strip()
    for suite in suites:
        if normalized in {suite.suite_id, suite.name, suite.root.name}:
            return suite
    raise SystemExit(f"Engine palette suite not found: {requested}")


def parse_role3(path: Path) -> list[dict]:
    group_re = re.compile(r"^\s*--\s+(.*?)\s*$")
    palette_re = re.compile(r"^\s*([a-z0-9_]+)\s*=\s*\{\s*$")
    role_re = re.compile(
        r"^\s*(bg|fg|ink)\s*=\s*\{\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)\s*\}"
    )
    groups = []
    current_group = None
    current = None
    in_palettes = False

    for raw in path.read_text().splitlines():
        line = raw.rstrip()
        if re.match(r"^\s*palettes\s*=\s*\{\s*$", line):
            in_palettes = True
            continue
        if in_palettes and re.match(r"^\s*}\s*,?\s*$", line) and current is None:
            break
        if not in_palettes:
            continue

        group_match = group_re.match(line)
        if group_match and current is None:
            current_group = {"name": group_match.group(1), "palettes": []}
            groups.append(current_group)
            continue

        if current_group is None:
            current_group = {"name": "Monochrome palettes", "palettes": []}
            groups.append(current_group)

        palette_match = palette_re.match(line)
        if palette_match:
            current = {"name": palette_match.group(1), "swatches": []}
            current_group["palettes"].append(current)
            continue

        role_match = role_re.match(line)
        if current and role_match:
            role, r, g, b = role_match.groups()
            current["swatches"].append({"name": role, "rgb": rgb_from_floats((r, g, b))})
            continue

        if current and re.match(r"^\s*}\s*,\s*$", line):
            current = None

    return groups


def parse_tone5(path: Path) -> list[dict]:
    group_re = re.compile(r"^\s*--\s+(.*?)\s*$")
    palette_re = re.compile(r"^\s*([a-z0-9_]+)\s*=\s*\{\s*$")
    tone_re = re.compile(
        r"^\s*tone([0-4])\s*=\s*\{\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)\s*\}"
    )
    groups = []
    current_group = None
    current_palette = None
    in_palettes = False

    for raw in path.read_text().splitlines():
        line = raw.rstrip()
        if re.match(r"^\s*(local\s+)?tone_palettes\s*=\s*\{\s*$", line):
            in_palettes = True
            continue
        if in_palettes and line == "}":
            break
        if not in_palettes:
            continue

        group_match = group_re.match(line)
        if group_match and group_match.group(1).endswith("palettes"):
            current_group = {"name": group_match.group(1), "palettes": []}
            groups.append(current_group)
            current_palette = None
            continue

        if current_group is None:
            current_group = {"name": "Palettes", "palettes": []}
            groups.append(current_group)

        palette_match = palette_re.match(line)
        if palette_match:
            current_palette = {"name": palette_match.group(1), "swatches": []}
            current_group["palettes"].append(current_palette)
            continue

        tone_match = tone_re.match(line)
        if current_palette and tone_match:
            idx, r, g, b = tone_match.groups()
            current_palette["swatches"].append(
                {"name": f"tone{idx}", "rgb": rgb_from_floats((r, g, b))}
            )
            continue

        if current_palette and line.strip() == "},":
            current_palette = None

    return groups


def parse_palettes(suite: Suite) -> list[dict]:
    if suite.palette_format == "role3":
        return parse_role3(suite.palette_catalog)
    if suite.palette_format == "tone5":
        return parse_tone5(suite.palette_catalog)
    raise SystemExit(f"Unsupported palette_format for {suite.name}: {suite.palette_format}")


def draw_header(draw: ImageDraw.ImageDraw, fonts: dict, suite: Suite, page_num: int) -> int:
    draw.text((MARGIN_X, MARGIN_Y), f"{suite.name} Palette Reference", font=fonts["title"], fill=TEXT_COLOR)
    draw.text((PAGE_W - MARGIN_X - 220, MARGIN_Y + 10), f"Page {page_num}", font=fonts["text"], fill=SUBTLE)
    y = MARGIN_Y + HEADER_H
    draw.line((MARGIN_X, y, PAGE_W - MARGIN_X, y), fill=RULE, width=2)
    meta = f"default: {suite.default_palette or 'unspecified'}   format: {suite.palette_format}"
    draw.text((MARGIN_X, y + 18), meta, font=fonts["small"], fill=SUBTLE)
    return y + 48


def draw_group_header(draw: ImageDraw.ImageDraw, fonts: dict, y: int, name: str) -> int:
    draw.text((MARGIN_X, y), name, font=fonts["group"], fill=TEXT_COLOR)
    y += 34
    draw.line((MARGIN_X, y, PAGE_W - MARGIN_X, y), fill=RULE, width=1)
    return y + 14


def draw_palette_row(draw: ImageDraw.ImageDraw, fonts: dict, y: int, palette: dict) -> int:
    draw.text((MARGIN_X, y + 6), palette["name"], font=fonts["name"], fill=TEXT_COLOR)
    x = MARGIN_X + 270
    for swatch in palette["swatches"]:
        rgb = swatch["rgb"]
        hex_code = hex_from_rgb(rgb)
        draw.rounded_rectangle(
            (x, y, x + SWATCH_W, y + SWATCH_H),
            radius=10,
            fill=rgb,
            outline=(70, 70, 70),
            width=1,
        )
        draw.text((x, y + SWATCH_H + 10), swatch["name"], font=fonts["small"], fill=SUBTLE)
        draw.text((x, y + SWATCH_H + 30), hex_code, font=fonts["text"], fill=TEXT_COLOR)
        x += SWATCH_W + SWATCH_GAP
    return y + ROW_H


def build_pages(suite: Suite, groups: list[dict]) -> list[Image.Image]:
    fonts = load_fonts()
    pages = []
    page = Image.new("RGB", (PAGE_W, PAGE_H), BG)
    draw = ImageDraw.Draw(page)
    page_num = 1
    y = draw_header(draw, fonts, suite, page_num)
    content_top = y

    for group in groups:
        needed = GROUP_H + (ROW_H * len(group["palettes"]))
        if y + needed > PAGE_H - MARGIN_Y and y > content_top:
            pages.append(page)
            page_num += 1
            page = Image.new("RGB", (PAGE_W, PAGE_H), BG)
            draw = ImageDraw.Draw(page)
            y = draw_header(draw, fonts, suite, page_num)
            content_top = y

        y = draw_group_header(draw, fonts, y, group["name"])
        for palette in group["palettes"]:
            if y + ROW_H > PAGE_H - MARGIN_Y:
                pages.append(page)
                page_num += 1
                page = Image.new("RGB", (PAGE_W, PAGE_H), BG)
                draw = ImageDraw.Draw(page)
                y = draw_header(draw, fonts, suite, page_num)
                content_top = y
                y = draw_group_header(draw, fonts, y, group["name"] + " (cont.)")
            y = draw_palette_row(draw, fonts, y, palette)
        y += 12

    pages.append(page)
    return pages


def generate_pdf(suite: Suite) -> Path:
    groups = parse_palettes(suite)
    if not groups or not any(group["palettes"] for group in groups):
        raise SystemExit(f"No palettes parsed from {suite.palette_catalog}")

    output = suite.root / "docs" / "palette-reference.pdf"
    output.parent.mkdir(parents=True, exist_ok=True)
    pages = build_pages(suite, groups)
    first, rest = pages[0], pages[1:]
    first.save(output, "PDF", resolution=150.0, save_all=True, append_images=rest)
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", help="suite id, suite name, or suite directory name")
    parser.add_argument(
        "--conky-root",
        default=str(Path.home() / ".config" / "conky"),
        help="root directory containing suite repositories",
    )
    args = parser.parse_args()

    suites = discover_suites(Path(args.conky_root).expanduser())
    suite = suite_by_arg(suites, args.suite)
    output = generate_pdf(suite)
    print(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
