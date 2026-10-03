# System Architecture — Informal Settlement Address & Emergency Dispatch Registry

## 1. Overview

This document defines the system architecture for an offline-first, living registry that assigns stable IDs to structures in informal settlements, builds a routable path-graph through footpaths, and feeds a real emergency dispatch backend. The architecture strictly enforces separation between structural data and resident identity, requires human review for structure identity decisions, and operates offline with opportunistic synchronization.

---

## 2. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              CLIENT LAYER (Offline-First)                         │
├─────────────────────────────────────────────────────────────────────────────────┤
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐               │
│  │  Mapper App      │  │  Dispatcher App  │  │  Resident App    │               │
│  │  (Field Workers) │  │  (Emergency Ops) │  │  (Opt-in)        │               │
│  │                  │  │                  │  │                  │               │
│  │ • Pin/photo      │  │ • Code lookup    │  │ • Consent mgmt   │               │
│  │ • Breadcrumbs    │  │ • Route display  │  │ • Grievance      │               │
│  │ • Services       │  │ • Status updates │  │ • Verify location│               │
│  └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘               │
│           │                     │                     │                          │
│           └─────────────────────┼─────────────────────┘                          │
│                                 ▼                                                │
│                    ┌────────────────────────┐                                   │
│                    │  Local SQLite/Realm DB │                                   │
│                    │  (Full offline copy)   │                                   │
│                    └───────────┬────────────┘                                   │
└────────────────────────────────┼────────────────────────────────────────────────┘
                                 │ Opportunistic Sync
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              SYNC LAYER                                           │
├─────────────────────────────────────────────────────────────────────────────────┤
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐               │
│  │  Sync Engine     │  │  Dedup Queue     │  │  Change Detection│               │
│  │  (Conflict-free  │  │  (Human Review)  │  │  Pipeline        │               │
│  │   field merges)  │  │                  │  │  (Imagery Diff)  │               │
│  └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘               │
│           │                     │                     │                          │
│           └─────────────────────┼─────────────────────┘                          │
└────────────────────────────────┼────────────────────────────────────────────────┘
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              SERVER LAYER                                         │
├─────────────────────────────────────────────────────────────────────────────────┤
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐               │
│  │  Structural      │  │  Resident        │  │  Path-Graph      │               │
│  │  Registry API    │  │  Identity API    │  │  Service         │               │
│  │                  │  │  (Separate DB)   │  │                  │               │
│  │ • Structures     │  │                  │  │ • Graph build    │               │
│  │ • Services       │  │ • Consent vault  │  │ • Routing        │               │
│  │ • Grievances     │  │ • Opt-in records │  │ • Dispatch API   │               │
│  └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘               │
│           │                     │                     │                          │
│           └─────────────────────┼─────────────────────┘                          │
└────────────────────────────────┼────────────────────────────────────────────────┘
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              DATA LAYER                                           │
├─────────────────────────────────────────────────────────────────────────────────┤
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐               │
│  │  PostgreSQL      │  │  PostgreSQL      │  │  Redis/Vector DB │               │
│  │  (Structural)    │  │  (Identity)      │  │  (Path-graph,    │               │
│  │                  │  │                  │  │   embeddings)    │               │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘               │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Component Responsibilities

### 3.1 Mapper App (Field Worker Client)
- **Offline capture**: Drop pins, capture photos, record structure metadata (material, floors, services)
- **Breadcrumb trails**: GPS traces from road access point to structure door
- **Service connections**: Structured records per service type (water, electricity, sanitation, internet)
- **Local storage**: Full SQLite database for offline operation
- **Sync trigger**: Opportunistic push when connectivity detected

### 3.2 Dispatcher App (Emergency Operations)
- **Code lookup**: Enter structure code → get location + route
- **Route display**: Visual path on map with turn-by-turn for footpath network
- **Status updates**: Mark dispatch success/failure, trigger re-verification
- **Zone awareness**: Only operates within pilot mapped zone

