"""Is the hybrid's lower usable-route caused by seed count, or inherent?

kmax = 140 is the ceiling the adaptive seeder is hitting on every seed. The M0
spine used ~1200 nodes and scored higher. This sweeps the ceiling to find out
whether the production graph can recover the difference without returning to
the spine's unusable density.

Run: .venv-spike/bin/python services/graph-service/tools/sweep_seeds.py
"""

import os
import sys
from types import SimpleNamespace

import numpy as np

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
sys.path[:0] = [os.path.join(REPO, "spike"), os.path.join(REPO, "services", "graph-service", "src")]

from m0_ground_truth import generate_dataset        # noqa: E402
from m0_evaluate import spurious_route_rate        # noqa: E402
import hybrid                                      # noqa: E402

SEEDS = [7, 21, 34]
CEILINGS = [140, 260, 450, 800]


def wrap(g):
    return SimpleNamespace(
        node_xy=g.node_xy,
        edges=[(e.a, e.b) for e in g.edges],
        edge_len=np.array([e.length for e in g.edges]),
        n_nodes=g.n_nodes,
    )


def main():
    print("usable_route by seed ceiling (mean over seeds)\n")
    print(f"{'kmax':>6} " + " ".join(f"{s:>7}" for s in SEEDS) + f" {'mean':>8} {'nodes':>7} {'comps':>6}")
    for kmax in CEILINGS:
        orig = hybrid.adaptive_seeds.__defaults__
        hybrid.adaptive_seeds.__defaults__ = (12, kmax)
        vals, nodes, comps = [], [], []
        for s in SEEDS:
            gt, tr = generate_dataset(seed=s)
            g = hybrid.build_graph(tr, build_version=1)
            r = spurious_route_rate(wrap(g), gt, tr)
            vals.append(r["usable_route_rate"])
            nodes.append(g.n_nodes)
            comps.append(g.stats["components"])
        print(f"{kmax:>6} " + " ".join(f"{v:>7.3f}" for v in vals)
              + f" {np.mean(vals):>8.3f} {int(np.mean(nodes)):>7} {max(comps):>6}")
        hybrid.adaptive_seeds.__defaults__ = orig

    print("\nM0 spine reference: ~1200 nodes, usable_route ~0.67")
    print("naive baseline:    ~580 nodes, usable_route ~0.04")


if __name__ == "__main__":
    main()