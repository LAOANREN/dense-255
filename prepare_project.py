#!/usr/bin/env python3
"""Assemble the Dense 255 data-grid watch face into a Connect IQ project.

Python 3, standard library only. This script assembles source/resources;
the existing GitHub Actions workflow runs monkeyc afterwards.
No photo, portrait, or extra bitmap/XML inputs are required.
"""
from pathlib import Path
import os
import re
import shutil
import struct
import zlib
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
PROJECT = ROOT / "project"
OUT = ROOT / "out"


def select(canonical, versioned):
    matches = [ROOT / n for n in (canonical, versioned) if (ROOT / n).is_file()]
    if len(matches) != 1:
        raise SystemExit(
            f"Upload exactly one of {canonical!r} or {versioned!r}; "
            f"found {len(matches)}"
        )
    return matches[0]


def flag(name, fallback):
    value = os.environ.get(name, fallback).lower()
    if value not in ("true", "false"):
        raise SystemExit(f"{name} must be true or false")
    return value


def xml_write(path, root):
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(root)
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)


def png_icon(path):
    # Generate the existing 40x40 launcher icon with the standard library.
    size = 40
    pixels = bytearray()
    for y in range(size):
        pixels.append(0)
        for x in range(size):
            d2 = (x - 19.5) ** 2 + (y - 19.5) ** 2
            ring = 14 ** 2 <= d2 <= 17 ** 2
            hand = (18 <= x <= 21 and 9 <= y <= 21) or (
                19 <= x <= 29 and 18 <= y <= 21
            )
            pixels.extend((0, 170, 255) if ring or hand else (0, 0, 0))

    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
        )

    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(pixels)))
        + chunk(b"IEND", b"")
    )


