"""
M0 — Path-graph feasibility spike: ground-truth trace generator.

Ground truth (the true walked polyline, destination list, path network) is
generated FIRST and held separately from the noisy GPS traces. Evaluation
therefore never scores a method against its own output.

Coordinate frame: local ENU metres (x=east, y=north) about a campus origin.
"""
from __future__ import annotations

import json
import math
import random
from dataclasses import dataclass, field, asdict


# --------------------------------------------------------------------------
# Campus layout — an irregular lane network standing in for a settlement.
# Deliberately non-orthogonal: irregular alleys are the hard case (PRD 6.2).
# --------------------------------------------------------------------------

# Axis-aligned-ish lane polylines in metres. Each is a centreline of a walkable
# lane. Graph connectivity comes from these, NOT from the GPS traces.
LANES: list[list[tuple[float, float]]] = [
    # main spine, roughly N-S, gently curved. Ends at y=156 to MEET the high
    # cross lane exactly; a near-miss endpoint silently fragments the network.
    [(0, 0), (0, 40), (6, 80), (2, 120), (0, 156)],
    # east-west cross lane, high up
    [(0, 156), (45, 158), (90, 150), (130, 152)],
    # mid cross lane, irregular
    [(3, 78), (40, 84), (78, 76), (110, 82)],
    # west spur
    [(0, 40), (-35, 44), (-70, 38)],
    # low east lane
    [(0, 8), (38, 14), (75, 8), (120, 16)],
    # diagonal connector (the awkward one)
    [(40, 84), (52, 118), (45, 153)],
    # short dead-end alley
    [(78, 76), (88, 48), (84, 22)],
    # northern connector
    [(90, 150), (96, 186), (128, 200)],
]

# Destinations: entrances a responder must be routed to. Each sits on/near a
# lane so a correct graph can reach it.
DESTINATIONS: list[tuple[float, float, str]] = [
    (-28.0, 41.0, "d_west_spur_mid"),
    (-66.0, 38.5, "d_west_spur_end"),
    (2.0, 60.0, "d_spine_low"),
    (37.0, 15.0, "d_low_east"),
    (72.0, 8.5, "d_low_east_far"),
    (41.0, 85.0, "d_mid_cross"),
    (79.0, 77.0, "d_mid_cross_east"),
    (86.0, 48.0, "d_deadend_mid"),
    (5.0, 156.0, "d_high_cross_w"),
    (47.0, 158.0, "d_high_cross_mid"),
    (96.0, 151.0, "d_diagonal_top"),
    (97.0, 187.0, "d_north_conn"),
    (126.0, 199.0, "d_north_conn_end"),
]


# --------------------------------------------------------------------------
# True path network, derived from LANES by exact polyline intersection.
# This is the ground-truth graph; a recovered graph is scored against it.
# --------------------------------------------------------------------------


def _seg_intersect(p1, p2, p3, p4):
    """Proper segment intersection point, or None."""
    x1, y1 = p1
    x2, y2 = p2
    x3, y3 = p3
    x4, y4 = p4
    d = (x2 - x1) * (y4 - y3) - (y2 - y1) * (x4 - x3)
    if abs(d) < 1e-12:
        return None
    t = ((x3 - x1) * (y4 - y3) - (y3 - y1) * (x4 - x3)) / d
    u = ((x3 - x1) * (y2 - y1) - (y3 - y1) * (x2 - x1)) / d
    if 0 <= t <= 1 and 0 <= u <= 1:
        return (x1 + t * (x2 - x1), y1 + t * (y2 - y1))
    return None


@dataclass
class TrueNode:
    id: int
    x: float
    y: float


@dataclass
class TrueEdge:
    a: int
    b: int
    length: float


