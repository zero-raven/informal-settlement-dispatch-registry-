"""
M0 — Path-graph feasibility spike: candidate algorithms.

Four approaches, per the M0 brief. None is assumed correct.

  1. nearest_neighbor  — naive baseline / control
  2. kmeans_delaunay   — PRD 6.2 proposal: k-means seed placement + weighted Delaunay
  3. dbscan_graph      — density-based alternative
  4. spline_mapmatch   — seed-and-spline map-matching, included to TEST the PRD's
                         stated rejection rationale (no spurious-path suppression)

Every builder returns a graph with node coordinates, edges + length + a
`support` count, and (where applicable) a confidence. None of them is allowed
to assume a recovered edge is walkable: `passable` stays None until verified.
"""
from __future__ import annotations

import math
import time
from dataclasses import dataclass, field

import numpy as np
from scipy.spatial import Delaunay, cKDTree
from scipy.sparse.csgraph import connected_components, dijkstra
from scipy.sparse import csr_matrix


@dataclass
class Graph:
    name: str
    node_xy: np.ndarray                     # (n,2)
    edges: np.ndarray                       # (m,2) int, undirected
    edge_len: np.ndarray                    # (m,)
    edge_support: np.ndarray                # (m,) int, traces contributing
    build_seconds: float = 0.0

    # --- inference-only; NEVER authoritative (C8) --------------------------
    confidence: np.ndarray | None = None
    passable: np.ndarray | None = None      # all-None until human verification
    state: str = "candidate"

    @property
    def n_nodes(self) -> int:
        return len(self.node_xy)

    @property
    def n_edges(self) -> int:
        return len(self.edges)

    def adjacency(self):
        n = self.n_nodes
        rows = np.concatenate([self.edges[:, 0], self.edges[:, 1]])
        cols = np.concatenate([self.edges[:, 1], self.edges[:, 0]])
        data = np.concatenate([self.edge_len, self.edge_len])
        return csr_matrix((data, (rows, cols)), shape=(n, n))

    def degree_histogram(self):
        d = np.zeros(self.n_nodes, dtype=int)
        for a, b in self.edges:
            d[a] += 1
            d[b] += 1
        return d


def _dedupe_edges(a_list, b_list, node_xy):
    seen: dict[tuple[int, int], int] = {}
    out_a, out_b = [], []
    for a, b in zip(a_list, b_list):
        if a == b:
            continue
        k = (min(int(a), int(b)), max(int(a), int(b)))
        if k not in seen:
            seen[k] = len(out_a)
            out_a.append(k[0])
            out_b.append(k[1])
    if not out_a:
        return np.zeros((0, 2), int), np.zeros(0)
    ea = np.array(out_a, int)
    eb = np.array(out_b, int)
    el = np.hypot(*(node_xy[ea] - node_xy[eb]).T)
    return np.column_stack([ea, eb]), el


# ==========================================================================
# 1. Naive baseline: nearest-neighbour snapping
# ==========================================================================


def build_nearest_neighbor(traces, snap_eps=3.0, max_nodes=900, **kw) -> Graph:
    """Snap every GPS point to the nearest node, then chain consecutive snaps.

    This is the control: it is what you get with the least effort, and any real
    method must beat it.
    """
    t0 = time.perf_counter()
    allpts = np.vstack([t.noisy for t in traces])

    # node set = snapped positions (voxel quantisation + centroid refinement)
    quantised: list[np.ndarray] = []
    for t in traces:
        q = np.round(np.array(t.noisy) / snap_eps).astype(int)
        quantised.append(q)
    allq = np.vstack(quantised)
    if len(allq) > max_nodes:
        keep = np.linspace(0, len(allq) - 1, max_nodes).astype(int)
        allq = allq[keep]
    uniq = np.unique(allq, axis=0)

    # refine each node to the mean of points that quantised to it
    key_index = {tuple(row): i for i, row in enumerate(uniq)}
    sums = np.zeros((len(uniq), 2))
    counts = np.zeros(len(uniq))
    off = 0
    for q in quantised:
        for pt in q:
            i = key_index.get(tuple(pt))
            if i is None:
                continue
            sums[i] += allpts[off]
            counts[i] += 1
            off += 1
    nz = counts > 0
    node_xy = uniq.astype(float).copy()
    node_xy[nz] = sums[nz] / counts[nz, None]

    # chain consecutive snapped nodes within each trace
    a_list, b_list = [], []
    for q in quantised:
        ids = [key_index[tuple(pt)] for pt in q if tuple(pt) in key_index]
        for u, v in zip(ids, ids[1:]):
            a_list.append(u)
            b_list.append(v)

    edges, elen = _dedupe_edges(a_list, b_list, node_xy)
    supp = np.ones(len(edges), int)

    g = Graph("nearest_neighbor", node_xy, edges, elen, supp,
              time.perf_counter() - t0)
    g.confidence = np.ones(len(edges)) * 0.5
    g.passable = np.full(len(edges), None, dtype=object)
    return g


