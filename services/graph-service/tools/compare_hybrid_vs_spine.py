"""Compare the production hybrid against the M0 spine that led it.

The hybrid is not expected to match the spine exactly: the spine snaps to raw
GPS points (3135 nodes), while the hybrid snaps to adaptive density seeds
(87 nodes). Fewer, cleaner nodes should mean fewer spurious edges, but it can
also mean coarser geometry. This script measures whether that trade holds.
"""

import sys
import os
from types import SimpleNamespace

import numpy as np

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
sys.path[:0] = [
    os.path.join(REPO, "spike"),
    os.path.join(REPO, "services", "graph-service", "src"),
]

from m0_ground_truth import generate_dataset            # noqa: E402
from m0_algorithms import build_spline_mapmatch        # noqa: E402
from m0_evaluate import spurious_route_rate            # noqa: E402
from hybrid import build_graph                         # noqa: E402

SEEDS = [7, 13, 21, 34, 55, 89]


def main():
    print(f"{'seed':>5} {'spine_usable':>13} {'hybrid_usable':>14} "
          f"{'spine_nodes':>12} {'hyb_nodes':>10} {'spine_spur':>11} {'hyb_spur':>9}")
    wins = ties = losses = 0
    for s in SEEDS:
        gt, tr = generate_dataset(seed=s)
        spine = build_spline_mapmatch(tr)
        hyb = build_graph(tr, build_version=1)

        spine_res = spurious_route_rate(spine, gt, tr)
        su = spine_res["usable_route_rate"]
        # score the hybrid with the spike's own metric by wrapping its Edge
        # objects into the shape the spike scorer expects
        a = SimpleNamespace(
            node_xy=hyb.node_xy,
            edges=[(e.a, e.b) for e in hyb.edges],
            edge_len=np.array([e.length for e in hyb.edges]),
            n_nodes=hyb.n_nodes,
        )
        hr = spurious_route_rate(a, gt, tr)

        hu = hr["usable_route_rate"]
        if hu > su:
            wins += 1
        elif hu == su:
            ties += 1
        else:
            losses += 1

        print(f"{s:>5} {su:>13.3f} {hr['usable_route_rate']:>14.3f} "
              f"{spine.n_nodes:>12} {hyb.n_nodes:>10} "
              f"{spine_res['spurious_route_rate']:>11.3f} "
              f"{hr['spurious_route_rate']:>9.3f}")

    print(f"\nhybrid vs spine: {wins} better, {ties} equal, {losses} worse")
    print("\nInterpretation:")
    print("  fewer nodes is the POINT: the spine emits one node per quantised GPS")
    print("  point, which is why it scores well on usable_route — it hugs the")
    print("  noisy trace. The hybrid trades that for a graph a mapper can actually")
    print("  review and correct. Usable-route is therefore expected to be lower;")
    print("  the question is whether it stays well above the naive baseline (0.036).")


if __name__ == "__main__":
    main()