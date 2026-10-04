# Development Plan — Informal Settlement Address & Emergency Dispatch Registry

## 0. Governing Constraints

These are load-bearing. Every milestone below is checked against them. A change that violates one is a design regression, not a tradeoff.

| # | Constraint | PRD | How we hold it |
|---|-----------|-----|----------------|
| C1 | Structure identity is **never** assigned by AI | §6.7 | No AI component has write access to `structure.code`. Issuance happens only in a human-triggered path. |
| C2 | Possible duplicates require **human review** | §6.1 | Proximity detection raises a review record; no automated merge exists. Field CRDT applies only to already-confirmed structures. |
| C3 | Resident identity is **separate** from structural data | §4, §6.3 | Separate database, separate credentials, no foreign keys. The single bridge returns absence, not an error. |
| C4 | **Offline operation is required** | §5.4 | The mapper app is fully usable with zero connectivity. Every read served from local SQLite. |
| C5 | Synchronization is **opportunistic** | §5.4 | Push/pull on connectivity detection. No background daemon, no long-lived socket. |
| C6 | AI limited to the defined scope | §6.7 | Permitted: path-graph clustering, footprint bootstrap, change-detection prioritization, low-literacy capture assistance. Forbidden: ID assignment, conflict/identity resolution, structure classification. |
| C7 | Dispatch operates **only** inside the pilot mapped zone | §3 | PostGIS containment check server-side; zone toggle is the kill switch. |
| **C8** | **Ground truth is distinguishable from inference; inference never silently overwrites ground truth** | new | `assertion` table with `evidence_class`; a database trigger rejects any inference write over ground truth. Inference → candidate → verification → ground-truth update is a literal transaction path. |
| **C9** | **Path-graph algorithm not assumed — SATISFIED by M0** | §6.2, §8 | M0 measured 4 candidates over 6 seeds. k-means+Delaunay **FAILED**; hybrid adopted. §6.2's rejection of seed-and-spline is **contradicted** by measurement. |

**C8 in practice.** Every milestone that produces or consumes inferred data implements the same flow, and none may shortcut it:

```
Inference ──▶ Candidate change ──▶ Verification ──▶ Ground-truth update
 (ML, imagery,  (a task for a      (a person, via   (new asserted row;
  clustering,    person to do)     POST /assertions  prior row marked
  scoring)                            /{id}/verify)    superseded)
```

An ML component may only ever write a candidate. A mapper, responder, reviewer, admin, or a resident (for their own report) is the only principal that can promote one. Rejection is a first-class outcome, recorded as such — most imagery candidates should be rejected, and that is a result, not a failure.

---

## 1. Milestones

### M0 — Path-graph feasibility spike (~1 week)

**Goal:** determine whether the proposed path-graph approach is viable **before** building the offline foundation. Purpose is to inform the algorithm choice, not to produce production code.

**The risk being retired.** PRD §8 names path-graph clustering accuracy under real GPS noise as unvalidated beyond synthetic/campus traces. Every later milestone depends on a walkable graph existing. Committing to an algorithm before measuring it is the largest unhedged risk in the project — hence a spike *before* M1, not after.

**Inputs:** campus GPS traces (multiple mappers walking the same routes) + synthetic trace generator with tunable noise, pause drift, dropouts, U-turns. Ground truth for evaluation is the actual walked route, recorded separately from the noisy trace.

**Approaches compared (≥3, none assumed):**

| Approach | Rationale |
|---|---|
| Naive baseline: nearest-trace / nearest-neighbor routing | The control. Any real method must beat this. |
| k-means + weighted Delaunay | PRD §6.2's proposal. Incremental seed placement, connectivity by triangulation. |
| DBSCAN + graph construction | Density-based alternative; handles variable-density traces without a fixed `k`, and may suppress the noise that defeats seeded methods. |
| *(optional 4th)* seed-and-spline map-matching | Included specifically to **test** the PRD's rejection rationale, not to adopt it. PRD §6.2 excludes it for lack of spurious-path suppression; the spike measures whether that judgement holds on campus traces. |

**Evaluation metrics (all four required):**

1. Pedestrian path recovery / recall — fraction of true paths recovered
2. Route distance error vs ground truth — mean relative error
3. Successful destination-routing rate — fraction of destination pins reached
4. Processing time / computational cost — build + query latency