def main():
    if PROJECT.exists():
        raise SystemExit("project/ already exists; use a fresh working folder.")

    # Copy only these five inputs. Unused root-level image/XML files are ignored.
    inputs = {
        "source/KnightFace.mc": select("KnightFace.mc", "KnightFace v2.mc"),
        "source/KnightFaceApp.mc": select("KnightFaceApp.mc", "KnightFaceApp v2.mc"),
        "manifest.xml": select("manifest.xml", "manifest v2.xml"),
        "monkey.jungle": select("monkey.jungle", "monkey v2.jungle"),
        "resources/settings/settings.xml": select("settings.xml", "settings v2.xml"),
    }

    source = inputs["source/KnightFace.mc"].read_text(encoding="utf-8")
    if "Gregorian.info" not in source or "App.Properties.getValue" not in source:
        raise SystemExit(
            "Invalid KnightFace source: missing Gregorian.info "
            "or App.Properties.getValue."
        )
    if "FONT_NUMBER_THAI_HOT" in source:
        raise SystemExit("Obsolete font constant detected.")

    theme = os.environ.get("FACE_THEME", "cyan")
    themes = {"cyan": 0, "yellow": 1, "green": 2, "white": 3}
    if theme not in themes:
        raise SystemExit("Invalid FACE_THEME")
    lang = os.environ.get("FACE_LANGUAGE", "zh")
    if lang not in ("zh", "en"):
        raise SystemExit("FACE_LANGUAGE must be zh or en")

    # Keep old settings/workflow fields compatible. The restored view uses its
    # fixed grid: steps/altitude, distance/calories, heart rate/ambient pressure.
    try:
        slots = [
            int(s.strip())
            for s in os.environ.get("FACE_SLOTS", "1,13,2,3,4,12,7,8").split(",")
        ]
    except ValueError as error:
        raise SystemExit("FACE_SLOTS requires eight comma-separated integers from 0 to 13") from error
    if len(slots) != 8 or any(s < 0 or s > 13 for s in slots):
        raise SystemExit("FACE_SLOTS requires eight comma-separated integers from 0 to 13")
    hours = os.environ.get("FACE_HOURS", "24")
    if hours not in ("12", "24"):
        raise SystemExit("FACE_HOURS must be 12 or 24")
    seconds = flag("FACE_SECONDS", "true")

    for relative, source_path in inputs.items():
        dest = PROJECT / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source_path, dest)

    ns = {"iq": "http://www.garmin.com/xml/connectiq"}
    manifest = ET.parse(PROJECT / "manifest.xml")
    app = manifest.find("iq:application", ns)
    if app is None or re.fullmatch(r"[0-9a-fA-F]{32}", app.get("id", "")) is None:
        raise SystemExit("Invalid app ID: use manifest v2.xml")
    products = [p.get("id") for p in app.findall("iq:products/iq:product", ns)]
    if products != ["fr255"]:
        raise SystemExit("This layout currently targets standard Forerunner 255 only.")

    props = ET.Element("properties")
    properties = {
        "accentColor": ("number", str(themes[theme])),
        "chinese": ("boolean", "true" if lang == "zh" else "false"),
        "hours24": ("boolean", "true" if hours == "24" else "false"),
        "showSeconds": ("boolean", seconds),
        "showLines": ("boolean", "true"),
    }
    properties.update({f"slot{i + 1}": ("number", str(v)) for i, v in enumerate(slots)})
    for name, (kind, value) in properties.items():
        ET.SubElement(props, "property", {"id": name, "type": kind}).text = value
    xml_write(PROJECT / "resources/settings/properties.xml", props)

    labels = {
        "AppName": "Dense 255",
        "Accent": "Accent color / 配色", "Cyan": "Cyan / 青", "Yellow": "Yellow / 黄",
        "Green": "Green / 绿", "White": "White / 白", "Chinese": "Chinese labels / 中文标签",
        "Hours24": "24-hour clock / 24小时制", "Seconds": "Seconds while awake / 唤醒时显示秒",
        "Lines": "Dividers / 分隔线",
    }
    for i in range(8):
        labels[f"Slot{i + 1}"] = f"Slot {i + 1} / 数据位{i + 1} (0-13; see README)"
    strings = ET.Element("strings")
    for key, label in labels.items():
        ET.SubElement(strings, "string", {"id": key}).text = label
    xml_write(PROJECT / "resources/strings/strings.xml", strings)

    drawables = ET.Element("drawables")
    ET.SubElement(drawables, "bitmap", {"id": "LauncherIcon", "filename": "icon.png"})
    xml_write(PROJECT / "resources/drawables/drawables.xml", drawables)
    png_icon(PROJECT / "resources/drawables/icon.png")

    # These checks do not replace actual Monkey C compilation.
    settings = ET.parse(PROJECT / "resources/settings/settings.xml")
    for item in settings.getroot().findall("setting"):
        key = item.get("propertyKey", "").removeprefix("@Properties.")
        if key not in properties:
            raise SystemExit(f"Unknown property in settings: {key}")
    for path in PROJECT.rglob("*.xml"):
        ET.parse(path)
        for ref in re.findall(r"@Strings\.([A-Za-z0-9_]+)", path.read_text(encoding="utf-8")):
            if ref not in labels:
                raise SystemExit(f"Unknown string resource: {ref}")

    OUT.mkdir(exist_ok=True)
    config = (
        f"device=fr255\ntheme={theme}\nlanguage={lang}\nslots={slots}\n"
        f"hours={hours}\nseconds={seconds}\nbackground=none\n"
        "grid=steps,altitude,distance,calories,heartRate,ambientPressure\n"
    )
    (OUT / "build-config.txt").write_text(config, encoding="utf-8")
    with zipfile.ZipFile(OUT / "Dense255-source.zip", "w", zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(PROJECT.rglob("*")):
            if path.is_file():
                bundle.write(path, path.relative_to(PROJECT))
    print("Project assembled; XML and resource references checked. No PRG has been built yet.")
    print("Data grid restored. No photo resources required.")
    print(config)


if __name__ == "__main__":
    main()
