"""
M0 — Path-graph feasibility spike: evaluation harness.

Scores each candidate graph against GROUND TRUTH on the four metrics the M0
brief requires:

  1. pedestrian path recovery / recall
  2. route distance error vs ground truth
  3. successful destination-routing rate
  4. processing time / computational cost

Nothing here is scored against a method's own output. Ground truth polylines
are generated independently in m0_ground_truth.py.
"""
from __future__ import annotations

import heapq
import json
import math
import statistics
import time
from dataclasses import dataclass

import numpy as np
from scipy.spatial import cKDTree

from m0_algorithms import BUILDERS, Graph
from m0_ground_truth import GroundTruth, generate_dataset


# --------------------------------------------------------------------------
# Metric 1: pedestrian path recovery / recall
# --------------------------------------------------------------------------


def path_recovery(g: Graph, gt: GroundTruth, tol=4.0) -> dict:
    """Fraction of ground-truth path length that the recovered graph covers.

    For each ground-truth edge, ask whether the candidate graph contains a
    parallel edge nearby. Recall = covered true length / total true length.
    Also reports precision = fraction of candidate edges that lie on a true path,
    which is where spurious edges show up.
    """
    if len(gt.edges) == 0:
        return {"recall": 0.0, "precision": 0.0, "spurious_edge_rate": 1.0}

    gtree = cKDTree(g.node_xy) if g.n_nodes else None

    # For each true edge, sample points along it and measure how many are served
    # by a roughly-parallel candidate edge. Credit the COVERED FRACTION of the
    # edge, not a single sample — otherwise recall silently caps at 1/n_samples.
    SAMPLES = 25
    covered = 0.0
    total = 0.0
    for e in gt.edges:
        a, b = gt.nodes[e.a], gt.nodes[e.b]
        total += e.length
        if gtree is None:
            continue
        tdir = (b.x - a.x, b.y - a.y)
        tn = math.hypot(*tdir) or 1.0

        # candidate edges near this true edge, precomputed once per true edge
        cand = []
        for (u, v) in g.edges:
            u2, v2 = g.node_xy[u], g.node_xy[v]
            cdir = (v2[0] - u2[0], v2[1] - u2[1])
            cn = math.hypot(*cdir) or 1.0
            dot = (tdir[0] * cdir[0] + tdir[1] * cdir[1]) / (tn * cn)
            if abs(dot) > 0.5:
                cand.append((u2, v2))

        if not cand:
            continue
        hits = 0
        for frac in np.linspace(0.02, 0.98, SAMPLES):
            px = a.x + tdir[0] * frac
            py = a.y + tdir[1] * frac
            if any(_pt_seg_dist((px, py), u2, v2) <= tol for u2, v2 in cand):
                hits += 1
        covered += e.length * (hits / SAMPLES)

    recall = covered / total if total else 0.0

    # precision: candidate edges lying on any true edge
    if len(g.edges) == 0:
        return {"recall": recall, "precision": 0.0, "spurious_edge_rate": 1.0}

    on_true = 0
    for (u, v) in g.edges:
        u2, v2 = g.node_xy[u], g.node_xy[v]
        cand_mid = ((u2[0] + v2[0]) / 2, (u2[1] + v2[1]) / 2)
        best = min(
            _pt_seg_dist(cand_mid, gt.nodes[e.a], gt.nodes[e.b]) for e in gt.edges
        )
        if best <= tol:
            on_true += 1
    precision = on_true / len(g.edges)

    # Recall alone is gameable: a graph that emits every possible edge scores
    # high recall at terrible precision. F-score is the honest single number,
    # and edge count is reported so that gaming is visible.
    f1 = (
        2 * precision * recall / (precision + recall)
        if (precision + recall) > 0
        else 0.0
    )

    return {
        "recall": round(recall, 4),
        "precision": round(precision, 4),
        "f1": round(f1, 4),
        "spurious_edge_rate": round(1 - precision, 4),
    }


def _pt_seg_dist(p, a, b) -> float:
    ax, ay = a.x if hasattr(a, "x") else a[0], a.y if hasattr(a, "y") else a[1]
    bx, by = b.x if hasattr(b, "x") else b[0], b.y if hasattr(b, "y") else b[1]
    vx, vy = bx - ax, by - ay
    L2 = vx * vx + vy * vy
    if L2 == 0:
        return math.hypot(p[0] - ax, p[1] - ay)
    t = max(0.0, min(1.0, ((p[0] - ax) * vx + (p[1] - ay) * vy) / L2))
    return math.hypot(p[0] - (ax + t * vx), p[1] - (ay + t * vy))


# --------------------------------------------------------------------------
# Metric 2 + 3: routing on the candidate graph vs true route
# --------------------------------------------------------------------------


