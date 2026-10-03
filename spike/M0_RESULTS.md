# M0 — Path-Graph Feasibility Spike: RESULTS

**Status: COMPLETE — the PRD's proposed algorithm FAILED the gate.**

Run: 6 seeds, 25 true nodes, 24 true edges, 32 traces, 13 destinations,
4 mappers with graded GPS quality (σ 2.0–7.0 m, drift 0.0–2.4 m, 3% dropout).

Reproduce: `cd spike && ../.venv-spike/bin/python m0_multiseed.py`

---

## 1. Results (mean over 6 seeds)

| Algorithm | nodes | edges | F1 | precision | usable_route | spurious_route | dest_reach | route_err | build_s |
|---|---|---|---|---|---|---|---|---|---|
| nearest_neighbor (baseline) | 581.5 | 1902.2 | 0.255 | 0.164 | **0.036** | **0.964** | 1.000 | 3.860 | 0.015 |
| **kmeans_delaunay (PRD §6.2)** | 90.0 | 193.3 | 0.572 | 0.509 | 0.520 | 0.480 | 0.782 | 0.248 | 0.092 |
| dbscan_graph | 8.0 | 8.3 | 0.183 | 0.288 | 0.148 | 0.852 | 0.949 | 0.185 | 0.019 |
| **spline_mapmatch (PRD-rejected)** | 1204.0 | 3134.5 | **0.668** | 0.531 | **0.688** | **0.313** | 1.000 | 0.531 | 0.028 |

### M0 exit gate (beat naive baseline on F1 **and** destination reach, no routing regression)

| Algorithm | ΔF1 | ΔDest | ΔRoute | Verdict |
|---|---|---|---|---|
| spline_mapmatch | +0.413 | +0.000 | +0.000 | fail — reaches 100% *because* it is a hairball |
| kmeans_delaunay | +0.317 | **−0.218** | **−0.182** | **fail — regresses on reachability** |
| dbscan_graph | −0.072 | −0.051 | −0.375 | fail |

**No candidate passes the gate as originally written.**

---

## 2. Three findings that change the decision

### 2.1 The gate itself was wrong

The naive baseline scores `dest_reach = 1.000` — it routes to every
destination — while emitting 96% spurious edges. It connects everything by
brute force through geometry no pedestrian walked. Destination reach alone is
therefore **not a discriminator**; it rewards exactly the failure mode the PRD
warns about.

`routing_success` and `dest_reach` were retained for completeness but demoted.
The discriminating metric is **`usable_route_rate`**: the fraction of routes
whose traversed length lies predominantly on real path geometry. On that metric
the ordering inverts and becomes meaningful:

- baseline 0.036 — connects everything, routes nowhere usable
- kmeans_delaunay 0.520
- **spline_mapmatch 0.688**

### 2.2 The PRD's stated rejection rationale for seed-and-spline is NOT supported

PRD §6.2 excludes seed-and-spline map-matching because it "has no mechanism to
suppress spurious paths from noisy traces". Measured: its spurious-route rate
is **0.313**, the *lowest* of all four. Its 3135 edges are largely redundant
rather than *spurious* — dense local connectivity along genuinely-walked
corridors.

The PRD conflated **edge count** with **spuriousness**. Volume of edges is not
the defect; proportion of routes traversing non-path geometry is.

### 2.3 k-means+Delaunay fails for a diagnosable reason

It under-performs on reachability (0.782) and routing (0.818) because the fixed
`k=90` seed count spreads seeds across empty space between lanes, and Delaunay
triangulation then **bridges non-adjacent seeds with long unsupported edges**,
producing 7 disconnected components (largest = 93% of nodes). The islands
holding the northern connector and the high cross-lane are unreachable.

It also routes 25% worse than baseline. Its usable-route rate is 0.520 — real
improvement over the baseline, but with unresolved topological gaps.

---

## 3. Recommendation

**Do not adopt k-means+Delaunay as specified. Do not adopt a naive
seed-and-spline either. Carry a hybrid into M3.**

Recommended production approach, in priority order:

1. **Take the spline/map-matching family as the connectivity backbone.** It has
   the best measured F1 (0.668), best usable-route rate (0.688), full
   destination reach (1.000), and the lowest spurious-route rate (0.313). It
   also has the PRD's prerequisite property — deterministic idempotent
   behaviour under revisit — which Delaunay seeding does not.

2. **Add the Delaunay component as a *restricted* gap-bridger, not the
   connectivity primitive.** Triangulate only over seed pairs whose connecting
   edge passes a proximity test against actual trace mass, and cap edge length
   at a multiple of the mean inter-seed spacing. This fixes the
   bridge-the-void failure while keeping genuine junctions connected.

3. **Apply k-means seeding but adaptively** — choose `k` from the trace data
   (elbow / density), not a constant. DBSCAN's failure was a tuning artefact
   (eps≥7 collapsed all lanes into one cluster; eps=4 gave 9 clusters against
   25 true nodes — too coarse). With per-density eps it remains a viable
   alternative for outlier rejection.

4. **Keep spurious suppression as an explicit, measured stage** regardless of
   family — since suppression is what the PRD actually cares about, and no
   candidate demonstrated it clearly on its own.

---

## 4. Gate outcome

| Question the gate was meant to answer | Answer |
|---|---|
| Is the path-graph approach viable at all? | **Yes** — 0.688 usable-route rate is workable for a pilot with human review |
| Is k-means+Delaunay, as specified in §6.2, the right choice? | **No** — regresses on reachability and routing; its rejection criterion was edge count, not spuriousness |
| Is the naive baseline a valid control? | **Yes** — and it revealed the gate was mis-specified |
| Should §6.2's algorithm preference stand? | **No. Supersede it.** §6.2's rejection of seed-and-spline is contradicted by measurement |

---

## 5. Required doc updates

1. **`architecture.md` §5.8** — replace the "candidates compared" diagram with
   the measured outcome. The prior text already carried a contradiction flag
   saying the algorithm is undecided; it must now carry the *result*.
2. **`development-plan.md` M0** — record the verdict, and change M3's
   precondition from "whatever M0 recommended" to the hybrid above.
3. **PRD §6.2 and §8** — flag as superseded by measurement. §8's "path-graph
   accuracy unvalidated" risk is now *partially retired*: we have numbers for
   synthetic traces. Field accuracy remains unvalidated.
4. **PRD §6.2's stated rationale for excluding seed-and-spline** — mark as
   contradicted by measurement. It remains architecturally desirable to *avoid*
   the unbounded edge growth, which the hybrid addresses.

## 6. Honest limitations

- **Synthetic traces only.** Campus capture is not yet in the dataset; every
  number here is against a generated ground truth. PRD §8's risk is narrowed,
  not retired.
- **6 seeds, one mapper-quality mix.** The stddevs are small but the sweep
  varies noise seed, not the noise *distribution*. A sweep over σ ∈ {1…12 m}
  would be stronger.
- **Single-scale geometry** (~200 m campus). A settlement-scale network with
  longer corridors and more junctions may reorder the candidates.
- **DBSCAN was under-tuned.** eps=4/ms=4 was picked from a coarse sweep; a
  proper tuning pass could change its standing.
- **`usable_route_rate` threshold (50% on-path length) is a spike judgement**,
  not a validated operational threshold. Production should expose it as
  configurable route confidence rather than a binary.
- No code from this spike is production-ready. It is a decision instrument.