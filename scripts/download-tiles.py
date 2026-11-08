#!/usr/bin/env python3
"""Download an offline map tile pack for the pilot zone.

Tiles come from OpenStreetMap's standard tile server for a small pilot
area only (respect its tile usage policy: this is bounded, cached, and
attributed). Output layout matches what the app reads:

    tiles/{z}/{x}/{y}.png

Usage:
    python3 scripts/download-tiles.py                # pilot bbox, z14-17
    python3 scripts/download-tiles.py --min-lat ... --max-lon ... --min-zoom 14 --max-zoom 17

Then transfer the `tiles/` directory to the device's app documents
directory (e.g. via adb push to the app's files dir), or bundle it as
an asset. The app works without tiles — the vector layer is the
fallback — but with them, the settlement map shows real streets offline.
"""
import argparse
import math
import os
import sys
import urllib.request

TILE_URL = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
HEADERS = {"User-Agent": "informal-settlement-registry/1.0 (semester pilot; contact: project team)"}


def deg2num(lat, lon, z):
    n = 2.0 ** z
    xtile = (lon + 180.0) / 360.0 * n
    ytile = (1.0 - math.log(math.tan(math.radians(lat)) + 1.0 / math.cos(math.radians(lat))) / math.pi) / 2.0 * n
    return int(xtile), int(ytile)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--min-lat", type=float, default=12.955)
    ap.add_argument("--max-lat", type=float, default=12.985)
    ap.add_argument("--min-lon", type=float, default=77.575)
    ap.add_argument("--max-lon", type=float, default=77.605)
    ap.add_argument("--min-zoom", type=int, default=14)
    ap.add_argument("--max-zoom", type=int, default=17)
    ap.add_argument("--out", default="tiles")
    args = ap.parse_args()

    total = 0
    for z in range(args.min_zoom, args.max_zoom + 1):
        x0, y0 = deg2num(args.max_lat, args.min_lon, z)
        x1, y1 = deg2num(args.min_lat, args.max_lon, z)
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                path = os.path.join(args.out, str(z), str(x), f"{y}.png")
                os.makedirs(os.path.dirname(path), exist_ok=True)
                if os.path.exists(path):
                    total += 1
                    continue
                req = urllib.request.Request(TILE_URL.format(z=z, x=x, y=y), headers=HEADERS)
                try:
                    with urllib.request.urlopen(req, timeout=20) as r:
                        data = r.read()
                    with open(path, "wb") as f:
                        f.write(data)
                    total += 1
                except Exception as e:
                    print(f"skip {z}/{x}/{y}: {e}", file=sys.stderr)
    print(f"tile pack ready: {total} tiles in {args.out}/ (attribution: (c) OpenStreetMap contributors, ODbL)")


if __name__ == "__main__":
    main()
