"""
M3 constraint tests: hybrid build, C8 candidate semantics, routing, and the
regression gate that keeps the M0 verdict true.

Run:  .venv-spike/bin/python -m pytest services/graph-service/test/ -q
"""

from __future__ import annotations

import os
import sys

import numpy as np
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "spike"))
sys.path.insert(0, os.path.join(REPO, "services", "graph-service", "src"))

from m0_ground_truth import generate_dataset            # noqa: E402
from m0_algorithms import build_nearest_neighbor        # noqa: E402
from m0_evaluate import path_recovery, route_eval, destination_reach  # noqa: E402
import hybrid                                            # noqa: E402
from hybrid import build_graph, suppress_spurious, ALGORITHM  # noqa: E402
from routing import GraphRegistry, route                # noqa: E402


@pytest.fixture(scope="module")
def dataset():
    return generate_dataset(seed=7)


@pytest.fixture(scope="module")
def graph(dataset):
    gt, traces = dataset
    return build_graph(traces, build_version=1)


# ---------------------------------------------------------------------------
# The M0 decision must be carried, not silently reverted
# ---------------------------------------------------------------------------

def test_algorithm_is_the_m0_recommended_hybrid():
    assert ALGORITHM == "hybrid_mapmatch_delaunay"
    assert hybrid.build_graph.__doc__


def test_adaptive_seeding_beats_a_fixed_k(dataset):
    """M0's failure was a constant k spreading seeds across voids."""
    gt, traces = dataset
    pts = np.vstack([np.asarray(t.noisy, float) for t in traces])

    adaptive = hybrid.adaptive_seeds(pts)
    assert 12 <= len(adaptive) <= 140, "seed count is derived, not assumed"

    # every seed should sit near real trace mass, not in empty space
    from scipy.spatial import cKDTree
    d, _ = cKDTree(pts).query(adaptive)
    assert np.median(d) < 12.0, "seeds land on walked ground"


def test_restricted_bridges_do_not_span_voids(dataset, graph):
    """The specific defect that broke M0's Delaunay: void-bridging edges."""
    gt, traces = dataset
    pts = np.vstack([np.asarray(t.noisy, float) for t in traces])
    from scipy.spatial import cKDTree

    tree = cKDTree(pts)
    bridges = [e for e in graph.edges if e.derivation == "delaunay_bridge"]
    for e in bridges:
        mid = (graph.node_xy[e.a] + graph.node_xy[e.b]) / 2.0
        # every bridge must pass near real trace mass
        assert len(tree.query_ball_point(mid, r=6.0)) > 0

    # and the length cap must actually bind
    if bridges:
        d_tree = cKDTree(graph.node_xy)
        sample = d_tree.query(graph.node_xy, k=min(3, graph.n_nodes))[1]
        spacing = float(np.median([
            np.hypot(*(graph.node_xy[a] - graph.node_xy[b]))
            for a, b in zip(sample[:, 0], sample[:, 1])]))
        assert max(e.length for e in bridges) <= spacing * 2.5 + 1e-6


def test_connectivity_is_not_fragmented(graph):
    """M0's k-means+Delaunay produced 7 components (largest 93%)."""
    c = graph.components()
    assert c["components"] <= 3, f"graph fragmented into {c['components']} components"
    assert c["largest_component_frac"] > 0.95


# ---------------------------------------------------------------------------
# C8 — inference is never authoritative
# ---------------------------------------------------------------------------

def test_every_edge_is_inference_and_a_candidate(graph):
    for e in graph.edges:
        assert e.evidence_class == "inference", "build output must never be ground truth"
        assert e.state == "candidate", "nothing may be asserted without observation"
        assert e.passable is None, "passability must stay unknown until verified"


def test_build_output_carries_the_algorithm_provenance(graph):
    """C9: every segment traces to the method that produced it."""
    for e in graph.edges[:20]:
        d = e.to_dict()
        assert d["algorithm"] == ALGORITHM
        assert d["evidence_class"] == "inference"
        assert d["state"] == "candidate"


def test_suppression_drops_unsupported_edges_only():
    e1 = hybrid.Edge(0, 1, 10.0, "delaunay_bridge", 1, 0.2)
    e2 = hybrid.Edge(1, 2, 10.0, "delaunay_bridge", 1, 0.2)
    e3 = hybrid.Edge(2, 3, 10.0, "mapmatch", 5, 0.9)
    on_true = {(1, 2)}
    kept, dropped = suppress_spurious([e1, e2, e3], on_true)
    assert len(kept) == 2 and dropped == 1
    assert e3 in kept, "backbone edges are retained"
    assert e2 in kept, "a supported bridge survives"
    assert e1 not in kept, "an unsupported bridge is dropped"


# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------

def test_route_reports_unverified_legs_rather_than_hiding_them(graph):
    gt, _ = None, None
    start = (2.0, 12.0)
    end = (41.0, 85.0)
    r = route(graph, start, end)
    assert r.reachable
    assert r.unverified_legs == len(r.legs) > 0
    assert any("INFERRED" in w for w in r.warnings), \
        "a responder must be told the path is machine-inferred"


def test_no_route_is_an_honest_outcome(graph):
    """A point far outside the network must be REFUSED, not snapped.

    Snapping an arbitrary coordinate to the nearest node yields a confident,
    plausible-looking route to the wrong place — the worst possible failure for
    emergency dispatch.
    """
    r = route(graph, (9999.0, 9999.0), (9998.0, 9998.0))
    assert r.reachable is False
    assert len(r.legs) == 0
    assert any("outside_mapped_network" in w for w in r.warnings), \
        f"expected a refusal, got {r.warnings}"


def test_a_point_near_the_network_still_routes(graph):
    """The snap guard must not reject legitimate destinations."""
    r = route(graph, (2.0, 12.0), (41.0, 85.0))
    assert r.reachable is True
    assert not any("outside_mapped_network" in w for w in r.warnings)


def test_graph_version_pinning_survives_a_rebuild(dataset):
    """A rebuild must publish a new version, never mutate in flight."""
    gt, traces = dataset
    reg = GraphRegistry()
    g1 = build_graph(traces, build_version=1)
    reg.publish(g1)
    assert reg.latest_version == 1

    before = route(reg.get(1), (2.0, 12.0), (41.0, 85.0))

    g2 = build_graph(traces, build_version=2)
    reg.publish(g2)
    after = route(reg.get(2), (2.0, 12.0), (41.0, 85.0))

    # a call pinned to v1 still sees v1's shape: the object is not mutated
    assert before.graph_version == 1
    assert after.graph_version == 2
    assert reg.get(1) is g1, "the old version remains addressable"
    assert len(before.legs) == len(after.legs)
    assert g1.n_nodes == reg.get(1).n_nodes


def test_route_is_deterministic(graph):
    a = route(graph, (2.0, 12.0), (41.0, 85.0))
    b = route(graph, (2.0, 12.0), (41.0, 85.0))
    assert a.total_distance_m == pytest.approx(b.total_distance_m)
    assert len(a.legs) == len(b.legs)


# ---------------------------------------------------------------------------
# Regression gate — the M0 verdict must survive production implementation
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("seed", [7, 13, 21, 34, 55, 89])
def test_hybrid_keeps_beating_the_naive_baseline(seed):
    """C9: if the hybrid stops beating the baseline, that is a regression.

    Scored on the CORRECTED M0 metric — usable_route_rate — not destination
    reach, which the baseline satisfies at 1.000 while 96% of its routes
    traverse non-path geometry.
    """
    from m0_evaluate import _pt_seg_dist  # noqa: F401  (shared definition)

    gt, traces = generate_dataset(seed=seed)

    # production hybrid
    g = build_graph(traces, build_version=1)
    hyb_usable = _usable_route_rate(g, gt, traces)
    hyb_reach = _dest_reach(g, gt)

    # naive baseline (the control M0 measured at 0.036)
    base = build_nearest_neighbor(traces)
    base_usable = _usable_route_rate(base, gt, traces)
    base_reach = _dest_reach(base, gt)

    assert hyb_usable > base_usable, (
        f"seed {seed}: hybrid usable_route {hyb_usable:.3f} must exceed "
        f"baseline {base_usable:.3f}"
    )
    # the hybrid must also keep near-full reach: an unreachable structure is a
    # worse dispatch failure than a circuitous route
    assert hyb_reach >= 0.9, f"seed {seed}: reach collapsed to {hyb_reach}"


def test_hybrid_connectivity_stays_single_component_across_seeds():
    """M0's k-means+Delaunay fragmented into 7 components. That must not return."""
    for s in [7, 21, 34, 89]:
        gt, tr = generate_dataset(seed=s)
        g = build_graph(tr, build_version=1)
        c = g.components()
        assert c["components"] == 1, f"seed {s}: {c['components']} components"
        assert c["largest_component_frac"] == pytest.approx(1.0)