### 3.3 Resident App (Opt-in Identity)
- **Consent management**: Granular opt-in for identity linkage to structure
- **Grievance channel**: In-app geo/photo-tagged complaints
- **Location verification**: Confirm/correct registered structure location
- **No QR dependency**: Fully in-app, rate-limited per device/account

### 3.4 Structural Registry API
- **Structure CRUD**: Create, read, update structure records
- **Service records**: Per-service structured data (type, source, hours, quality, shared-count, last-verified, verification-method)
- **Grievance intake**: Receive, validate, weight grievance reports
- **NO PII**: Strictly no resident identity data

### 3.5 Resident Identity API (Separate Service)
- **Consent vault**: Encrypted, opt-in only identity records
- **Linkage**: Optional linkage to structure code (resident-controlled)
- **Dispatch context**: Only exposed to dispatch if resident opted in
- **Separate database**: Physically isolated from structural data

### 3.6 Path-Graph Service
- **Graph construction**: Incremental clustering (k-means seed placement) + weighted Delaunay triangulation
- **Routing**: Shortest-path on walkable network (footpaths, not roads)
- **Dispatch integration**: Code → location + route API
- **Validation**: Campus/synthetic trace validation before production integration

### 3.7 Sync Engine
- **Field-level CRDTs**: For confirmed structures only (service data, status updates)
- **NO CRDT for identity**: Entity identity never auto-merged
- **Dedup queue**: New structures within proximity radius → human review
- **Conflict resolution**: Last-write-wins for fields, human for identity

### 3.8 Dedup/Review Queue
- **Proximity detection**: Tuned radius around newly-synced structures
- **Side-by-side review**: Paired photos, metadata comparison
- **Human decision**: Merge / keep separate / request field revisit
- **Scaling concern**: Manual queue is bottleneck beyond pilot (known risk)

### 3.9 Change Detection Pipeline
- **Fast signal**: Dispatch failure + resident complaint → immediate re-verification trigger
- **Slow signal**: Satellite/aerial imagery diffing (weeks-months cadence)
- **Bootstrap layer**: Open building-footprint datasets for initial load and slow-baseline
- **Prioritization**: AI-assisted zone ranking for mapper revisit

---

## 4. Data Flow Summary

### 4.1 Bootstrap → Map → Sync
```
Open footprint data → Pre-load candidate pins → Mapper confirms/adjusts/drops new
                                                         ↓
                                              Local ID assignment (tentative)
                                                         ↓
                                              Offline breadcrumb + photo capture
                                                         ↓
                                              Opportunistic sync to server
                                                         ↓
                                              Dedup queue check (proximity)
                                                         ↓
                                              Human review → Finalize stable ID
```

### 4.2 Path-Graph Build
```
Mapper breadcrumbs (multiple) → Incremental clustering → Seed placement
                                                      ↓
                                          Weighted Delaunay triangulation
                                                      ↓
                                          Walkable graph (edges = footpath segments)
                                                      ↓
                                          Routing engine (A* on graph)
```

### 4.3 Dispatch Flow
```
Dispatcher enters code → Structural Registry: location + structure metadata
                              ↓
                        Path-Graph: route from road to door
                              ↓
                        Responder dispatched with route
                              ↓
                        Success/failure logged → Fast signal for re-verification
```

### 4.4 Feedback Loops
```
Dispatch failure ──┐
                   ├─→ Re-verification queue → Mapper revisit
Resident grievance ┘       (weighted by verification_method)
        │
        └─→ Cross-check vs registered location → Weighted update
```

---

## 5. Non-Functional Requirements