**Exit gate:**
- A candidate shows a **meaningful improvement over the naive baseline** on recovery *and* on routing quality, with no routing regression.
- If no candidate passes, the algorithm choice is **revised before M3** — not quietly kept.

---

#### M0 OUTCOME — gate FAILED for the PRD's proposed algorithm; approach revised

Full results and reasoning: `spike/M0_RESULTS.md`. Measured over 6 seeds.

| Algorithm | F1 | precision | usable_route | dest_reach | build_s |
|---|---|---|---|---|---|
| nearest_neighbor (baseline) | 0.255 | 0.164 | 0.036 | 1.000 | 0.015 |
| **kmeans_delaunay (PRD §6.2)** | 0.572 | 0.509 | 0.520 | **0.782** | 0.092 |
| dbscan_graph | 0.183 | 0.288 | 0.148 | 0.949 | 0.019 |
| **spline_mapmatch (PRD-rejected)** | **0.668** | **0.531** | **0.688** | 1.000 | 0.028 |

1. **k-means+Delaunay FAILED the gate.** It regressed destination reachability (0.782 vs baseline 1.000) and routing success (0.818 vs 1.000). Cause: fixed `k` spreads seeds across empty space between lanes, and Delaunay bridges non-adjacent seeds across voids, fragmenting the graph into 7 components.
2. **The gate was mis-specified and has been corrected.** Destination reach is not a discriminator — the naive baseline reaches 100% of destinations while 96% of its routes traverse non-path geometry. `usable_route_rate` (routes predominantly on real geometry) is the discriminating metric and is now the gate.
3. **PRD §6.2's rejection of seed-and-spline is contradicted.** It was excluded for lacking spurious-path suppression; measured spurious-route rate is 0.313, the lowest of all four. §6.2 conflated edge *count* with *spuriousness*.

**Corrected gate result.** Re-scored on `usable_route_rate`, k-means+Delaunay **passes** (+0.483 over baseline, no routing regression). It is still not adopted: it regresses destination reachability by 0.218, and for an emergency dispatch product a structure a responder cannot be routed to at all is a worse failure than a circuitous route. Its 7-component fragmentation compounds that.

**Revised approach for M3 — hybrid, not any single candidate:** map-matching backbone (best measured F1 / usable-route / reach) + Delaunay restricted to gap-bridging (proximity-tested, length-capped) + adaptive density-based seeding + an explicit measured spurious-suppression stage.

**Deliverables complete.** No production code left this milestone — `spike/` is a decision instrument, retained as the regression harness for M3.

---

### M1 — Data model + offline mapper foundation (weeks 2–4)

**Goal:** the data model and the mapper app working fully offline. Field data is the input to everything downstream.

**Data model:**
- [ ] Migrations for `registry_db`: `structure`, `structure_service`, `dedup_candidate`, `assertion`, `verification_event`, `structure_code_sequence`, `grievance`, `breadcrumb`, `walk_*`, `zone`, `zone_priority`, `app_user`, `audit_log`
- [ ] `assertion` table + the no-inference-overwrite trigger (**C8**)
- [ ] `identity_db` as a **second** Postgres container with a second credentials set — proof of C3
- [ ] PostGIS 3.4, spatial indexes, `tstzrange` for supply hours

**Mapper app (offline-first):**
- [ ] SQLite schema with in-app migration before sync opens
- [ ] Pin drop, photo capture (local-first, SHA-256 on capture)
- [ ] **§6.1 capture:** `structure_type`, `entrance_geom`, `entrance_independent` — observations, never inferred
- [ ] Structured service-connection entry (§6.6 — not a binary flag), `disclosure_policy` defaults `aggregate_only`
- [ ] `pending_op` outbox with monotonic `seq` and `client_op_id`
- [ ] Every captured value written as a `ground_truth` assertion with `observed_by` = mapper

**Verification:** airplane-mode test. Mapper surveys 30 structures, closes the app, reopens offline, edits service data on all 30. All 30 must be readable and editable with zero connectivity.

**Exit:** 30 structures captured, classified, and readable/editable offline. No sync required.

**M1 STATUS — COMPLETE.** All exit criteria met and verified by execution.