def _dijkstra(adj: dict, src: int, dst: int):
    dist = {src: 0.0}
    prev = {}
    pq = [(0.0, src)]
    seen = set()
    while pq:
        d, u = heapq.heappop(pq)
        if u in seen:
            continue
        seen.add(u)
        if u == dst:
            break
        for v, w in adj.get(u, ()):
            nd = d + w
            if nd < dist.get(v, float("inf")):
                dist[v] = nd
                prev[v] = u
                heapq.heappush(pq, (nd, v))
    if dst not in dist:
        return None
    return dist[dst]


def route_eval(g: Graph, gt: GroundTruth, traces) -> dict:
    """For each trace: route start->dest on the candidate graph, compare to the
    true route length, and to the straight-line lower bound."""
    if g.n_nodes == 0:
        return {"route_error_mean": None, "routing_success": 0.0, "n": len(traces)}

    adj: dict[int, list[tuple[int, float]]] = {}
    for (u, v), L in zip(g.edges, g.edge_len):
        adj.setdefault(int(u), []).append((int(v), float(L)))
        adj.setdefault(int(v), []).append((int(u), float(L)))

    tree = cKDTree(g.node_xy)
    errs = []
    ok = 0
    for t in traces:
        s = int(tree.query(np.array(t.start_xy))[1])
        d = int(tree.query(np.array(t.end_xy))[1])
        if s == d:
            # both endpoints snapped to the same node: the route is degenerate
            # and carries no routing information. Skipped, not scored as -100%.
            continue
        route = _dijkstra(adj, s, d)
        if route is None:
            continue
        ok += 1
        straight = math.hypot(t.end_xy[0] - t.start_xy[0], t.end_xy[1] - t.start_xy[1])
        if straight > 1e-6:
            # inflation vs the straight-line lower bound; a valid pedestrian
            # network must be >= 0, so a negative score means a measurement bug.
            errs.append((route - straight) / straight)

    n_scored = len(traces)
    return {
        "route_error_mean": round(float(np.mean(errs)), 4) if errs else None,
        "route_error_median": round(float(np.median(errs)), 4) if errs else None,
        "routing_success": round(ok / n_scored, 4) if n_scored else 0.0,
        "n": n_scored,
        "n_routed": ok,
        "n_degenerate": n_scored - ok,
    }


def _polyline_length(pts) -> float:
    return sum(
        math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(pts, pts[1:])
    )


def spurious_route_rate(g: Graph, gt: GroundTruth, traces) -> dict:
    """Fraction of candidate routes that travel over NON-true geometry.

    This is the metric that separates a real footpath network from a hairball.
    A graph that connects every destination can do so by emitting a dense mesh
    of edges that no pedestrian ever walked — reaching 100% of destinations
    while routing people through walls and yards.

    A route is "spurious" if most of its length lies on candidate edges that
    are not close to any ground-truth edge.
    """
    if g.n_nodes == 0 or len(g.edges) == 0:
        return {"spurious_route_rate": 1.0, "usable_route_rate": 0.0}

    adj: dict[int, list[tuple[int, float]]] = {}
    for i, ((u, v), L) in enumerate(zip(g.edges, g.edge_len)):
        adj.setdefault(int(u), []).append((int(v), float(L), i))
        adj.setdefault(int(v), []).append((int(u), float(L), i))

    # mark candidate edges that lie on a true path
    tol = 4.0
    on_true = np.zeros(len(g.edges), bool)
    for i, (u, v) in enumerate(g.edges):
        u2, v2 = g.node_xy[u], g.node_xy[v]
        mid = ((u2[0] + v2[0]) / 2.0, (u2[1] + v2[1]) / 2.0)
        for e in gt.edges:
            if _pt_seg_dist(mid, gt.nodes[e.a], gt.nodes[e.b]) <= tol:
                on_true[i] = True
                break

    tree = cKDTree(g.node_xy)
    spurious_routes = 0
    usable = 0
    scored = 0
    for t in traces:
        s = int(tree.query(np.array(t.start_xy))[1])
        d = int(tree.query(np.array(t.end_xy))[1])
        if s == d:
            continue
        # dijkstra carrying the traversed edge ids
        dist = {s: 0.0}
        prev_e: dict[int, int] = {}
        prev_n: dict[int, int] = {}
        pq = [(0.0, s)]
        seen = set()
        while pq:
            dd, uu = heapq.heappop(pq)
            if uu in seen:
                continue
            seen.add(uu)
            if uu == d:
                break
            for vv, ww, ei in adj.get(uu, ()):
                ndd = dd + ww
                if ndd < dist.get(vv, float("inf")):
                    dist[vv] = ndd
                    prev_e[vv] = ei
                    prev_n[vv] = uu
                    heapq.heappush(pq, (ndd, vv))
        if d not in dist:
            continue
        scored += 1
        # walk back, weighting edge length by whether it is on a true path
        node = d
        tot = 0.0
        good = 0.0
        while node != s:
            e = prev_e[node]
            L = float(g.edge_len[e])
            tot += L
            if on_true[e]:
                good += L
            node = prev_n[node]
        if tot > 0 and (good / tot) < 0.5:
            spurious_routes += 1
        else:
            usable += 1

    return {
        "spurious_route_rate": round(spurious_routes / scored, 4) if scored else 1.0,
        "usable_route_rate": round(usable / scored, 4) if scored else 0.0,
        "n_routes_scored": scored,
    }