@dataclass
class GroundTruth:
    nodes: dict[int, TrueNode]
    edges: list[TrueEdge]
    lanes: list[list[tuple[float, float]]] = field(default_factory=list)
    destinations: list[tuple[float, float, str]] = field(default_factory=list)

    def node_at(self, x: float, y: float) -> int:
        best, bd = None, float("inf")
        for nid, n in self.nodes.items():
            d = math.hypot(n.x - x, n.y - y)
            if d < bd:
                bd, best = d, nid
        return best

    def to_dict(self):
        return {
            "nodes": [{"id": n.id, "x": n.x, "y": n.y} for n in self.nodes.values()],
            "edges": [{"a": e.a, "b": e.b, "length": e.length} for e in self.edges],
            "destinations": [
                {"x": d[0], "y": d[1], "name": d[2]} for d in self.destinations
            ],
        }


def build_ground_truth() -> GroundTruth:
    """Node every lane properly: each lane is noded at its own vertices AND at
    every intersection with any other lane, ordered by arc length, then chained.

    Naive chaining (vertices only) leaves intersection nodes orphaned, which
    silently fragments the network into disconnected components.
    """
    nodes: dict[tuple[float, float], int] = {}
    node_list: list[TrueNode] = []

    def add_node(x, y):
        key = (round(x, 4), round(y, 4))
        if key not in nodes:
            nid = len(node_list)
            nodes[key] = nid
            node_list.append(TrueNode(nid, x, y))
        return nodes[key]

    for lane in LANES:
        for pt in lane:
            add_node(*pt)

    # ---- collect every lane-lane intersection as a noding point -------------
    node_points: set[tuple[float, float]] = set()
    for i, la in enumerate(LANES):
        for j, lb in enumerate(LANES):
            if j < i:
                continue
            for sa in range(len(la) - 1):
                for sb in range(len(lb) - 1):
                    ip = _seg_intersect(la[sa], la[sa + 1], lb[sb], lb[sb + 1])
                    if ip is not None:
                        node_points.add((round(ip[0], 4), round(ip[1], 4)))
                        add_node(*ip)

    # ---- node each lane along arc length and chain -------------------------
    edges: list[TrueEdge] = []
    seen_edges: set[tuple[int, int]] = set()
    TOL = 1.5

    for lane in LANES:
        # (arc_length, point) for every node lying on this lane
        on_lane: list[tuple[float, tuple[float, float]]] = []
        arc = 0.0
        for k, (x, y) in enumerate(lane):
            if k > 0:
                arc += math.hypot(x - lane[k - 1][0], y - lane[k - 1][1])
            on_lane.append((arc, (x, y)))
            # segment interior between this vertex and the next
            if k + 1 < len(lane):
                nx, ny = lane[k + 1]
                seg_len = math.hypot(nx - x, ny - y)
                for p in node_points:
                    if math.hypot(p[0] - x, p[1] - y) < TOL or math.hypot(
                        p[0] - nx, p[1] - ny
                    ) < TOL:
                        continue
                    # projection parameter onto the segment
                    vx, vy = nx - x, ny - y
                    L2 = vx * vx + vy * vy
                    t = ((p[0] - x) * vx + (p[1] - y) * vy) / L2
                    if t <= 0 or t >= 1:
                        continue
                    if math.hypot(x + t * vx - p[0], y + t * vy - p[1]) > TOL:
                        continue
                    on_lane.append((arc + t * seg_len, p))

        # dedupe by arc length, then order
        on_lane.sort(key=lambda e: e[0])
        deduped: list[tuple[float, tuple[float, float]]] = []
        for a, p in on_lane:
            if deduped and abs(a - deduped[-1][0]) < 0.5:
                continue
            deduped.append((a, p))

        chain = [add_node(*p) for _, p in deduped]
        for u, v in zip(chain, chain[1:]):
            if u == v:
                continue
            key = (min(u, v), max(u, v))
            if key in seen_edges:
                continue
            seen_edges.add(key)
            a, b = node_list[u], node_list[v]
            edges.append(TrueEdge(u, v, math.hypot(a.x - b.x, a.y - b.y)))

    gt = GroundTruth(nodes={n.id: n for n in node_list}, edges=edges)
    gt.lanes = [list(map(tuple, lane)) for lane in LANES]
    gt.destinations = list(DESTINATIONS)
    return gt