| Requirement | Specification |
|-------------|---------------|
| Offline capability | Full read/write offline; sync when online |
| Sync latency | Opportunistic; background when connectivity detected |
| Pilot zone | College campus only; dispatch restricted to mapped zone |
| Data separation | Structural DB and Identity DB physically isolated |
| ID stability | Deterministic, idempotent on revisit; not geohash-derived |
| Human-in-loop | Identity decisions (dedup) always human-reviewed |
| AI scope | Limited to: path-graph clustering, footprint bootstrap, change-detection prioritization, low-literacy capture assistance |
| Excluded from AI | ID assignment, sync conflict/identity resolution, structure classification |
| Evidence model | Every asserted value carries `evidence_class`; inference cannot overwrite ground truth (C8) |
| Path-graph algorithm | **Decided by M0 measurement** — k-means+Delaunay failed the gate; hybrid adopted (§5.8) |
| Grievance weighting | Dispatch-feedback > unverified resident report (until corroborated) |
| Rate limiting | Per device/account for grievance channel |

---

## 5.5 Repository Structure

```
el/
├── docs/
│   ├── architecture.md          ← this file
│   ├── database.md              ← schema, separation proof, retention
│   ├── api.md                   ← contract-first REST/OpenAPI
│   └── development-plan.md      ← milestones, testing, local env, docker
├── openapi/
│   ├── registry.yaml  consent.yaml  graph.yaml  sync.yaml
├── services/
│   ├── registry-api/            ← structures, services, dedup, dispatch, grievances
│   │   ├── src/{routes,domain,db,auth,middleware}/
│   │   ├── migrations/          ← registry_db only
│   │   └── test/{unit,integration,contract}/
│   ├── consent-api/             ← SEPARATE BUILD CONTEXT (C3 boundary is real)
│   │   └── migrations/          ← identity_db only
│   ├── graph-api/               ← path-graph build + routing
│   ├── change-detector/         ← imagery diff, footprint bootstrap (Python)
│   └── ml/                      ← AI scope, isolated (C6)
├── apps/
│   ├── mapper/                  ← offline-first field app
│   ├── dispatcher/              ← emergency ops app
│   ├── resident/                ← consent + grievance app
│   └── review-console/          ← dedup queue, graph inspection (web)
├── packages/
│   ├── contracts/               ← generated TS+Dart SDKs from openapi/
│   ├── sync-core/               ← CRDT field-merge, outbox, cursor logic
│   ├── geo/                     ← PostGIS + turf.js wrappers
│   └── design-tokens/           ← shared UI; low-literacy capture mode (C6 assist)
├── infra/
│   ├── docker/                  ← Dockerfiles, compose.{dev,test,demo}.yml
│   ├── k8s/                     ← production manifests, namespace split
│   └── fixtures/                ← synthetic generators ONLY. No real settlement data.
└── tools/
    ├── trace-gen/               ← synthetic GPS traces for M3 validation
    └── scripts/                 ← migrate, seed, contract-check
```

Two structural decisions here are load-bearing:

- `consent-api` is a **separate build context**, so `registry-api`'s image cannot contain identity code or credentials. The C3 boundary survives a careless environment-variable change.
- `services/ml` has **no database credentials at all**. It emits scores and candidate inputs to a narrow API that the registry service calls. C1 and C6 are enforced by what ML physically cannot reach.

---

## 5.6 Mobile Application Architecture

One shared core, three thin shells. The offline engine is not duplicated per app.

```
apps/{mapper,dispatcher,resident}/
└── src/
    ├── core/                    ← SHARED, single source of truth
    │   ├── db/                  ← SQLite, migrations, repositories
    │   ├── sync/                ← outbox, cursor pull, opportunistic trigger
    │   ├── crdt/                ← field-level Lamport merge (confirmed structures ONLY)
    │   └── net/                 ← connectivity detection, retry, backoff
    ├── features/                ← per-app domain code
    ├── ui/                      ← tokens, incl. low-literacy capture mode
    └── bootstrap.ts             ← migrate DB → load zone → then open sync
```

**Framework:** Flutter. One codebase, one SQLite binding, mature offline patterns, and a renderer that holds up on low-end Android — which is what a field mapper actually carries.