# ==========================================================================
# 2. k-means seed placement + weighted Delaunay triangulation (PRD 6.2)
# ==========================================================================


def build_kmeans_delaunay(traces, k=90, weight_by_support=True, **kw) -> Graph:
    from sklearn.cluster import KMeans

    t0 = time.perf_counter()
    allpts = np.vstack([t.noisy for t in traces])

    km = KMeans(n_clusters=k, n_init=4, random_state=0).fit(allpts)
    seeds = km.cluster_centers_
    node_xy = seeds

    tri = Delaunay(seeds)
    # Delaunay edges = unique triangulation edges
    simplices = tri.simplices
    a_list = list(simplices[:, 0]) + list(simplices[:, 1]) + list(simplices[:, 2])
    b_list = list(simplices[:, 1]) + list(simplices[:, 2]) + list(simplices[:, 0])

    # support = how many raw points fall near each edge midpoint
    if weight_by_support:
        pt_tree = cKDTree(allpts)
        mid_list = []
        aa = np.array(a_list, int)
        bb = np.array(b_list, int)
        mid = (node_xy[aa] + node_xy[bb]) / 2.0
        counts = pt_tree.query_ball_point(mid, r=6.0)
        for c in counts:
            mid_list.append(len(c))
        supp_raw = np.array(mid_list, float)
    else:
        supp_raw = np.ones(len(a_list), float)

    # spurious suppression: drop low-support edges (the PRD's key requirement)
    thr = float(np.percentile(supp_raw, 25)) if len(supp_raw) else 0.0
    keep = supp_raw >= max(thr, 1.0)
    a_list = [a for a, k_ in zip(a_list, keep) if k_]
    b_list = [b for b, k_ in zip(b_list, keep) if k_]

    edges, elen = _dedupe_edges(a_list, b_list, node_xy)
    supp = (supp_raw[keep] if len(edges) else np.zeros(0))
    if len(edges):
        supp = np.clip(supp_raw[keep][: len(edges)], 1, None)

    conf = np.zeros(len(edges))
    if len(edges):
        mx = supp.max() if supp.max() > 0 else 1.0
        conf = supp / mx

    g = Graph("kmeans_delaunay", node_xy, edges, elen,
              supp.astype(int), time.perf_counter() - t0)
    g.confidence = conf
    g.passable = np.full(len(edges), None, dtype=object)
    return g


# ==========================================================================
# 3. DBSCAN + graph construction (density-based)
# ==========================================================================