# --------------------------------------------------------------------------
# Noisy GPS traces, produced by walking the true network.
# --------------------------------------------------------------------------


def walk_route(
    gt: GroundTruth, start_xy, end_xy, rng: random.Random
) -> list[tuple[float, float]]:
    """Follow true lanes from start to end; return the exact walked polyline.

    Uses Dijkstra over the true graph so the walked route is a genuine
    ground-truth route, not a straight line.
    """
    import heapq

    s = gt.node_at(*start_xy)
    t = gt.node_at(*end_xy)
    adj: dict[int, list[tuple[int, float]]] = {}
    for e in gt.edges:
        adj.setdefault(e.a, []).append((e.b, e.length))
        adj.setdefault(e.b, []).append((e.a, e.length))

    dist = {s: 0.0}
    prev: dict[int, int] = {}
    pq = [(0.0, s)]
    seen = set()
    while pq:
        d, u = heapq.heappop(pq)
        if u in seen:
            continue
        seen.add(u)
        if u == t:
            break
        for v, w in adj.get(u, []):
            nd = d + w
            if nd < dist.get(v, float("inf")):
                dist[v] = nd
                prev[v] = u
                heapq.heappush(pq, (nd, v))

    if t not in dist:
        raise RuntimeError(f"no true path {start_xy} -> {end_xy}")

    path_nodes = [t]
    while path_nodes[-1] != s:
        path_nodes.append(prev[path_nodes[-1]])
    path_nodes.reverse()

    # Reconstruct the polyline along the lane geometry between nodes.
    poly: list[tuple[float, float]] = []
    for u, v in zip(path_nodes, path_nodes[1:]):
        pts = _lane_points_between(gt, u, v)
        poly.extend(pts if pts else [(gt.nodes[u].x, gt.nodes[u].y)])
    poly.append((gt.nodes[path_nodes[-1]].x, gt.nodes[path_nodes[-1]].y))
    return poly


def _lane_points_between(gt: GroundTruth, u: int, v: int):
    """Mid-points of lane segments strictly between two adjacent nodes."""
    out = []
    for lane in gt.lanes:
        for (x1, y1), (x2, y2) in zip(lane, lane[1:]):
            mid = ((x1 + x2) / 2, (y1 + y2) / 2)
            for node_id, target in ((u, (x1, y1)), (v, (x2, y2))):
                if math.hypot(gt.nodes[node_id].x - target[0],
                              gt.nodes[node_id].y - target[1]) < 1.5:
                    out.append(mid)
    return out


def add_gps_noise(
    polyline, rng: random.Random, sigma=3.0, drift=0.0, dropout=0.03, uturn_p=0.0
) -> list[tuple[float, float]]:
    """Apply realistic GPS corruption: gaussian noise, systematic drift,
    dropout, and occasional U-turn artefacts."""
    out = []
    drift_v = (rng.gauss(0, drift), rng.gauss(0, drift)) if drift > 0 else (0.0, 0.0)
    for i, (x, y) in enumerate(polyline):
        if rng.random() < dropout:
            continue
        # systematic drift accumulates along the walk
        f = i / max(1, len(polyline) - 1)
        dx = rng.gauss(0, sigma) + drift_v[0] * f
        dy = rng.gauss(0, sigma) + drift_v[1] * f
        out.append((x + dx, y + dy))
    if uturn_p > 0 and len(out) > 6:
        k = rng.randrange(2, len(out) - 2)
        out[k] = out[k - 2]
    return out