**Offline-first discipline (C4):**
- The UI never awaits a network call. It reads from SQLite, renders, and enqueues a write.
- `bootstrap.ts` migrates the local DB **before** the sync layer opens. A schema mismatch can never produce a corrupt sync.
- Full mapped zone pre-seeded via `GET /v1/sync/bootstrap` on first run. After that the field works with zero connectivity indefinitely.
- Photos are written locally first, hashed on capture, uploaded opportunistically, and never block a save.

**Opportunistic sync (C5):** connectivity change → debounce → `sync/health` gate → push pending ops → pull from cursor. No background daemon, no long-lived socket, no retry loop that assumes a network exists. Pulling the plug mid-push is a normal state, not an error.

**What each app may write:**

| App | Structural | Identity | Dispatch |
|-----|-----------|----------|----------|
| Mapper | Full capture + service data | **None** | Read tasks |
| Dispatcher | Outcome only | Read occupant-context (audited) | Read + outcome |
| Resident | **None** | Consent only | None |

A resident app with write access to structural data would violate C3 by construction. It has no such route.

**Low-literacy capture assistance (permitted AI, C6):** voice- and icon-driven entry for material/services, with the assistant proposing *values the mapper confirms*. It proposes field content and never proposes identity, never proposes a code, and never resolves a conflict.

---

## 5.7 Offline Synchronization Strategy

Two distinct problems, two distinct mechanisms. Conflating them is how offline systems lose data or invent identities.

### Field-level edits → CRDT

Only for structures that already have a code. Per field: Lamport clock + `site_id` tiebreak. Two mappers editing service data offline both survive; merge is deterministic and commutative. Explicitly **not** used for deciding whether two pins are the same building (C2).

### Entity identity → human review

Never CRDT. A new pin inside a dedup radius does not merge and does not duplicate — it becomes a `dedup_candidate` and waits for a reviewer. This is why identity is deliberately *not* an offline-first feature: the offline engine can defer a decision, but only a human can make it.

### Sync envelope

```
mapper device                          server
  pending_op (seq, client_op_id)
      │
      ├─ push batch ──────────────▶  dedup proximity check
      │                                 ├─ hit  → 409 dedup_required → review queue
      │                                 └─ miss → apply → sync_receipt
      │
      ◀────────────── receipts ─────────┘
  mark clean, bump cursor
      │
      ◀────────────── pull(cursor) ────  tombstones + changes since cursor
```

Guarantees: `client_op_id` makes every op idempotent, so a replay after a dropped response is safe. Ops apply in `seq` order; one failure does not abort the batch and only failed ops retry. `server_time` is authoritative — client clocks are never trusted, which matters on devices that have been offline for days. Cursor is opaque and time-ordered, so tombstones propagate and deleted structures converge rather than resurrecting.

---

## 5.8 Path-Graph Architecture

**Algorithm DECIDED by the M0 spike (measured, not assumed).** Full results: `spike/M0_RESULTS.md`.

> **RESOLVED — supersedes the earlier §5.8 text and PRD §6.2's algorithm preference.** The previous version of this section asserted k-means+Delaunay as the approach. M0 measured four candidates against ground truth over 6 seeds and **k-means+Delaunay failed the gate**: it regressed destination reachability (0.782 vs baseline 1.000) and routing success (0.818), because a fixed seed count spreads seeds across empty space and Delaunay then bridges non-adjacent seeds across voids, fragmenting the network into 7 components.

Measured, mean over 6 seeds:

| Algorithm | F1 | precision | usable_route | dest_reach | route_err | build_s |
|---|---|---|---|---|---|---|
| nearest_neighbor (baseline) | 0.255 | 0.164 | 0.036 | 1.000 | 3.860 | 0.015 |
| kmeans_delaunay (PRD §6.2) | 0.572 | 0.509 | 0.520 | 0.782 | 0.248 | 0.092 |
| dbscan_graph | 0.183 | 0.288 | 0.148 | 0.949 | 0.185 | 0.019 |
| **spline_mapmatch (PRD-rejected)** | **0.668** | **0.531** | **0.688** | 1.000 | 0.531 | 0.028 |

Two findings that change the design:

