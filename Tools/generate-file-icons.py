#!/usr/bin/env python3
"""Bundle the vendored Material Icon Theme into an app Resources directory.

Writes `<out>/file-icons.json` (name / extension / folder -> icon) and copies
the SVGs those entries need into `<out>/icons`. The upstream mapping lives in
TypeScript (`src/core/icons/fileIcons.ts`, `folderIcons.ts`); only the plain
`fileExtensions` / `fileNames` / `folderNames` lists are read — the
pattern-generated names are skipped, so an unmatched file falls back to the
generic icon rather than being mislabelled.

Usage: python3 Tools/generate-file-icons.py <resources-dir>
"""
import json
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VENDOR = os.path.join(ROOT, "vendor", "material-icon-theme")
ICONS = os.path.join(VENDOR, "icons")

ENTRY = re.compile(r"name:\s*'([^']+)'")
ITEM = re.compile(r"'([^']*)'")

# The generic file and folder icons are drawn by the upstream generator rather
# than committed as files (src/core/generator/{file,folder}Generator.ts), so
# Puzzle writes them out here with the same paths and default colour.
DEFAULT_COLOR = "#90a4ae"
GENERATED = {
    "file": "m8.668 6h3.6641l-3.6641-3.668v3.668m-4.668-4.668h5.332l4 4v8c0 0.73828-0.59375 "
            "1.3359-1.332 1.3359h-8c-0.73828 0-1.332-0.59766-1.332-1.3359v-10.664c0-0.74219 "
            "0.59375-1.3359 1.332-1.3359m3.332 1.3359h-3.332v10.664h8v-6h-4.668z",
    "folder": "m6.922 3.768-.644-.536A1 1 0 0 0 5.638 3H2a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h12a1 1 "
              "0 0 0 1-1V5a1 1 0 0 0-1-1H7.562a1 1 0 0 1-.64-.232",
    "folder-open": "M14.483 6H4.721a1 1 0 0 0-.949.684L2 12V5h12a1 1 0 0 0-1-1H7.562a1 1 0 0 "
                   "1-.64-.232l-.644-.536A1 1 0 0 0 5.638 3H2a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h11l2.403"
                   "-5.606A1 1 0 0 0 14.483 6",
}


def entries(path, list_key):
    """(icon name, [names]) for every entry that carries a plain name list."""
    source = open(path, encoding="utf-8").read()
    found = []
    marks = list(ENTRY.finditer(source))
    for index, mark in enumerate(marks):
        end = marks[index + 1].start() if index + 1 < len(marks) else len(source)
        body = source[mark.start():end]
        match = re.search(r"%s:\s*\[([^\]]*)\]" % list_key, body)
        if not match:
            continue
        names = [n for n in ITEM.findall(match.group(1)) if n]
        if names:
            found.append((mark.group(1), names))
    return found


def has_icon(name):
    return os.path.isfile(os.path.join(ICONS, name + ".svg"))


def collect(path, list_key):
    """Flatten to name -> icon; the first entry wins, as it does upstream."""
    mapping = {}
    used = set()
    for icon, names in entries(path, list_key):
        if not has_icon(icon):
            continue
        for name in names:
            key = name.lower()
            if key in mapping:
                continue
            mapping[key] = icon
            used.add(icon)
    return mapping, used


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    if not os.path.isdir(ICONS):
        sys.exit("vendor/material-icon-theme is missing — run vendor/fetch.sh first")
    out = sys.argv[1]
    icon_out = os.path.join(out, "icons")
    os.makedirs(icon_out, exist_ok=True)

    file_source = os.path.join(VENDOR, "src", "core", "icons", "fileIcons.ts")
    folder_source = os.path.join(VENDOR, "src", "core", "icons", "folderIcons.ts")
    extensions, used_a = collect(file_source, "fileExtensions")
    names, used_b = collect(file_source, "fileNames")
    folders, used_c = collect(folder_source, "folderNames")
    used = used_a | used_b | used_c

    for icon in sorted(used):
        shutil.copyfile(os.path.join(ICONS, icon + ".svg"),
                        os.path.join(icon_out, icon + ".svg"))
    # Light-appearance variants ship beside the icons they replace.
    light = []
    for icon in sorted(used):
        if has_icon(icon + "_light"):
            shutil.copyfile(os.path.join(ICONS, icon + "_light.svg"),
                            os.path.join(icon_out, icon + "_light.svg"))
            light.append(icon)
    for name, path in GENERATED.items():
        with open(os.path.join(icon_out, name + ".svg"), "w", encoding="utf-8") as svg:
            svg.write('<svg viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg">'
                      '<path d="%s" fill="%s" /></svg>' % (path, DEFAULT_COLOR))

    with open(os.path.join(out, "file-icons.json"), "w", encoding="utf-8") as manifest:
        json.dump({"names": names, "extensions": extensions,
                   "folders": folders, "light": light},
                  manifest, sort_keys=True, separators=(",", ":"))
    print("   %d icons, %d extensions, %d names, %d folders"
          % (len(used) + len(GENERATED), len(extensions), len(names), len(folders)))


main()