def densify(polyline, step=2.0):
    """Interpolate a polyline to ~step metre spacing (simulates 1 Hz GPS)."""
    if len(polyline) < 2:
        return list(polyline)
    out = []
    for (x1, y1), (x2, y2) in zip(polyline, polyline[1:]):
        d = math.hypot(x2 - x1, y2 - y1)
        n = max(1, int(d / step))
        for i in range(n):
            t = i / n
            out.append((x1 + t * (x2 - x1), y1 + t * (y2 - y1)))
    out.append(polyline[-1])
    return out


@dataclass
class Trace:
    trace_id: str
    mapper_id: str
    noisy: list[tuple[float, float]]
    true_polyline: list[tuple[float, float]]
    dest_name: str
    start_xy: tuple[float, float]
    end_xy: tuple[float, float]


def generate_dataset(
    n_mappers: int = 4,
    walks_per_mapper: int = 8,
    seed: int = 7,
    sigma_range: tuple[float, float] | None = None,
    drift_range: tuple[float, float] | None = None,
    dropout: float | None = None,
) -> tuple[GroundTruth, list[Trace]]:
    """Generate traces. `sigma_range` overrides the default per-mapper GPS
    quality spread so a sweep can hold noise constant or vary it deliberately.

    `sigma_range=(s, s)` gives every mapper identical noise (isolates sigma);
    `sigma_range=(lo, hi)` spreads quality across mappers (the M0 default).
    """
    rng = random.Random(seed)
    gt = build_ground_truth()

    origins = [(2.0, 12.0), (-20.0, 41.0), (60.0, 12.0), (40.0, 86.0)]
    traces: list[Trace] = []
    for m in range(n_mappers):
        mid = f"mapper_{m}"
        for w in range(walks_per_mapper):
            d = DESTINATIONS[(m * walks_per_mapper + w) % len(DESTINATIONS)]
            start = origins[(m + w) % len(origins)]
            try:
                poly = walk_route(gt, start, d[:2], rng)
            except RuntimeError:
                continue
            poly = densify(poly, step=2.0)
            true_poly = list(poly)
            # per-mapper GPS quality differs
            if sigma_range is None:
                sigma = [2.0, 3.5, 5.0, 7.0][m % 4]
            else:
                lo, hi = sigma_range
                frac = (m / max(1, n_mappers - 1)) if hi > lo else 0.0
                sigma = lo + (hi - lo) * frac
            if drift_range is None:
                drift = [0.0, 0.8, 1.6, 2.4][m % 4]
            else:
                lo, hi = drift_range
                frac = (m / max(1, n_mappers - 1)) if hi > lo else 0.0
                drift = lo + (hi - lo) * frac
            drop = 0.03 if dropout is None else dropout
            noisy = add_gps_noise(poly, rng, sigma, drift, drop, 0.02)
            traces.append(
                Trace(
                    trace_id=f"t_{m}_{w}",
                    mapper_id=mid,
                    noisy=noisy,
                    true_polyline=true_poly,
                    dest_name=d[2],
                    start_xy=start,
                    end_xy=d[:2],
                )
            )
    return gt, traces


if __name__ == "__main__":
    import pathlib

    gt, traces = generate_dataset()
    out = pathlib.Path(__file__).parent / "data"
    out.mkdir(exist_ok=True)
    (out / "ground_truth.json").write_text(json.dumps(gt.to_dict(), indent=1))
    (out / "traces.json").write_text(
        json.dumps(
            [
                {
                    "trace_id": t.trace_id,
                    "mapper_id": t.mapper_id,
                    "dest_name": t.dest_name,
                    "start_xy": list(t.start_xy),
                    "end_xy": list(t.end_xy),
                    "noisy": t.noisy,
                    "true_polyline": t.true_polyline,
                }
                for t in traces
            ],
            indent=1,
        )
    )
    print(f"ground truth: {len(gt.nodes)} nodes, {len(gt.edges)} edges")
    print(f"traces: {len(traces)}, mean pts {sum(len(t.noisy) for t in traces)/len(traces):.0f}")
    print("destinations covered:", len({t.dest_name for t in traces}))