**On the corrected gate, k-means+Delaunay passes** (+0.483 usable-route over baseline, no routing regression). It is still not adopted: its −0.218 destination-reach regression means some structures cannot be routed to *at all*, which for emergency dispatch is a worse failure than a circuitous route, and its graph fragments into 7 components.

**Destination reach is not a discriminator.** The naive baseline reaches 100% of destinations while 96% of its routes traverse non-path geometry — it connects everything by brute force. The discriminating metric is **`usable_route_rate`**: routes whose traversed length lies predominantly on real path geometry. All dispatch decisions use it.

**PRD §6.2's rejection of seed-and-spline is contradicted by measurement.** It was rejected for having "no mechanism to suppress spurious paths", but its spurious-route rate is 0.313, the lowest of all four. §6.2 conflated *edge count* with *spuriousness* — a dense mesh along genuinely-walked corridors is redundant, not spurious.

Adopted approach — a hybrid, not any single candidate:

```
GPS breadcrumbs (multiple mappers, noisy, offline)
        │
        ▼
  map-matching backbone            snap + string-match along trace order
        │                          (best measured F1, usable-route, reach)
        ▼
  restricted Delaunay bridging     triangulate ONLY seed pairs whose edge
        │                          passes a proximity test against trace mass,
        │                          with edge length capped at k× mean spacing
        │                          → repairs void bridges; keeps junctions
        ▼
  adaptive k-means seeding         k chosen from trace density, not a constant
        │                          (DBSCAN retained for outlier rejection)
        ▼
  explicit spurious-suppression stage   the property the PRD actually requires —
        │                          measured, not assumed, for any family
        ▼
  walk_node / walk_segment  (evidence_class='inference', state='candidate')
        │
        ▼
  A* routing → Dispatch
```

Every edge arrives `state='candidate'` with `evidence_class='inference'` and is **not authoritative** (C8). A mapper walking the path or a responder traversing it produces the ground-truth assertion that promotes it to `state='asserted'`. `passable` stays NULL until observed. Every edge records `algorithm`, so any routing result traces to the method and build version that produced it.

`graph_version` pins for the duration of a dispatch call, so a rebuild never serves a half-connected graph — a rebuild yields `503 graph_rebuilding` with `Retry-After`. Reviewer correction of an edge is a ground-truth observation and promotes the segment.

**Scope of the claim.** These figures are synthetic-trace only. PRD §8's accuracy risk is narrowed, not retired: campus capture is not yet in the dataset and field accuracy is unvalidated. No field accuracy is claimed.

---

## 5.9 AI/ML Architecture

### Permitted (C6)

| Use | Method | Input | Output | Cannot |
|-----|--------|-------|--------|-------|
| Path-graph clustering | k-means-style incremental | breadcrumbs | seeds, edge weights | touch structures or identity |
| Footprint bootstrap | open building-footprint datasets | region | candidate pins (`status='candidate'`) | issue codes or verify |
| Change prioritization | raster diff → rank | imagery, complaints | zone visit-order score | change status or identity |
| Low-literacy capture | intent classification | voice/icon input | proposed field values | propose identity or resolve conflicts |

### Explicitly excluded (PRD §6.7)

- **Structure ID assignment** — no code path, no DB grant, CI test enforces absence
- **Sync conflict / identity resolution** — review queue is human-only; `score` is a ranking hint and never a decision
- **Structure classification (`structure_type`, `entrance_independent`)** — §6.1 defines a structure as an independently identifiable *destination*, which is an observation about human access, not something inferable from geometry or imagery. Two dwellings behind one gate are one structure; the same two dwellings with separate gates are two. No model can see that difference. AI must not propose a structure type or an entrance classification.

### Enforcement

`services/ml` holds no database credentials. It reads through narrow read-only API endpoints and writes through a narrow results endpoint. Database role grants deny `INSERT`/`UPDATE` on `structure.code` and `structure_code_sequence` to every non-system role. The constraint is enforced by what ML physically cannot reach — not by convention, review, or a comment.