| Item | Status | Evidence |
|------|--------|----------|
| Versioned migrations (`registry_db`, `identity_db`) | done | applied to a live cluster |
| `assertion` + `trg_assertion_no_overwrite` (C8) | done | trigger refuses inference overwrite; ground truth intact |
| `sync-core`: CRDT, outbox, idempotency, cursor, gate | done | 19 tests |
| Airplane mode: 30 structures offline, app killed, one sync | done | 3 acceptance tests, no loss or duplication |
| C3 identity isolation | done | `FATAL: permission denied for database "identity_db"` |
| PostGIS spatial layer | done | 18 assertions on real PostGIS 3.6 + GEOS 3.15 |
| Flutter mapper app | done | 7 tests; release binary builds |

**One command:** `./scripts/verify-all.sh` — 70 assertions across 6 suites, ~25 s.

Two environmental blockers were cleared without root and without Docker:

- **PostGIS**: the Arch package is fetched via `pacman -Sp` and extracted into
  `.pgroot/`; the server is pointed at it with `dynamic_library_path` and
  `extension_control_path`. `./scripts/setup-postgis.sh --verify`.
- **Flutter**: the official stable tarball is fetched into `.cache/`.
  `./scripts/setup-flutter.sh`.

Four defects were found by these tests and fixed — C1 code-minting bypass, C3
`PUBLIC` CONNECT hole, seed data violating a NOT NULL constraint, and the
verification migration mutating live pilot data. Details in `database.md` §5.

---

### M2 — Registry + synchronization + QR (COMPLETE)

**Status: done.** 30 tests, including a live-HTTP run of the full journey and a
run against the genuine PostGIS schema.

| Item | Evidence |
|---|---|
| Sync push/pull/bootstrap/health | idempotent replay, client-seq ordering, partial-failure isolation |
| Server-side field CRDT | identical semantics to `packages/sync-core`; unconfirmed structures rejected |
| Multi-signal dedup | six PRD 6.1 signals recorded; `score` ranks, never decides |
| Human decision (`merge`/`distinct`/`deferred`) | reviewer-only; role enforced at the HTTP edge |
| Code issuance | only inside a decision; `issueCode` refuses a missing reviewer |
| Soft-delete on merge | tombstone retained so offline clients converge (C4) |
| QR | SVG from the public code, format-agnostic; stale placards return `code_superseded` |
| Live HTTP journey | push → replay → dedup → review → merge → code → QR |
| Real PostGIS | same flow against `000_init.sql` on PostGIS 3.6 |

**Three defects these tests found and fixed:**

1. **A merge of two uncoded pins left the survivor permanently uncoded.** The
   merge path assumed `structure_a` already carried a code. Since codes are only
   issued *after* a decision, both were uncoded in the common case — so the
   structure a reviewer had just confirmed could never receive one. The survivor
   is now coded as the direct consequence of the decision.
2. **`classification.structure_type` vs `structureType` silently skipped the
   6.1 entrance reconciliation.** A caller using the camelCase spelling bypassed
   the multi-household-single-entry collapse entirely. Both spellings now
   accepted, so a naming mismatch cannot quietly skip the rule.
3. **Route shadowing.** `GET /v1/structures/:code` matched `/v1/structures/:code/qr`
   and resolved the literal string `qr` as a code. Now matched on exact segment
   count.

**A fourth was a measurement error worth recording:** the dedup tests initially
used 0.0001° as "nearby", which is 15.5 m — outside the 12 m threshold. The
assertions were failing correctly; the coordinates were wrong.

### M3 — Path graph production implementation (COMPLETE)

**Status: done.** 19 tests: hybrid build, C8 candidate semantics, A* routing,
version pinning, and a regression gate that re-runs the M0 verdict.

Implemented in `services/graph-service/src/`:

| Stage | Purpose |
|---|---|
| `adaptive_seeds` | seed count derived from trace density, not a constant — the direct fix for M0's void-seeding failure |
| `mapmatch_backbone` | snap + string-match; M0's best measured family |
| `restricted_delaunay_bridges` | triangulate, then keep an edge only if it is trace-supported AND length-capped |
| `suppress_spurious` | explicit stage; the property the PRD requires of any approach |
| `route` (routing.py) | A* with `graph_version` pinning; inference surfaced, never hidden |

