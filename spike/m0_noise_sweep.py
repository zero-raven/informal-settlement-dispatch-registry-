"""
M0 extension — GPS-noise sensitivity sweep.

The 6-seed sweep varied the noise SEED but held the noise DISTRIBUTION fixed.
This asks the harder question: does the algorithm ranking hold across the full
realistic range of GPS error, from consumer-phone quality to genuinely bad
reception?

For each sigma in {1, 2, 4, 6, 8, 10, 12} m, every mapper gets the SAME
sigma (isolating the variable), averaged over several seeds. Also sweeps drift
and dropout independently.

The question that matters: does the M0 verdict (kmeans_delaunay fails, map-
matching family leads) survive, or was it an artefact of one noise regime?
"""
from __future__ import annotations

import json
import statistics
import sys

from m0_algorithms import BUILDERS
from m0_evaluate import evaluate_all
from m0_ground_truth import generate_dataset

SIGMAS = [1, 2, 4, 6, 8, 10, 12]
DRIFTS = [0.0, 1.0, 2.5]
DROPOUTS = [0.0, 0.05, 0.12]
SEEDS = [7, 13, 21]


def run_case(gen_kwargs, seeds=SEEDS):
    per = {n: {"f1": [], "usable_route_rate": [], "dest_reach": [],
               "precision": [], "spurious_route_rate": [], "edges": [],
               "routing_success": [], "build_seconds": []}
           for n in BUILDERS}
    for s in seeds:
        gt, traces = generate_dataset(seed=s, **gen_kwargs)
        if len(traces) < 4:
            continue
        res = evaluate_all(traces, gt)
        for name, r in res.items():
            if "error" in r:
                continue
            for k in per[name]:
                v = r.get(k)
                if isinstance(v, (int, float)):
                    per[name][k].append(float(v))
    return per


def show(title, per):
    print(f"\n### {title}")
    hdr = f"{'algorithm':<18}" + "".join(
        f"{h:>10}" for h in ("F1", "prec", "usable", "spur", "dest", "edges")
    )
    print(hdr)
    print("-" * len(hdr))
    for n, m in per.items():
        def mean(k):
            v = m[k]
            return round(statistics.mean(v), 3) if v else None
        print(
            f"{n:<18}"
            + "".join(
                f"{str(mean(k)):>10}"
                for k in ("f1", "precision", "usable_route_rate",
                          "spurious_route_rate", "dest_reach", "edges")
            )
        )


def main():
    print("M0 extension — GPS noise sensitivity")
    print(f"seeds per point: {SEEDS}")

    sigma_results = {}
    for s in SIGMAS:
        per = run_case({"sigma_range": (s, s), "drift_range": (0.0, 0.0)})
        show(f"sigma = {s} m (constant, no drift)", per)
        sigma_results[s] = {
            n: {k: (round(statistics.mean(v), 4) if v else None)
                for k, v in m.items()}
            for n, m in per.items()
        }

    drift_results = {}
    for d in DRIFTS:
        per = run_case({"sigma_range": (3.0, 3.0), "drift_range": (d, d)})
        show(f"drift = {d} m (constant sigma 3 m)", per)
        drift_results[d] = {
            n: {k: (round(statistics.mean(v), 4) if v else None)
                for k, v in m.items()}
            for n, m in per.items()
        }

    dropout_results = {}
    for dp in DROPOUTS:
        per = run_case({"sigma_range": (3.0, 3.0), "drift_range": (0.0, 0.0),
                        "dropout": dp})
        show(f"dropout = {dp:.0%} (constant sigma 3 m)", per)
        dropout_results[dp] = {
            n: {k: (round(statistics.mean(v), 4) if v else None)
                for k, v in m.items()}
            for n, m in per.items()
        }

    # ---- verdict stability -------------------------------------------------
    print("\n=== verdict stability across sigma ===")
    leader_by_sigma = {}
    for s, res in sigma_results.items():
        ranked = sorted(
            res.items(), key=lambda kv: -(kv[1]["usable_route_rate"] or 0)
        )
        leader_by_sigma[s] = ranked[0][0]
        km = res.get("kmeans_delaunay", {})
        sm = res.get("spline_mapmatch", {})
        base = res.get("nearest_neighbor", {})
        print(
            f"  sigma={s:>2}m  leader={ranked[0][0]:<18}"
            f"  kmeans_usable={km.get('usable_route_rate')}"
            f"  spline_usable={sm.get('usable_route_rate')}"
            f"  base_usable={base.get('usable_route_rate')}"
        )

    leaders = set(leader_by_sigma.values())
    print(f"\n  distinct leaders across sigma: {leaders or 'n/a'}")

    # Does kmeans ever beat the map-matching family?
    km_beats_spline = [
        s for s in SIGMAS
        if (sigma_results[s]["kmeans_delaunay"]["usable_route_rate"] or 0)
        > (sigma_results[s]["spline_mapmatch"]["usable_route_rate"] or 0)
    ]
    print(f"  sigma where kmeans beats spline: {km_beats_spline or 'never'}")

    with open("m0_noise_sweep.json", "w") as fh:
        json.dump(
            {
                "seeds": SEEDS,
                "sigmas": sigma_results,
                "drifts": drift_results,
                "dropouts": dropout_results,
                "leader_by_sigma": leader_by_sigma,
                "kmeans_beats_spline_at": km_beats_spline,
            },
            fh,
            indent=2,
        )
    print("\nwrote m0_noise_sweep.json")


if __name__ == "__main__":
    main()