Change-detection scoring writes to a `zone_priority` table. It has no route to `structure` at all. A score can change which zone a mapper visits first and nothing else.

---

## 5.10 Authentication & Authorization

**AuthN:** OIDC (Keycloak). Access token 15 min. Offline mappers hold a device-bound refresh token (Ed25519), because a mapper may be offline for days and a hard expiry would lock them out of their own work.

**AuthZ:** role claim, enforced per-route from a policy table. Roles: `mapper`, `dispatcher`, `reviewer`, `admin`, plus `municipal_ngo` for authorized external users (§6.6).

| Capability | mapper | dispatcher | reviewer | admin | municipal/NGO | resident | ML svc | consent svc |
|------------|--------|-----------|----------|-------|--------------|---------|---------|-------------|
| Create structure | yes | no | no | no | no | **no** | **no** | no |
| Assign code | **no** — human review only | no | no | via decision | no | **no** | **no** | no |
| Merge structures | **no** | no | yes | yes | no | **no** | **no** | no |
| Service data `full` | yes (field-relevant) | yes (response-relevant only) | no | yes | per role | **no** | **no** | no |
| Service data aggregate | yes | yes | yes | yes | per role | **no** | zone stats only | **no** |
| Service data, unauthenticated | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** |
| Dispatch lookup | no | yes | no | yes | per role | no | no | no |
| Dispatch outcome | no | yes | no | yes | no | no | no | no |
| Occupant context | **no** | yes (audited) | no | yes | per role | read own | no | resolves |
| Consent scopes | **no** | no | no | no | **no** | own only | no | writes |
| Grievance | write | triage | read | read | read | write own | no | no |
| Zone config | no | no | no | yes | no | no | no | no |
| Audit read | no | no | yes | yes | per role | no | no | no |
| Write inference candidates | no | no | no | no | no | no | **yes** | no |
| Promote candidate → ground truth | **yes** | **yes** | yes | yes | no | own report | **no** | no |
| DB credential for `identity_db` | **no** | no | no | no | no | no | **no** | **yes** |

Three rows carry the most weight.

**`Assign code` is `no` for every automated role.** No role — including admin — assigns a code directly. Issuance happens only inside a dedup decision the reviewer made.

**`Promote candidate → ground truth` is `no` for the ML service.** Inference writes candidates; only a person promotes them (C8). This is the row that makes the ground-truth principle a permission rather than a convention.

**`DB credential for identity_db` is `yes` for exactly one service.** Enforced in Docker (separate containers, separate credentials) and verified by a CI test that attempts the connection and requires it to fail.

**§6.6 service-data access.** Structure-level service information is sensitive operational data and is not publicly exposed. Access is role-based; aggregate service statistics may be exposed where appropriate. The unauthenticated row is uniformly `no`, and `full` reads are audit-logged.

**PII risk ≠ service-data risk.** Identity is PII and is consent-gated (§6.3, separate store, revocable). Service data is not PII but is still sensitive: it can expose vulnerability and enable enforcement or exclusion without naming anyone. It is therefore role-gated, not consent-gated. The consent vault is the wrong instrument for it. See §6 for the full comparison.

**Auditing:** every occupant-context call is written to `audit_log` with actor and timestamp, and queryable via `/v1/audit/consent-calls`. Every mutating call is logged. Dispatch outcomes are logged with responder identity — dispatch accountability is the check on consent-by-design.

---

## 5.11 Ground Truth vs Inference (C8)

The most easily violated principle in the system, so it is enforced by the database rather than by discipline.

**Ground truth** is something a person observed:

- mapper verification
- responder observation (reached the scene, saw the gate)
- resident report

**Inference** is something a system concluded:

- GPS trace clustering
- imagery change detection
- route confidence
- duplicate candidates

**Inference must never silently overwrite ground truth.** The permitted flow, and the only one:

```
Inference ──▶ Candidate change ──▶ Verification ──▶ Ground-truth update
   (never            (a task)          (a person)        (new asserted row)
    overwrites)
```

