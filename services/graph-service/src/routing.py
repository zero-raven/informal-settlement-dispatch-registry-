"""
M3 — A* routing over the inferred graph, with version pinning.

Two properties that matter for emergency dispatch:

1. `graph_version` is pinned for the life of a call, so a rebuild never serves
   a half-connected graph. A caller gets a complete answer or an explicit
   `503 graph_rebuilding`, never a route through a graph mid-construction.
2. Routing confidence is INFERENCE. A low-confidence route is surfaced to the
   dispatcher, not hidden, and it never silently rewrites ground truth (C8).
"""

from __future__ import annotations

import heapq
import math
from dataclasses import dataclass, field


@dataclass
class RouteLeg:
    edge_index: int
    from_node: int
    to_node: int
    length_m: float
    confidence: float
    derivation: str
    state: str            # always 'candidate' until observed (C8)


@dataclass
class Route:
    reachable: bool
    legs: list[RouteLeg] = field(default_factory=list)
    total_distance_m: float = 0.0
    graph_version: int = 0
    min_confidence: float = 0.0
    unverified_legs: int = 0
    warnings: list[str] = field(default_factory=list)

    def to_dict(self):
        return {
            "reachable": self.reachable,
            "graph_version": self.graph_version,
            "total_distance_m": round(self.total_distance_m, 2),
            "min_confidence": round(self.min_confidence, 4),
            "unverified_legs": self.unverified_legs,
            "legs": [
                {
                    "from_node": l.from_node, "to_node": l.to_node,
                    "length_m": round(l.length_m, 2),
                    "confidence": round(l.confidence, 4),
                    "derivation": l.derivation, "state": l.state,
                }
                for l in (self.legs or [])
            ],
            "warnings": self.warnings or [],
        }


class GraphRegistry:
    """Holds built graphs by version so a routing call can pin one.

    A rebuild publishes a NEW version rather than mutating in place; an
    in-flight call keeps reading the version it started with.
    """

    def __init__(self):
        self._graphs: dict[int, object] = {}
        self._latest: int | None = None

    def publish(self, graph):
        self._graphs[graph.build_version] = graph
        self._latest = graph.build_version
        return graph.build_version

    @property
    def latest_version(self):
        return self._latest

    def get(self, version: int | None = None):
        v = version if version is not None else self._latest
        if v is None:
            return None
        return self._graphs.get(v)

    def known_versions(self):
        return sorted(self._graphs)

    def rebuild_in_progress(self) -> bool:
        """True when the newest build is not yet the one we would serve."""
        return self._latest is None


def route(graph, start_xy, end_xy, *, graph_version=None, confidence_floor=0.0,
          max_snap_m=25.0):
    """A* between two coordinates on the inferred graph.

    Returns a Route with `reachable=False` rather than raising when no path
    exists: `no_route` is an honest outcome the dispatcher must handle, not an
    error to paper over.

    `max_snap_m` refuses to route to a point far from the network. Snapping an
    arbitrary coordinate to the nearest node would otherwise produce a confident,
    plausible-looking route to the wrong place — the worst possible failure for
    an emergency dispatch call.
    """
    from scipy.spatial import cKDTree

    if graph is None or graph.n_nodes == 0:
        return Route(reachable=False, legs=[], warnings=["graph_unavailable"],
                     graph_version=graph_version or 0)

    tree = cKDTree(graph.node_xy)
    s_dist, s = tree.query([start_xy[0], start_xy[1]])
    d_dist, t = tree.query([end_xy[0], end_xy[1]])

    far = []
    if float(s_dist) > max_snap_m:
        far.append(f"start is {float(s_dist):.0f} m from the mapped network")
    if float(d_dist) > max_snap_m:
        far.append(f"destination is {float(d_dist):.0f} m from the mapped network")
    if far:
        # Refusing is the safe outcome. Returning a route to the nearest node
        # would look correct and be wrong.
        return Route(
            reachable=False, legs=[], graph_version=graph.build_version,
            warnings=["outside_mapped_network: " + "; ".join(far)],
        )

    s, t = int(s), int(t)

    adj: dict[int, list[tuple[int, int]]] = {}
    for i, e in enumerate(graph.edges):
        adj.setdefault(e.a, []).append((e.b, i))
        adj.setdefault(e.b, []).append((e.a, i))

    if s == t:
        return Route(
            reachable=True, legs=[], total_distance_m=0.0,
            graph_version=graph.build_version, min_confidence=1.0,
            warnings=["start_and_destination_share_a_node"],
        )

    def h(i):
        return float(math.hypot(graph.node_xy[i][0] - graph.node_xy[t][0],
                                graph.node_xy[i][1] - graph.node_xy[t][1]))

    dist = {s: 0.0}
    prev: dict[int, tuple[int, int]] = {}
    pq = [(h(s), 0.0, s)]
    seen = set()

    while pq:
        _, d, u = heapq.heappop(pq)
        if u in seen:
            continue
        seen.add(u)
        if u == t:
            break
        for v, ei in adj.get(u, []):
            nd = d + graph.edges[ei].length
            if nd < dist.get(v, float("inf")):
                dist[v] = nd
                prev[v] = (u, ei)
                heapq.heappush(pq, (nd + h(v), nd, v))

    if t not in dist:
        return Route(
            reachable=False, legs=[], graph_version=graph.build_version,
            warnings=["no_route: structure exists but the graph is disconnected here"],
        )

    legs: list[RouteLeg] = []
    node = t
    while node != s:
        u, ei = prev[node]
        e = graph.edges[ei]
        legs.append(RouteLeg(ei, u, node, e.length, e.confidence, e.derivation, e.state))
        node = u
    legs.reverse()

    warnings = []
    unverified = sum(1 for l in legs if l.state != "asserted")
    minc = min((l.confidence for l in legs), default=1.0)
    if unverified:
        # Inference, surfaced not hidden (C8). A responder is told the path is
        # machine-inferred and has not been walked.
        warnings.append(
            f"{unverified}/{len(legs)} legs are INFERRED and not yet verified by a mapper"
        )
    if minc < confidence_floor:
        warnings.append(f"low-confidence segment present (min {minc:.2f})")

    return Route(
        reachable=True,
        legs=legs,
        total_distance_m=float(sum(l.length_m for l in legs)),
        graph_version=graph.build_version,
        min_confidence=minc,
        unverified_legs=unverified,
        warnings=warnings,
    )