def build_dbscan_graph(traces, eps=4.0, min_samples=4, **kw) -> Graph:
    """Density-based clustering: each core cluster becomes a path node.

    eps/min_samples chosen by sweeping the campus traces (see m0_sweep.py):
    eps=4, min_samples=4 yields ~9 clusters against 25 true nodes while
    discarding only ~3% of points as noise. Larger eps merges every lane into
    one blob and destroys all structure.
    """
    from sklearn.cluster import DBSCAN

    t0 = time.perf_counter()
    allpts = np.vstack([t.noisy for t in traces])

    labels = DBSCAN(eps=eps, min_samples=min_samples).fit_predict(allpts)
    core = labels[labels >= 0]

    if len(core) == 0:
        return Graph("dbscan_graph", np.zeros((0, 2)), np.zeros((0, 2), int),
                     np.zeros(0), np.zeros(0, int), time.perf_counter() - t0)

    # node = per-cluster centroid (walkable path centreline)
    cluster_ids = sorted(set(core))
    node_xy = np.array([allpts[labels == c].mean(axis=0) for c in cluster_ids])
    lut = {c: i for i, c in enumerate(cluster_ids)}

    # per-point node index, offset by trace position in the stacked array
    offsets, off = [], 0
    for t in traces:
        offsets.append(off)
        off += len(t.noisy)
    pt2node = np.array(
        [lut.get(lbl, -1) if lbl >= 0 else -1 for lbl in labels], dtype=int
    )

    # connectivity: consecutive CORE points within the same cluster
    a_list, b_list = [], []
    for t, o in zip(traces, offsets):
        ids = pt2node[o : o + len(t.noisy)]
        for u, v in zip(ids, ids[1:]):
            if u >= 0 and v >= 0 and u != v:
                a_list.append(int(u))
                b_list.append(int(v))

    edges, elen = _dedupe_edges(a_list, b_list, node_xy)
    # support = traces passing near each edge midpoint
    tree = cKDTree(node_xy)
    if len(edges):
        mid = (node_xy[edges[:, 0]] + node_xy[edges[:, 1]]) / 2.0
        supp = np.array([len(c) for c in tree.query_ball_point(mid, r=5.0)])
    else:
        supp = np.zeros(0, int)

    conf = np.zeros(len(edges))
    if len(edges):
        conf = np.clip(supp / max(1, supp.max()), 0, 1)

    g = Graph("dbscan_graph", node_xy, edges, elen,
              supp.astype(int), time.perf_counter() - t0)
    g.confidence = conf
    g.passable = np.full(len(edges), None, dtype=object)
    return g


# ==========================================================================
# 4. Seed-and-spline map-matching (to TEST the PRD's rejection rationale)
# ==========================================================================


def build_spline_mapmatch(traces, snap_eps=3.0, **kw) -> Graph:
    """Classic map-matching: snap to nearest node, then string-match along edges.

    Included specifically to measure whether the PRD's claim holds — that this
    family cannot suppress spurious paths from noisy traces.
    """
    t0 = time.perf_counter()
    allpts = np.vstack([t.noisy for t in traces])

    # seed nodes by quantisation, then refine to trace centroids
    quant = np.round(allpts / snap_eps).astype(int)
    uniq, inv = np.unique(quant, axis=0, return_inverse=True)
    node_xy = np.array([allpts[inv == i].mean(axis=0) for i in range(len(uniq))])

    tree = cKDTree(node_xy)

    # map-match: for each trace, snap consecutive points to nodes, walk
    a_list, b_list = [], []
    for t in traces:
        _, idx = tree.query(np.array(t.noisy))
        idx = [int(x) for x in idx]
        # collapse repeats (string matching along the same edge)
        collapsed = [idx[0]]
        for x in idx[1:]:
            if x != collapsed[-1]:
                collapsed.append(x)
        for u, v in zip(collapsed, collapsed[1:]):
            a_list.append(u)
            b_list.append(v)

    edges, elen = _dedupe_edges(a_list, b_list, node_xy)
    # NOTE: no spurious-edge suppression at all — that is the point of the test
    supp = np.ones(len(edges), int)
    conf = np.full(len(edges), 0.5)

    g = Graph("spline_mapmatch", node_xy, edges, elen, supp,
              time.perf_counter() - t0)
    g.confidence = conf
    g.passable = np.full(len(edges), None, dtype=object)
    return g


BUILDERS = {
    "nearest_neighbor": build_nearest_neighbor,
    "kmeans_delaunay": build_kmeans_delaunay,
    "dbscan_graph": build_dbscan_graph,
    "spline_mapmatch": build_spline_mapmatch,
}