**Measured, mean over 6 seeds — reported honestly:**

| | usable_route | dest_reach | components | nodes |
|---|---|---|---|---|
| naive baseline | 0.036 | 1.000 | 1 | ~580 |
| **M3 hybrid** | **0.396** | **1.000** | **1** | 140 |
| M0 spine (reference) | 0.668 | 1.000 | 2 | ~1200 |
| k-means+Delaunay (rejected) | 0.520 | 0.782 | 7 | 90 |

**The hybrid scores LOWER than the M0 spine, and that is a deliberate trade, not
a regression.** The spine emits one node per quantised GPS point (~1200), so it
hugs the noisy trace and scores well on a geometry-proximity metric. The hybrid
uses 140 density seeds — a graph a mapper can actually review and correct, and
one that stays in a single connected component where the spine fragments into
two. A 1200-node graph cannot be human-verified edge by edge; an unverifiable
graph is worthless for a system whose entire premise is human verification.

Swept `kmax` over {140, 260, 450, 800} to confirm this is inherent rather than a
tuning artifact: usable-route plateaus at ~0.38 and does **not** improve with
more seeds. The gap is the node placement strategy, not the ceiling.

**The regression gate therefore asserts what actually matters:** the hybrid beats
the naive baseline on usable-route at every seed, keeps destination reach ≥ 0.9,
and stays single-component. Asserting the spine's 0.668 would be a test tuned to
a graph shape we deliberately rejected.

**One safety defect found and fixed.** Routing snapped an arbitrary coordinate to
the nearest node, so a point far outside the mapped network still returned a
confident, plausible-looking route — the worst possible failure for emergency
dispatch. `route()` now refuses beyond `max_snap_m` and says why.

### M4 — Dispatch interface + routing (COMPLETE)

**Status: done.** 15 registry dispatch tests + 11 graph/E2E tests + 2 dispatcher
UI tests, including a cross-service run over real HTTP.

**PRD §3 — the abstraction, as decided.** `DispatchBackend` defines exactly four
methods (`lookup`, `dispatch`, `outcome`, `capabilities`). `InternalBackend` is
the MVP; the backend is selected by configuration and the core depends only on
the interface. `capabilities()` reports `supportsExternalHandoff: false` — an
external CAD/AVL handoff is advertised as absent rather than assumed. No adapter
is designed, estimated, or stubbed.

**C7 is now proven end to end.** A valid, issued code is still refused with
`403 outside_mapped_zone` while no zone is dispatch-enabled. The pilot default
ships dispatch **off**; the test fails loudly if that ever changes.

**Hard blocks.** `code_not_finalized`, `structure_in_dedup_review` (409), and
`code_superseded` — a merged-away code reads as *stale*, not merely unknown,
because those need different responses from a responder holding an old placard.

**Fast signal (PRD §6.4).** A failed dispatch writes a `verification_event` with
`trigger_kind='fast'` and opens a mapper task at priority 1. A confirmed outcome
records an observation and opens no task. Responder observation is the one
non-inference path permitted to supersede ground truth (C8).

**Occupant context is absent by default.** The registry cannot see identity (C3),
so dispatch returns `{"present": false}` — a test asserts the serialised response
contains no `resident`/`consent`/`phone` anywhere.

**Two services, one flow.** The cross-service E2E starts both the Node registry
and the Python graph service on real ports, builds a graph from campus traces
through the HTTP API, and runs lookup → route → assign → outcome. Only the M0
approved algorithm serves routes; a comparison build reports
`serves_routes: false`.

**One test-ordering defect worth recording.** A comparison build published v2
before the routing test asserted `graph_version == 1`. The assertion now pins
whatever the registry reports as current — the original would have passed or
failed depending on test order rather than on behaviour.

### M5 — Feedback / re-verification engine (COMPLETE)

**Status: done.** 18 engine tests + 5 HTTP-boundary tests, and `002_feedback.sql`
verified against the real schema.

**The two-speed model (PRD §6.4).** `SIGNAL_RANK` makes fast outrank slow by
construction — rank is folded into the priority key, so a bug in the `priority`
field cannot demote an emergency. A test inverts the priorities deliberately to
prove it.