def _usable_route_rate(g, gt, traces, tol=4.0):
    """Fraction of routes whose length lies predominantly on real geometry.

    Mirrors m0_evaluate.spurious_route_rate so the spike and production are
    scored identically. Accepts either graph shape: the production `Edge`
    objects or the spike's numpy arrays.
    """
    if g.n_nodes == 0 or len(g.edges) == 0:
        return 0.0

    pairs, lengths = _edge_view(g)

    adj = {}
    for i, (u, v) in enumerate(pairs):
        adj.setdefault(int(u), []).append((int(v), lengths[i], i))
        adj.setdefault(int(v), []).append((int(u), lengths[i], i))

    on_true = np.zeros(len(pairs), bool)
    for i, (u, v) in enumerate(pairs):
        u2, v2 = g.node_xy[u], g.node_xy[v]
        mid = ((u2[0] + v2[0]) / 2.0, (u2[1] + v2[1]) / 2.0)
        for e in gt.edges:
            if _dist(mid, gt.nodes[e.a], gt.nodes[e.b]) <= tol:
                on_true[i] = True
                break

    import heapq
    from scipy.spatial import cKDTree

    tree = cKDTree(g.node_xy)
    usable = scored = 0
    for t in traces:
        s = int(tree.query(np.array(t.start_xy))[1])
        d = int(tree.query(np.array(t.end_xy))[1])
        if s == d:
            continue
        dist, prev_e, prev_n = {s: 0.0}, {}, {}
        pq, seen = [(0.0, s)], set()
        while pq:
            dd, uu = heapq.heappop(pq)
            if uu in seen:
                continue
            seen.add(uu)
            if uu == d:
                break
            for vv, ww, ei in adj.get(uu, []):
                nd = dd + ww
                if nd < dist.get(vv, float("inf")):
                    dist[vv] = nd
                    prev_e[vv] = ei
                    prev_n[vv] = uu
                    heapq.heappush(pq, (nd, vv))
        if d not in dist:
            continue
        scored += 1
        node, tot, good = d, 0.0, 0.0
        while node != s:
            e = prev_e[node]
            L = float(lengths[e])
            tot += L
            if on_true[e]:
                good += L
            node = prev_n[node]
        if tot > 0 and (good / tot) >= 0.5:
            usable += 1
    return usable / scored if scored else 0.0


def _dest_reach(g, gt):
    """Destinations routable from a mid-network hub. Shape-agnostic."""
    import heapq
    from scipy.spatial import cKDTree

    if g.n_nodes == 0:
        return 0.0
    pairs, lengths = _edge_view(g)
    adj = {}
    for i, (u, v) in enumerate(pairs):
        adj.setdefault(u, []).append((v, lengths[i]))
        adj.setdefault(v, []).append((u, lengths[i]))

    tree = cKDTree(g.node_xy)
    hub = int(tree.query(np.array([0.0, 80.0]))[1])

    def dij(src, dst):
        dist, pq, seen = {src: 0.0}, [(0.0, src)], set()
        while pq:
            d, u = heapq.heappop(pq)
            if u in seen:
                continue
            seen.add(u)
            if u == dst:
                return True
            for v, w in adj.get(u, []):
                nd = d + w
                if nd < dist.get(v, float("inf")):
                    dist[v] = nd
                    heapq.heappush(pq, (nd, v))
        return dst in dist

    reach = sum(1 for (x, y, _n) in gt.destinations
                if dij(hub, int(tree.query(np.array([x, y]))[1])))
    return reach / len(gt.destinations) if gt.destinations else 0.0


def _edge_view(g):
    """Return (pairs, lengths) for either graph representation."""
    e0 = g.edges[0]
    if hasattr(e0, "a"):  # production Edge dataclass
        pairs = [(int(e.a), int(e.b)) for e in g.edges]
        lengths = [float(e.length) for e in g.edges]
    else:                 # spike numpy (m,2) array + edge_len
        pairs = [(int(u), int(v)) for u, v in g.edges]
        lengths = [float(x) for x in g.edge_len]
    return pairs, lengths


def _dist(p, a, b):
    import math
    vx, vy = b.x - a.x, b.y - a.y
    L2 = vx * vx + vy * vy
    if L2 == 0:
        return math.hypot(p[0] - a.x, p[1] - a.y)
    t = max(0.0, min(1.0, ((p[0] - a.x) * vx + (p[1] - a.y) * vy) / L2))
    return math.hypot(p[0] - (a.x + t * vx), p[1] - (a.y + t * vy))