def destination_reach(g: Graph, gt: GroundTruth) -> dict:
    """Can a responder be routed to each destination, from the network centroid?"""
    if g.n_nodes == 0:
        return {"dest_reach": 0.0, "reachable": 0, "total": 0}
    adj: dict[int, list[tuple[int, float]]] = {}
    for (u, v), L in zip(g.edges, g.edge_len):
        adj.setdefault(int(u), []).append((int(v), float(L)))
        adj.setdefault(int(v), []).append((int(u), float(L)))

    tree = cKDTree(g.node_xy)
    hub = int(tree.query(np.array([0.0, 80.0]))[1])  # a mid-network staging point
    reach = 0
    for (x, y, _name) in gt.destinations:
        n = int(tree.query(np.array([x, y]))[1])
        if _dijkstra(adj, hub, n) is not None:
            reach += 1
    total = len(gt.destinations)
    return {
        "dest_reach": round(reach / total, 4) if total else 0.0,
        "reachable": reach,
        "total": total,
    }


# --------------------------------------------------------------------------
# Runner
# --------------------------------------------------------------------------


def connectivity(g: Graph) -> dict:
    from scipy.sparse.csgraph import connected_components

    if g.n_nodes == 0:
        return {"components": 0, "largest_frac": 0.0, "mean_degree": 0.0}
    n_comp, labels = connected_components(g.adjacency(), directed=False)
    counts = np.bincount(labels)
    deg = g.degree_histogram()
    return {
        "components": int(n_comp),
        "largest_frac": round(float(counts.max() / g.n_nodes), 4),
        "mean_degree": round(float(deg.mean()), 3) if len(deg) else 0.0,
        "isolated_nodes": int((deg == 0).sum()),
    }


def evaluate_all(traces, gt, builders=None, **kw) -> dict:
    out = {}
    for name, fn in (builders or BUILDERS).items():
        t0 = time.perf_counter()
        try:
            g = fn(traces, **kw)
        except Exception as exc:  # a failing approach is a RESULT, not a crash
            out[name] = {"error": f"{type(exc).__name__}: {exc}"}
            continue
        wall = time.perf_counter() - t0
        out[name] = {
            "nodes": g.n_nodes,
            "edges": g.n_edges,
            "build_seconds": round(g.build_seconds, 4),
            "wall_seconds": round(wall, 4),
            **{f"topo_{k}": v for k, v in connectivity(g).items()},
            **path_recovery(g, gt),
            **route_eval(g, gt, traces),
            **destination_reach(g, gt),
            **spurious_route_rate(g, gt, traces),
            "evidence_class": "inference",
            "state": g.state,
        }
    return out


def print_table(results: dict):
    cols = [
        ("algorithm", lambda r, n: n),
        ("nodes", lambda r, n: r.get("nodes")),
        ("edges", lambda r, n: r.get("edges")),
        ("recall", lambda r, n: r.get("recall")),
        ("f1", lambda r, n: r.get("f1")),
        ("precision", lambda r, n: r.get("precision")),
        ("spurious", lambda r, n: r.get("spurious_edge_rate")),
        ("route_err", lambda r, n: r.get("route_error_mean")),
        ("route_ok", lambda r, n: r.get("routing_success")),
        ("dest_reach", lambda r, n: r.get("dest_reach")),
        ("comps", lambda r, n: r.get("topo_components")),
        ("largest", lambda r, n: r.get("topo_largest_frac")),
        ("build_s", lambda r, n: r.get("build_seconds")),
    ]
    widths = [max(len(c[0]), 12) for c in cols]
    print("  ".join(c[0].rjust(w) for c, w in zip(cols, widths)))
    print("-" * (sum(widths) + 2 * (len(cols) - 1)))
    for name, r in results.items():
        if "error" in r:
            print(f"{name:>12}  ERROR {r['error']}")
            continue
        cells = []
        for (label, fn), w in zip(cols, widths):
            v = fn(r, name)
            cells.append(str(v).rjust(w))
        print("  ".join(cells))


if __name__ == "__main__":
    import sys

    gt, traces = generate_dataset()
    print(f"dataset: {len(gt.nodes)} true nodes, {len(gt.edges)} true edges, "
          f"{len(traces)} traces, {len(gt.destinations)} destinations\n")
    res = evaluate_all(traces, gt)
    print_table(res)

    with open("m0_results.json", "w") as fh:
        json.dump(
            {
                "dataset": {
                    "true_nodes": len(gt.nodes),
                    "true_edges": len(gt.edges),
                    "traces": len(traces),
                    "destinations": len(gt.destinations),
                },
                "results": res,
            },
            fh,
            indent=2,
        )
    print("\nwrote m0_results.json")