Mechanism (`database.md` §1.5): every asserted value is a row in `assertion` carrying `evidence_class`. Inference rows are constrained to `state='candidate'` by CHECK, and a BEFORE UPDATE trigger raises an exception if an inference write targets an asserted ground-truth row. Promotion to `asserted` requires an `observed_by` and `observed_at` — a person.

Why this matters concretely: an imagery diff that thinks a structure is gone, or a clustering pass that moves a footprint three metres, or a dedup scorer that is 90% confident two pins are the same — none of these may change what the registry says. They may only create work for someone who will look.

| Value | Class | Promoted by |
|---|---|---|
| `centroid`, `entrance_geom`, `entrance_independent`, `structure_type`, `status` | ground truth | mapper / responder / resident |
| `footprint` | candidate when bootstrapped, ground truth when surveyed | mapper |
| `walk_segment` geometry & confidence | **inference**, always candidate | mapper walks it / responder traverses it |
| `zone_priority.score` | **inference**, always candidate | never promoted — orders visits only |
| `dedup_candidate` | **inference**, always candidate | reviewer decision |
| `dedup.photo_similarity` | **inference** | never decides |
| AI-proposed field values | **inference**, proposed for confirmation | mapper confirms |

This also discharges the AI-scope constraint structurally: an AI component can only ever write a candidate row, so "AI must not assign identity" becomes a database permission rather than a code review promise.

---

## 6. Resolved Decisions (PRD §7)

All three questions are now **DECIDED**.

**1. §6.1 — What counts as one structure?**

> *"A physically distinguishable residential unit that can be assigned a unique destination for mapping and emergency dispatch."*

| Situation | Structures |
|---|---|
| Standalone dwelling | 1 |
| Separate dwellings sharing a wall, independently identifiable entrances | separate per dwelling |
| Multiple households, one common entrance | 1 |
| Compound with independently accessible dwellings | multiple |
| Temporary shelter functioning as an independent residential destination | counts |
| Non-residential | recorded for navigation/context, explicit type required |

The operative concept is **unique destination**, not building. That is why `entrance_geom` and `entrance_independent` are first-class fields and why the entrance is the discriminator the dedup review turns on.

Consequences: `structure_type` enum with six values; `entrance_geom` + `entrance_independent`; `compound_root_id` for compounds; `shares_wall_with` symmetric link; `non_residential_subtype` required for non-residential. The 12 m value is retained as a **candidate-generation threshold only** — dedup now weighs GPS proximity, entrance proximity, footprint overlap, photo evidence, mapper assertion, and shared-wall information together. The public code format remains provisional and independent of the immutable internal UUID.

**2. §3 — Which dispatch backend?**

Internal dispatch interface is the only implemented backend this semester. `DispatchBackend` (`lookup` / `dispatch` / `outcome` / `capabilities`) exists as an interface with `InternalBackend` as its MVP implementation, selected by configuration, so a future CAD/AVL/NGO adapter is additive. No external integration is designed or estimated.

**3. §6.6 — Surveillance-trust risk of service data?**

> *"Structure-level service information is sensitive operational data and is not publicly exposed. Access is role-based; aggregate service statistics may be exposed where appropriate."*

`disclosure_policy` per structure (`full` / `aggregate_only` / `redacted`), default `aggregate_only`. No unauthenticated or resident-facing path returns service data. `full` reads are audit-logged. Aggregate statistics come from a view with no per-structure row path.

**Access model (as decided):**

| Actor | Service-data access |
|---|---|
| **Public** | No individual structure-level service data — none |
| **Mapper** | Relevant service information needed for field work |
| **Dispatcher** | Only information operationally relevant to response |
| **Authorized municipal/NGO users** | Access according to role |
| **Public analytics/reporting** | Aggregate data only |

**PII risk and sensitive service-data risk are distinct, and both are protected.**