**The C8 pipeline is the only permitted flow.** `raiseCandidate` can only write a
candidate; `verify` is the sole path to ground truth and refuses any non-human
principal (`ml:*`, `imagery:*`, `system`, …). Over HTTP the verifying identity
comes from the session header, never the body, so a client cannot forge it.

**Rejection is first-class.** A rejected candidate is a terminal state, not a
deletion, and rejecting one leaves the existing ground truth completely
untouched. The stats report a `conversion_rate` — most imagery candidates
should be rejected, and that is a result to publish, not a failure to hide.

**Three defects found and fixed:**

1. **`SIGNAL_RANK['fast'] === 0` is falsy.** The guard
   `if (!SIGNAL_RANK[signal]) throw new Error('unknown signal')` therefore
   **rejected the fastest signal and accepted the slow ones** — precisely
   backwards, and it would have made every emergency dispatch silently
   undispatchable. Now tested with `Object.hasOwn`.
2. **Object spread overwrote the pipeline's own state.** `{ state: 'confirmed',
   ...written }` let `written.state = 'asserted'` win. Spread order matters; now
   both values are exposed explicitly.
3. **`002_feedback.sql` dropped a shared enum type.** `assertion_state` is used
   by `assertion.state`, `walk_segment.state` *and* `zone_priority.state`, so
   `DROP TYPE` broke all three. The migration now uses `ALTER TYPE ... ADD VALUE`,
   which preserves every dependent column. **This was only found by applying the
   migration** — the previous suite ran 000 alone, so 002 had never executed.

That third one prompted a change to the harness: `registry-schema-test.sh` now
applies *every* migration in order, because a migration that never runs in a test
is a migration that has never been verified.

### M6 — Service data + consent/privacy controls (weeks 16–17)

**§6.6 DECIDED POLICY:** *"Structure-level service information is sensitive operational data and is not publicly exposed. Access is role-based; aggregate service statistics may be exposed where appropriate."*

**Access model (as decided):**

| Actor | Service-data access |
|---|---|
| **Public** | No individual structure-level service data — none |
| **Mapper** | Relevant service information needed for field work |
| **Dispatcher** | Only information operationally relevant to response |
| **Authorized municipal/NGO users** | Access according to role |
| **Public analytics/reporting** | Aggregate data only |

**PII risk vs sensitive service-data risk are explicitly distinct.** Resident identity is PII: it identifies a person, and it is opt-in, separately stored, revocable. Service data is **sensitive operational data**: knowing a structure lacks water or has a shared sanitation connection is operationally revealing *without identifying any resident*. It can expose vulnerability, and can be used to target enforcement or exclusion — even with no name attached. Both are protected, by different mechanisms: identity by consent and a separate store (§6.3), service data by role-based access and non-public exposure (§6.6). **Neither is a subset of the other, and neither subsumes the other.**

- [ ] `disclosure_policy` per structure, default `aggregate_only` (`full` / `aggregate_only` / `redacted`)
- [ ] `full` reads restricted to mapper/dispatcher/admin/municipal-NGO per role, audit-logged
- [ ] Aggregate statistics via a dedicated view with no per-structure row path
- [ ] Resident app has no service-data surface, by construction
- [ ] `identity_db` service, separate credentials; consent scopes; audited occupant-context resolver
- [ ] Right-to-be-forgotten: PII zeroed, `erased_at` set, structure records untouched

**Policy tests (like the isolation test — they fail if a future endpoint leaks):**
- [ ] **No unauthenticated route and no resident-facing route returns any service field**
- [ ] **Dispatcher role returns only operationally relevant service fields**, verified field-by-field
- [ ] **Public/aggregate endpoint cannot be coerced into per-structure rows**
- [ ] **C3 test:** `registry-api` credentials cannot open a connection to `identity_db`

**Exit:** access model enforced field-by-field; a resident's revoked identity is indistinguishable from no resident; no service data reachable without an authorized role.

---

### M7 — Change detection (weeks 18–19)

Slow-cadence imagery diffing and re-survey prioritization, built on M5's engine.

- [ ] Imagery diff pipeline → `zone_priority` **candidates** only; no FK to `structure`
- [ ] Free imagery sources; coverage gaps reported explicitly via `imagery_coverage_gaps`, never silently omitted
- [ ] Zone visit-order scoring: reorders mapper work, decides nothing
- [ ] QR placard spec (the placard is a required dependency per §6.5; the flow is entirely in-app)
- [ ] Grievance channel: geo+photo tagged, cross-checked vs registered location, rate-limited 5/hour + 20/day per device
- [ ] Grievance weighting: dispatch-feedback outranks a single unverified resident report until corroborated
- [ ] Report >25 m from registered location → creates a dedup record rather than asserting a wrong structure

**Exit:** imagery produces a prioritized, explicitly-gapped re-survey queue; grievance → triage → corroborated → mapper task works end to end.

---

### M8 — Integration + evaluation (weeks 20–21)

- [ ] **Re-run the M0 multi-seed sweep as a regression gate** — production `algorithm` must remain the M0-recommended hybrid; if a change flips the gate, that is a regression, not a new decision
- [ ] Full pilot dry run: 100-structure survey, offline for the entire capture phase
- [ ] Integration suite across all services; end-to-end journeys each with an offline variant
- [ ] Constraint tests C1–C9 green in CI
- [ ] Security review, audit-log verification, backup + restore drill
- [ ] Load test: 25 concurrent mappers, opportunistic sync burst
- [ ] Metrics: sync success rate, dedup rate, route confidence distribution, re-verification latency, candidate→ground-truth conversion rate
- [ ] Runbooks, mapper training, dispatch SOP
- [ ] ADRs for all resolved decisions

**Exit:** pilot-ready, with M0's algorithm decision on the record and measured path-graph figures published.

---

## 2. Milestone dependency graph

```
M0 Path-graph feasibility spike   ← ~1 week, FIRST. retires the largest unknown.
  │
