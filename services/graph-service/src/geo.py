"""
Lat/lon <-> local metres, and building a graph from registry breadcrumbs.

The builder and router work in metres (snap radii, edge lengths). Callers speak
lat/lon. This module is the only place the two meet. Constants match the
registry's own containment maths so both services agree on distances.
"""

from __future__ import annotations

import math
from collections import defaultdict

from hybrid import build_graph

M_PER_DEG_LAT = 110540.0
M_PER_DEG_LON_EQ = 111320.0
MIN_POINTS = 12  # adaptive_seeds' kmin: fewer points cannot seed a graph


class InsufficientBreadcrumbs(ValueError):
    pass


def project(lat: float, lon: float, origin: tuple[float, float]) -> tuple[float, float]:
    # shortcut: equirectangular, accurate to <0.1% within a few km; upgrade if zones span cities
    lat0, lon0 = origin
    return ((lon - lon0) * M_PER_DEG_LON_EQ * math.cos(math.radians(lat0)),
            (lat - lat0) * M_PER_DEG_LAT)


def unproject(x: float, y: float, origin: tuple[float, float]) -> tuple[float, float]:
    lat0, lon0 = origin
    return (lat0 + y / M_PER_DEG_LAT,
            lon0 + x / (M_PER_DEG_LON_EQ * math.cos(math.radians(lat0))))


def group_breadcrumbs(points: list[dict]) -> list[list[tuple[float, float]]]:
    """Registry /v1/breadcrumbs rows -> one (lat, lon) list per trace, in seq order."""
    by_trace: dict[str, list[dict]] = defaultdict(list)
    for p in points:
        by_trace[p["trace_id"]].append(p)
    traces = []
    for pts in by_trace.values():
        pts.sort(key=lambda p: p.get("seq") or 0)
        if len(pts) >= 2:
            traces.append([(float(p["lat"]), float(p["lon"])) for p in pts])
    return traces


class _Trace:
    __slots__ = ("noisy",)

    def __init__(self, xy):
        self.noisy = xy


def build_graph_latlon(traces: list[list[tuple[float, float]]], build_version: int):
    total = sum(len(t) for t in traces)
    if total < MIN_POINTS:
        raise InsufficientBreadcrumbs(
            f"{total} breadcrumb points; at least {MIN_POINTS} are needed to build a graph")
    origin = traces[0][0]
    g = build_graph([_Trace([project(lat, lon, origin) for lat, lon in t]) for t in traces],
                    build_version=build_version)
    g.origin = origin
    return g