| | Resident identity (PII) | Service data (sensitive operational) |
|---|---|---|
| What it reveals | Who lives at this structure | That a structure lacks water / shares sanitation / has poor access |
| Personal? | **Yes** — identifies a person | **No** — identifies a condition |
| Harm mechanism | Identification, targeting, surveillance of a person | Exposure of vulnerability; enforcement pressure, exclusion, price or service denial — with nobody named |
| Consent | Opt-in, separately stored, revocable (§6.3) | Not consent-based; **role-based access** and non-public exposure |
| Storage | Separate `identity_db`, separate credentials, no FK (§4) | `registry_db`, `disclosure_policy`-gated |
| Erasure | Right to be-forgotten; structural record unaffected | Retained as operational data, exposed only by role |

The practical implication: a dataset with no names in it can still be harmful. Twelve structures in a zone with no water connection is a map of vulnerability that enables enforcement or exclusion even though it contains no resident identity whatsoever. That is why §6.6 is decided as sensitive-operational-data protection rather than folded into the consent model — **the consent vault protects people, and it is the wrong instrument for protecting places.** Treating service data as merely "non-PII, therefore fine to publish" would be the actual error here.

---

## 6b. Known Risks (from PRD, unchanged)

1. Path-graph clustering accuracy under real GPS noise — unvalidated beyond synthetic/campus traces
2. Open building-footprint model accuracy on informal structures specifically — historically the hardest case for these models
3. Manual dedup review queue is a scaling bottleneck beyond pilot size
4. Regional coverage gaps in free imagery/footprint datasets

These are risks, not open questions. None of them was resolved by the §7 decisions, and none of them is treated as settled anywhere in this design.

---

## 7. Known Risks (from PRD)

1. Path-graph clustering accuracy under real GPS noise — unvalidated beyond synthetic/campus traces
2. Open building-footprint model accuracy on informal structures — historically hardest case
3. Manual dedup review queue scaling bottleneck beyond pilot size
4. Regional coverage gaps in free imagery/footprint datasets

---

## 8. Technology Stack Summary

| Layer | Technology | Rationale |
|-------|------------|-----------|
| Mobile (Mapper/Dispatcher/Resident) | React Native + Expo / Flutter | Cross-platform, offline SQLite support |
| Local DB (Mobile) | SQLite (via WatermelonDB/Realm) | Full offline, sync-friendly |
| Server API | Node.js (Fastify) or Go | Type-safe, good offline-sync libraries |
| Structural DB | PostgreSQL + PostGIS | Geospatial queries, JSONB for flexible services |
| Identity DB | PostgreSQL (separate instance) | Physical isolation, encryption at rest |
| Path-Graph | Redis + custom graph engine | Fast routing, incremental updates |
| Sync Engine | Custom + Yjs/Automerge for field CRDTs | CRDT for fields, custom for identity |
| Change Detection | Python (rasterio, GDAL) + scheduled jobs | Imagery processing ecosystem |
| AI/ML | Python (scikit-learn, PyTorch) | Clustering, change detection, footprint bootstrap |
| Deployment | Docker Compose (dev), Kubernetes (prod) | Containerized, portable |
| Auth | OIDC (Keycloak) + mTLS for service-to-service | Standards-based, fine-grained RBAC |

---

## 9. Security Model

- **Structural data**: No PII, accessible to mappers, dispatchers, admins
- **Identity data**: Encrypted at rest, resident-controlled access, separate auth domain
- **Sync**: mTLS between client and server, signed sync payloads
- **Dispatch API**: Authenticated, zone-restricted, audit-logged
- **Grievance**: Rate-limited, geo-validated, weighted by verification source

---

## 10. Scalability Considerations

- **Pilot**: ~1,000 structures, 10-20 mappers, single zone
- **Dedup queue**: Human review limits scale; consider ML-assisted pre-filtering (NOT auto-merge) for v2
- **Path-graph**: Incremental updates; full rebuild only on major topology change
- **Imagery**: Free tier limits; budget for commissioned capture if scaling

---

*End of Architecture Document*