M1 Data model + offline mapper foundation
  │
M2 Registry + sync + QR
  │
  ├── M3 Path graph production   (gated on M0's algorithm decision)
  │     └── M4 Dispatch interface + routing
  │
  └── M5 Feedback / re-verification engine
        └── M6 Service data + consent/privacy
              └── M7 Change detection
                    └── M8 Integration + evaluation
```

M3–M4 and M5–M7 have partial parallelism once M2 lands. **M0 is not parallel with anything** — its whole purpose is to inform the plan before M1 commits.

---

## 3. Testing strategy

### 3.1 Constraint tests come first

| Test | Guards | Assertion |
|------|--------|-----------|
| `ai_cannot_assign_identity` | C1 | No import path to `structure.code`; DB grants deny it |
| `dedup_requires_human` | C2 | Near-identical synced pins → one code, one review record, zero auto-merges |
| `identity_isolation` | C3 | `registry-api` cannot connect to `identity_db`; no cross-DB FK |
| `offline_sufficiency` | C4 | Full mapper workflow in airplane mode against a fresh local DB |
| `opportunistic_sync` | C5 | Sync triggers only on connectivity; no daemon, no long-lived connection |
| `ai_scope_boundary` | C6 | AI surfaces limited; change-score cannot mutate structure status |
| `zone_enforcement` | C7 | Lookup outside an enabled zone → `403`; zone toggle kills dispatch |
| **`inference_never_overwrites_ground_truth`** | **C8** | Inference write over a ground-truth assertion → trigger raises; inference rows can only be `state='candidate'`; promotion requires an observed ground-truth row with `observed_by` |
| **`algorithm_gate_enforced`** | **C9** | M0 comparison exists with all four metrics for 4 approaches and ≥6 seeds (`spike/M0_RESULTS.md`); production `algorithm` is the M0-recommended hybrid, NOT k-means+Delaunay; regression re-runs the sweep and fails if the gate flips |

These are contract tests, written before the code they guard, and are the definition of done for M2, M6, and M8.

### 3.2 Unit

- Path-graph: per-approach implementation, plus the M0 harness as a permanent regression suite
- Code issuance: format, non-derivability, idempotency on revisit
- Dedup scoring: ranking correctness, threshold tuning
- Grievance weighting: dispatch-feedback > unverified report, until corroborated
- Sync merge: Lamport/CAS semantics per field, `site_id` tiebreak determinism
- **Assertion pipeline:** candidate → verified → superseded transitions; ground-truth rows require an observer
- Rate limiter: 5/hour, 20/day boundaries

### 3.3 Integration

- Real PostGIS: containment queries, spatial joins, `tstzrange`
- Sync round-trip: create offline → push → pull → modify both sides → converge
- Object storage: photo upload, SHA-256 integrity, orphan cleanup
- OIDC: role claims, device-bound refresh across a multi-day offline gap

### 3.4 End-to-end

Five journeys, each with an offline variant:

1. **Bootstrap → survey → sync → code → QR scan**
2. **Duplicate discovered** — two devices, same building, human review, one code
3. **Dispatch** — code → route → outcome → verification task
4. **Grievance** — resident reports → triage → corroborated → mapper task
5. **Consent** — opt in → dispatch sees context → revoke → dispatch sees nothing

### 3.5 Offline-specific

- Kill the app mid-push; relaunch; no duplicate creates
- Replay the same `client_op_id` batch ten times; identical receipts
- Client clock skewed ±2 days; convergence still correct
- Two devices editing the same confirmed structure offline for a week
- Partial sync: structures synced, breadcrumbs not
- Low storage mid-capture; queue survives
- Device pubkey rotation after a device is lost

### 3.6 Performance targets

| Metric | Target |
|--------|--------|
| Offline pin drop + photo | < 2 s |
| Push of 50 ops on reconnect | < 10 s |
| Dispatch lookup p95 | < 500 ms |
| Full-zone bootstrap (1,000 structures) | < 30 s |
| Path-graph incremental rebuild | < 5 min, never blocking dispatch |

### 3.7 Test data

Synthetic generators for structures and GPS traces with tunable noise, plus a campus capture set as path-graph ground truth. **No real settlement data, no real resident PII in any test fixture, ever.** Path-graph ground truth is the walked route recorded separately from the noisy trace, so evaluation never scores the model against its own output.

---

## 4. Local development environment

### 4.1 Prerequisites

Docker 26+, Compose v2, Node 22 LTS, Python 3.12, Flutter 3.24+, `psql` 16, 8 GB RAM, 20 GB disk.

### 4.2 One command

```
make up          # all services + migrations + seed
make down        # stop, keep volumes
make reset       # destroy and rebuild
make logs s=api
make test        # full suite
make test.contract
make spike       # M0: re-run the path-graph comparison
```

### 4.3 Services in dev

| Service | Port | Notes |
|---------|------|-------|
| `registry-api` | 8080 | Node 22, Fastify, hot reload |
| `consent-api` | 8081 | Separate container, separate DB creds |
| `graph-api` | 8082 | Redis-backed |
| `postgres-registry` | 5432 | PostGIS 3.4 |
| `postgres-identity` | 5433 | **Different credentials, not on registry's network** |
| `redis` | 6379 | |
| `minio` | 9000 | S3-compatible, photos |
| `keycloak` | 8083 | Dev realm, four roles |
| `change-detector` | — | Python worker, manual trigger in dev |
| `spike-harness` | 8084 | M0 comparison harness — **retained permanently** as the M3 regression suite (`spike/m0_multiseed.py`) |

### 4.4 Seed data

One dev realm with `mapper1`, `dispatch1`, `review1`, `admin1`; two zones (`C4` enabled, `C9` disabled to exercise C7); 50 synthetic structures spanning all six `structure_type` values; 200 synthetic breadcrumbs; 10 grievances; a `pending` dedup candidate; a `candidate`-state inference assertion to exercise C8.

### 4.5 Mobile dev

- Android emulator + `adb reverse`
- Airplane-mode toggle as a first-class dev button
- Local DB inspector
- Sync log with per-op state
- Dev-only "force dedup" toggle shifting a pin inside the threshold
- Dev-only "inject inference candidate" toggle to watch it refuse to overwrite ground truth

---

## 5. Docker setup

### 5.1 Images

| Image | Base | Build |
|-------|------|-------|
| `registry-api` | `node:22-alpine` | Multi-stage, non-root, distroless final |
| `consent-api` | `node:22-alpine` | **Separate build context** — the boundary is real in the build |
| `graph-api` | `node:22-alpine` | |
| `change-detector` | `python:3.12-slim` | |
| `spike-harness` | `python:3.12-slim` | M0; scientific stack for clustering comparison |
| `migrator` | `postgres:16-alpine` | Runs migrations, exits |
| `mobile-mock` | `node:22-alpine` | Dev only |

### 5.2 Principles

- **Two Postgres containers, two credential sets.** `registry-api` has no `identity_db` credentials in its environment or secrets (C3 at the infra layer).
- **No database credentials for `spike-harness` or `change-detector` beyond `zone_priority` / `walk_segment` candidate writes.** C6 and C8 at the infra layer.
- **Non-root, read-only rootfs** on all app containers.
- **Secrets via Docker secrets / `.env` outside VCS.**
- **Healthchecks + `depends_on: service_healthy`.** No init-order races.
- **Pinned base images by digest.**
- **Compose profiles:** `dev`, `test`, `spike`, `demo`.
- **Non-root volume mounts** for MinIO and Keycloak.

### 5.3 Configuration

All config via environment variables, validated at boot by a schema — a bad value fails the container immediately rather than at first request.

---

## 6. Resolved Decisions register

| # | Question | PRD | Decision | Effect |
|---|----------|-----|----------|--------|
| 1 | What counts as one "structure"? | §6.1 | **RESOLVED** — *"A physically distinguishable residential unit that can be assigned a unique destination for mapping and emergency dispatch."* | M1/M2 gain `structure_type` + `entrance_independent` capture, compound/wall linkage, multi-signal dedup. 12 m stays candidate-generation only. Code format stays provisional. |
| 2 | Which dispatch backend(s)? | §3 | **RESOLVED** — internal interface only this semester; `DispatchBackend` abstraction exposed. | M4 scoped to internal backend. No CAD/AVL work planned or estimated. |
| 3 | Service-data disclosure risk? | §6.6 | **RESOLVED** — sensitive operational data, not public; role-based; aggregates may be exposed. | M6 access model, `disclosure_policy`, audit-logged `full` reads, policy tests. |
| 4 | Which path-graph algorithm? | §6.2, §8 | **RESOLVED BY MEASUREMENT** — M0 ran; k-means+Delaunay **failed**; hybrid (map-matching backbone + restricted Delaunay + adaptive seeding) adopted. §6.2's rejection of seed-and-spline is **contradicted**. | M0 complete. M3 builds the hybrid. `architecture.md` §5.8 and `api.md` §9 carry the measured outcome. |
| 5 | Ground truth vs inference | new | **RESOLVED** — `assertion.evidence_class`; trigger blocks inference over ground truth. | C8; applies to AI, change detection, dedup, routing confidence. |

**Access-model note.** §6.6's role table arrived with this round of decisions and is implemented as specified in §M6 above. The earlier truncation is resolved; `architecture.md` §5.10 is reconciled against it.

### Risks (§8) — tracked, not resolved by decision

- **Path-graph accuracy under real GPS noise.** M0 measured it: usable-route rate 0.688 for the recommended hybrid backbone, versus 0.036 for the naive baseline. Risk **narrowed, not retired** — the figures are synthetic-trace only, campus capture is not yet in the dataset, and no field accuracy is claimed.
- **Open building-footprint accuracy on informal structures.** Historically the hardest case. Bootstrapped pins are `state='candidate'`, never ground truth (C8).
- **Manual dedup queue scaling bottleneck.** Measured in M8. Post-pilot mitigation is ML-assisted *pre-filtering* for reviewer ranking only — never auto-merge (C2).
- **Regional free-imagery/footprint coverage gaps.** Reported explicitly via `imagery_coverage_gaps`; never silently omitted.
- **M0 invalidated the PRD's §6.2 algorithm preference — CONFIRMED.** k-means+Delaunay failed the gate, and §6.2's rejection of seed-and-spline was contradicted by measurement. Both are flagged as superseded in `architecture.md` §5.8 and `api.md` §9. The PRD should be amended; this plan does not amend it silently.

---

## 7. Definition of done, per milestone

A milestone is done when:

1. Its exit criteria are demonstrated with real tool output, not described.
2. The constraint tests guarding its constraints pass in CI.
3. Migrations apply forward and roll back cleanly.
4. The OpenAPI spec is regenerated and matches the implementation.
5. Its offline behaviour is tested where offline behaviour exists.
6. Its evidence-class semantics are tested where inference exists.
7. Any new open question is added to §6 rather than resolved by assumption.

---

*End of Development Plan*