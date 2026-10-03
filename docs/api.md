# API Specification

Base URL: `https://api.registry.pilot/v1`
Transport: HTTPS, TLS 1.3. All bodies `application/json` unless noted.

This is a **contract-first** document. Services are generated from these definitions (OpenAPI 3.1) — implementation must not drift from it.

---

## 0. Services and the identity boundary

| Service | Prefix | Holds PII | Reaches `identity_db` |
|---------|--------|-----------|----------------------|
| `registry-api` | `/v1` | No | No |
| `consent-api` | `/v1/consent` | Yes | Yes |
| `graph-api` | `/v1/graph` | No | No |
| `sync-api` | `/v1/sync` | No | No |

`registry-api` has no credential capable of reaching `identity_db`. The only bridge is `consent-api`'s dispatch resolver (§6), which is read-only, audited, and returns an *absence* rather than an error when consent is missing. This is the mechanical enforcement of PRD §4 and §6.3.

---

## 1. Authentication

- OIDC (Keycloak). Bearer JWT in `Authorization`.
- Access token TTL 15 min; offline mappers hold a **refresh token bound to their device key** — required because a mapper may be offline for days. Refresh only on connectivity; failure is not an error state in the field.
- Roles: `mapper`, `dispatcher`, `reviewer`, `admin`. Claim `role` in the token; enforced per-route in a policy table.
- Client mutating calls require a **device signature** over the request body (`X-Device-Signature`, Ed25519) using the pubkey registered at `POST /v1/mappers/register`. Prevents a stolen bearer token from writing as another mapper.
- Service-to-service: mTLS, no user token.

---

## 2. Structures

### 2.1 `POST /v1/structures` — create candidate (offline sync)

Role: `mapper`. This is the write path used by sync. **No code is issued here.** Returns `409 dedup_required` when the new pin falls inside any existing structure's dedup radius.

```json
// Request
{
  "client_op_id": "018f3c2a-...-uuid",
  "device_id": "dev_9f2b",
  "payload": {
    "footprint": { "type": "Polygon", "coordinates": [[[77.59,12.97],[77.59,12.971],[77.591,12.971],[77.591,12.97],[77.59,12.97]]] },
    "centroid": { "lat": 12.9705, "lon": 77.5905, "accuracy_m": 4.2 },
    "access_point": { "lat": 12.9702, "lon": 77.5901 },
    "structure_type": "shared_wall_dwelling",
    "non_residential_subtype": null,
    "entrance_geom": { "lat": 12.9704, "lon": 77.5903 },
    "entrance_independent": true,
    "compound_root_id": null,
    "is_shared_wall": true,
    "shares_wall_with": null,
    "floors_estimated": 2,
    "material_primary": "brick_plaster",
    "occupancy_estimate": 9,
    "status": "surveyed",
    "verification_src": "mapper_survey",
    "services": [
      { "service_type": "water", "source": "shared_private", "supply_hours": [[6,10],[18,22]],
        "quality": "fair", "shared_with_count": 4 }
    ],
    "photos": [{ "sha256": "…", "captured_at": "2026-03-02T09:14:00Z" }],
    "captured_at": "2026-03-02T09:14:00Z"
  }
}
```

```json
// 201 Created
{
  "server_id": "b21c…", "status": "surveyed", "code": null,
  "version": 1,
  "dedup": { "required": false }
}
```

```json
// 409 Conflict — routed to human review, never auto-merged (PRD §6.1)
{
  "error": "dedup_required",
  "dedup_candidate_id": "c07d…",
  "nearest_structure": { "server_id": "9a1f…", "code": "SLR-C40012", "distance_m": 6.3, "iou": 0.71 }
}
```

> Note: `occupancy_estimate` is a structural aggregate. It is never derivable to an individual and is not linked to any identity record.
>
> **§6.1 classification.** `structure_type` must be supplied by the mapper. It is a field observation, not an inference: the system does not guess a structure type, and AI must not propose one. `entrance_independent` is the discriminator that separates `shared_wall_dwelling` (two structures) from `multi_household_single_entry` (one structure) — the mapper answers "can a responder be sent here as a unique destination?", not "how many households live here". If `structure_type='non_residential'`, `non_residential_subtype` is required (`422`).

### 2.2 `PATCH /v1/structures/{id}` — field-level update (CRDT-merged)

Role: `mapper`, `dispatcher` (status only). Body carries per-field Lamport stamps for confirmed structures.

```json
{
  "client_op_id": "…", "base_version": 4,
  "fields": {
    "floors_estimated":      { "value": 3, "lamport": 88, "site_id": "dev_9f2b" },
    "material_primary":      { "value": "concrete", "lamport": 91, "site_id": "dev_9f2b" }
  }
}
```

Merge rule: per field, highest Lamport wins; tie broken deterministically by `site_id`. **Field-level CRDT applies only to structures already confirmed (has a `code`).** An unconfirmed structure in conflict is escalated to `dedup_candidate` or rejected, never merged.

### 2.3 `GET /v1/structures/{code}`

Role: any. Structural record + current verification state + service records. No PII, no occupant fields.

```json
{
  "code": "SLR-C40012",
  "status": "verified",
  "centroid": { "lat": 12.9705, "lon": 77.5905 },
  "footprint": { … },
  "access_point": { "lat": 12.9702, "lon": 77.5901 },
  "services": [ { "service_type": "water", "source": "shared_private", "quality": "fair",
                  "shared_with_count": 4, "last_verified_at": "2026-02-11T06:20:00Z",
                  "verification_src": "mapper_survey" } ],
  "last_verified_at": "2026-02-11T06:20:00Z",
  "verification_src": "mapper_survey",
  "version": 7
}
```

### 2.4 `GET /v1/structures?bbox=&status=&updated_since=&limit=&cursor=`

Cursor-paged, default 200, max 1000. Bounding-box required for mobile pre-seed.

### 2.5 `DELETE /v1/structures/{id}`

Soft delete only. Sets `deleted_at` and a tombstone `verification_event` so offline clients converge. Hard delete is admin-only and requires a `verification_event` with `outcome='gone'`.

---

## 3. Service connections (PRD §6.6)

### 3.1 `PUT /v1/structures/{code}/services/{service_type}`

Full upsert. Cheap re-check path:

```json
{ "still_true": true, "checked_at": "2026-03-20T08:02:00Z", "quality": "good" }
```

→ server updates `still_true_checked_at` only, leaving `last_verified_at` and `verification_src` intact. A contradicted check opens a re-verification task.

### 3.2 `GET /v1/structures/{code}/services`

Returns records. Behaviour is governed by the structure's `disclosure_policy` (§6.6): `full` returns exact values (role-gated, audit-logged), `aggregate_only` returns coarsened values (`shared_with_count` bucketed, hours rounded), `redacted` returns `403`.

**Access model (§6.6, as decided):**

| Actor | This endpoint |
|---|---|
| Public (unauthenticated) | `401` — no individual structure-level service data, ever |
| Mapper | Exact records, scoped to field-relevant service types |
| Dispatcher | Exact records for `service_type ∈ {water, electricity, sanitation, road_access}` — operational relevance to response; other types omitted from the response, not merely hidden |
| Authorized municipal/NGO | Per role assignment |
| Public analytics/reporting | This endpoint returns `403`; aggregate statistics come from §3.3 |

Dispatcher scope is a **response-shaping rule, not a field mask**. `quality` on a water connection is operationally relevant to a response; `shared_with_count` on an internet connection is not. Omitting the whole record is more honest than returning a partially-populated one that implies completeness.

### 3.3 `GET /v1/zones/{zone}/service-stats`

Aggregate statistics only. No per-structure rows, no structure codes, no coordinates. This is the only service-data surface reachable by a reporting consumer.

**Implementer note — service data is not PII, and that is exactly why it still needs protecting.** Resident identity (§6.3) identifies a *person* and is therefore consent-gated, separately stored, and revocable. Service data identifies a *condition* — no water connection, shared sanitation, poor access — and contains no personal identifier. It is nonetheless sensitive: a zone-level count of unserved structures is a map of vulnerability that can be used for enforcement, exclusion, or service denial without anyone being named.

The consequence for implementation: **do not treat these as the same problem, and do not route service data through the consent vault.** Identity gets consent. Service data gets role-based access. Treating "no PII" as "safe to publish" is the failure mode §6.6 exists to prevent.

```json
{ "zone": "C4", "structures_counted": 143, "generated_at": "2026-03-20T08:00:00Z",
  "by_type": { "water": { "connected": 131, "share": 0.916 },
               "electricity": { "connected": 128, "share": 0.895 },
               "sanitation": { "connected": 96, "share": 0.671 } } }
```

Served from a dedicated aggregate view with no row-level path to `structure_service`. `403` for any attempt to coerce it into per-structure detail.


---

## 4. Dedup / human review (PRD §6.1)

### 4.1 `GET /v1/dedup?state=open` — reviewer's queue

```json
{ "items": [ { "dedup_candidate_id": "c07d…", "score": 0.88,
    "signals": {
      "distance_m": 6.3,
      "entrance_dist_m": 11.8,
      "iou": 0.71,
      "wall_shared": true,
      "photo_similarity": 0.44,
      "mapper_conflict": false
    },
    "definition_hint": "Wall shared, entrances 11.8 m apart and flagged independent — §6.1 reads this as TWO structures, but the reviewer decides.",
    "structure_a": { "code": "SLR-C40012", "status": "verified", "photo": "s3://…a.jpg",
                     "centroid": {…}, "structure_type": "shared_wall_dwelling",
                     "entrance_geom": {…}, "entrance_independent": true,
                     "is_shared_wall": true, "built_year_est": 1998 },
    "structure_b": { "code": null, "status": "surveyed", "photo": "s3://…b.jpg",
                     "centroid": {…}, "structure_type": "shared_wall_dwelling",
                     "entrance_geom": {…}, "entrance_independent": true,
                     "material_primary": "brick_plaster" },
    "suggested_action": "distinct" } ] }
```

`suggested_action` applies the §6.1 rules to the recorded signals and is **a ranking hint only**. There is no automated merge endpoint and no automated distinct endpoint; the reviewer's decision is the outcome in every case.

**§6.1 decision guidance, for the reviewer's benefit:**

| Observed | §6.1 reading | Typical outcome |
|---|---|---|
| Overlapping footprints, **one** common entrance | 1 structure | `merge` |
| Shared wall, **independent** entrances | 2 structures | `distinct`, link `shares_wall_with` |
| Compound, dwellings independently accessible | multiple structures | `distinct`, set `compound_root_id` on children |
| Temporary shelter functioning as an independent destination | counts | `distinct` |
| Non-residential context feature | not a residential structure | `distinct`, `structure_type='non_residential'` + subtype |
| Same mapper captured both and asserts one unit | 1 structure | `merge` |

### 4.2 `POST /v1/dedup/{id}/decision`

```json
{ "decision": "distinct", "note": "shared wall, two independent entrances — two destinations",
  "classification": { "structure_type": "shared_wall_dwelling",
                      "entrance_independent": true,
                      "is_shared_wall": true,
                      "shares_wall_with": "9a1f…" },
  "code_resolution": "issue_new" }
```

- `merge` → `structure_b` soft-deleted, service rows and breadcrumbs reassigned to `structure_a`, `code_resolution` selects the surviving code, and any `structure_link` rows in `identity_db` for the discarded code are queued for resident notification. **Assignment of the surviving code is a system action following a human decision — never an AI action.** If the merge collapses two entrances into one, the §6.1 outcome is `multi_household_single_entry` and the mapper's independent-entrance flags are reconciled.
- `distinct` → `code_resolution: issue_new` issues `structure_b.code` immediately, `classification` is applied to both structures, and `dedup_threshold_m` for both is updated from the outcome to tune future candidate generation. `shares_wall_with` is written symmetrically.
- `deferred` → returns to queue with a field-revisit task.

### 4.3 `POST /v1/structures/{id}/dedup-threshold`

Reviewer-only. Persists the candidate-generation threshold; the `distinct` decision auto-suggests a value. **This tunes how often a human is asked, never what the answer is.**

### 4.4 QR (M2)

The QR encodes the **public short code** only. It is a derived rendering — never an independent identifier, and never a second identity system.

- `GET /v1/structures/{code}/qr` → returns an SVG/PNG plus the encoded payload, for printing a placard
- The encoding is a function of the code string. **It does not hard-code the code format** (§6.1 keeps the public format provisional), so changing the format is a code-sequence change and placards reprint — no identity migration.
- Scanning a placard resolves the code and redirects to §2.3 (dispatcher) or, for a resident, to the in-app grievance/consent flow. Per §6.5 the grievance flow is **entirely in-app**; the placard is a required physical dependency, not a required app.

```
GET /v1/structures/{code}/qr
→ 200 { "payload": "SLR-C40012", "svg": "…", "svg_sha256": "…" }
```

A scan of an unknown, superseded, or merged-away code returns `404` with a distinct `code_superseded` body — a responder following an out-of-date placard must be told the placard is stale, not merely that the code is unknown.

---

## 5. Dispatch (PRD §3, §5.6)

### 5.0 Dispatch service abstraction

**§3 DECIDED: the internal dispatch interface is the only implemented dispatch backend for this semester.** No CAD/AVL integration is designed or estimated here.

The abstraction exists so a future external backend is additive rather than invasive:

```
                    DispatcherApp
                         │
                    registry-api
                         │
         ┌───────────────┴───────────────┐
         │  DispatchBackend (interface)  │   ← core registry depends on this,
         │  lookup()  dispatch()          │     NOT on any concrete backend
         │  outcome()  capabilities()     │
         └───────────────┬───────────────┘
                         │
            ┌────────────┴────────────┐
            │                         │
  InternalBackend              ExternalBackend (FUTURE)
  (implemented, MVP)            (CAD / AVL / NGO — NOT DESIGNED)
  code → location → route       plugs in here later;
  → responder → outcome         registry core unchanged
```

`registry-api` depends only on the interface. The internal backend is one implementation, selected by configuration. A future external adapter implements the same four methods and is selected by the same configuration switch — no route handler, schema, or client changes.

| Method | Purpose |
|---|---|
| `lookup(code, responder_location, profile)` | Resolve a code to destination + route |
| `dispatch(code, context)` | Hand off to a responder, return `dispatch_id` |
| `outcome(dispatch_id, result)` | Record success/failure → fast signal (§6.4) |
| `capabilities()` | Advertise zone support, profile types, offline routing availability |

**Current MVP flow:** Structure ID → dispatch lookup → location → route → responder → dispatch outcome. This is complete and self-contained without any external system.

### 5.1 `POST /v1/dispatch/lookup`

Role: `dispatcher`. Body: a structure code.

```json
// Request
{ "code": "SLR-C40012", "responder_location": { "lat": 12.9680, "lon": 77.5871 },
  "profile": "foot" }
```

```json
// 200 OK
{ "code": "SLR-C40012",
  "centroid": { "lat": 12.9705, "lon": 77.5905 },
  "address_text": "SLR-C40012, Zone C4 (no street address on record)",
  "zone": { "code": "C4", "dispatch_enabled": true },
  "route": {
    "graph_version": 42,
    "legs": [ { "instructions": "Head north on the main footpath 80 m",
                "geometry": { … }, "distance_m": 80, "confidence": 0.91 } ],
    "total_distance_m": 340, "estimated_minutes": 5.5,
    "warnings": [ { "code": "low_confidence_segment", "segment_id": 881, "note": "single-surveyed path" } ],
    "reachable": true
  },
  "structure": { "status": "verified", "floors_estimated": 2,
                 "access_note": "gate on the south side; stair to level 2" },
  "occupant_context": { "present": false } }
```

Failure modes:

| Status | Meaning |
|--------|---------|
| `404 structure_not_found` | Unknown code |
| `409 code_not_finalized` | Structure still in dedup review — dispatch must not proceed |
| `403 outside_mapped_zone` | Structure centroid outside an enabled zone (PRD §3) |
| `422 no_route` | `reachable:false` — no connected walkable path at current graph version |
| `503 graph_rebuilding` | Graph version mid-rebuild; retry with `Retry-After` |

### 5.2 `POST /v1/dispatch/{code}/outcome`

Role: `dispatcher`. This is the **fast signal** (PRD §6.4).

```json
{ "outcome": "failed", "reason": "gate_locked_no_responder", "observed_geometry": {…},
  "responder_notes": "Access via lane to the north, not the main footpath" }
```

`failed` opens a re-verification task, records a `verification_event(trigger_kind='fast')`, and if `observed_geometry` is >30 m from the registered centroid, additionally flags the structure `unreachable` pending review.

**Responder observation is ground truth (C8).** A responder who reached the scene observed the gate. If their report contradicts a mapper's record, `observed_geometry` becomes a ground-truth assertion with `observed_by = 'dispatch:unit-7'` and supersedes the prior value — the only mechanism by which anything other than inference can overwrite ground truth. A `failed` outcome weighted 1.0 outranks any single unverified resident report.

### 5.3 `GET /v1/dispatch/routes?code=&profile=foot|bicycle`

Direct route access without a dispatch record, for pre-positioning.

---

## 6. Consent & occupant context (PRD §6.3)

### 6.1 `GET /v1/consent/me` — resident

```json
{ "resident": { "alias": "res_7f2a" },
  "consents": [ { "scope": "store_identity", "granted": true, "granted_at": "2026-02-02T10:00:00Z" },
                { "scope": "share_on_dispatch", "granted": false } ],
  "links": [ { "structure_code": "SLR-C40012", "consented_at": "2026-02-02T10:01:00Z" } ] }
```

### 6.2 `PUT /v1/consent/me/{scope}`

```json
{ "granted": true, "policy_version": "2026-03-01" }
```

Revoking `link_to_structure` cascades: `structure_link` rows soft-erased, `structure_code` resolution blocked.

### 6.3 `GET /v1/consent/dispatch/{code}/occupant-context`

Role: `dispatcher`. The **only** endpoint that touches both domains. Audited on every call.

```json
{ "context_present": true, "granted_scopes": ["link_to_structure","share_on_dispatch"],
  "fields": [ { "label": "Preferred language", "value": "Kannada" },
              { "label": "Medical note", "value": "…" } ],
  "consent_expires_at": "2026-09-01T00:00:00Z" }
```

With no consent: `{"context_present": false, "granted_scopes": [], "fields": []}` — HTTP 200, no error, no existence leak. A code with no linked resident and a code with a revoked resident are indistinguishable to the caller.

### 6.4 `DELETE /v1/consent/me` — right to be forgotten

Encrypted PII zeroed, `erased_at` set, structural records untouched. Explicitly confirms that erasing identity does not delete the structure record.

---

## 7. Grievances (PRD §6.5)

### 7.1 `POST /v1/grievances`

Rate limited: 5/hour per `device_hash`, 20/day. Exceeding → `429` with `Retry-After`.

```json
{ "client_op_id": "…", "structure_code": "SLR-C40012",
  "reported_location": { "lat": 12.9706, "lon": 77.5904 },
  "photo_sha256": "…", "body": "Water pipe broken for three days" }
```

Server computes `offset_from_registered_m` and cross-checks; a report beyond 25 m creates or links a `dedup_candidate` instead of asserting a wrong structure. Weight assigned from source, not from client.

### 7.2 `GET /v1/grievances?state=&zone=`

Role: `dispatcher`, `reviewer`, `admin`.

### 7.3 `POST /v1/grievances/{id}/triage`

```json
{ "state": "corroborating", "note": "matches imagery diff for zone C4 from 2026-03-01" }
```

Promoting a resident report to `corroborated` raises its weight to 0.7 and opens a mapper task.

---

## 8. Sync (PRD §5.4)

### 8.1 `POST /v1/sync/push`

Role: `mapper`. Batch, ordered by client `seq`. Fully idempotent via `client_op_id`; replays return the original receipt.

```json
{ "device_id": "dev_9f2b",
  "ops": [ { "client_op_id": "…", "seq": 1024, "table": "local_structure",
             "entity_id": "…", "op": "create", "payload": {…} },
           { "client_op_id": "…", "seq": 1025, "table": "local_breadcrumb",
             "entity_id": "…", "op": "create", "payload": { "geojson": "…", "accuracy_m": 3.1 } } ] }
```

```json
// Response
{ "results": [ { "client_op_id": "…", "server_id": "b21c…", "version": 1,
                 "state": "applied" },
               { "client_op_id": "…", "state": "dedup_required",
                 "dedup_candidate_id": "c07d…" },
               { "client_op_id": "…", "state": "rejected",
                 "reason": "structure_in_dedup_review" } ],
  "server_time": "2026-03-20T08:00:00Z" }
```

Ops are applied in `seq` order; one failing op does not abort the batch, and the client retries only failed ops. Unresolved identity conflicts return `dedup_required` — never a silent merge.

### 8.2 `GET /v1/sync/pull?since=<cursor>&zone=C4&limit=1000`

```json
{ "cursor": "srv:2026-03-20T07:59:12Z:99341", "has_more": true,
  "changes": [ { "table": "local_structure", "entity_id": "…", "op": "update",
                 "payload": {…}, "version": 8 } ],
  "server_time": "2026-03-20T08:00:00Z" }
```

Cursor is opaque and time-ordered; clock skew is handled by `server_time`, never by client wall time.

### 8.3 `GET /v1/sync/bootstrap?zone=C4`

Single call that returns the full mapped zone — structures, service records, graph version, and consent-independent data — for the pre-seed. Deliberately excludes anything identity-related.

### 8.4 `GET /v1/sync/health`

`{ "graph_version": 42, "dedup_open": 14, "server_time": "…", "maintenance": false }` — mappers poll this opportunistically to decide whether a sync window is worth attempting.

---

## 9. Path-graph (PRD §6.2)

**Algorithm DECIDED by the M0 spike (C9 satisfied).** The M0 spike measured four candidates over 6 seeds and k-means+Delaunay failed the gate; the adopted approach is a hybrid — map-matching backbone + restricted Delaunay gap-bridging + adaptive density seeding. See `spike/M0_RESULTS.md` and `architecture.md` §5.8. `algorithm` records provenance per segment so any routing result is traceable to the method that produced it.

### 9.1 `POST /v1/graph/rebuild`

Admin. Triggers incremental build from unclustered breadcrumbs using the M0-selected approach.

```json
{ "mode": "incremental", "algorithm": "hybrid_mapmatch_delaunay",
  "min_cluster_support": 2, "spurious_edge_threshold": 0.35,
  "delaunay_max_edge_factor": 2.5, "seed_count": "adaptive" }
```

`algorithm` is optional and defaults to the M0-approved hybrid. Admin may build a specific approach for comparison, but **only the approved algorithm may serve dispatch routes**; builds from other algorithms are tagged `state='candidate'` and excluded from routing until reviewed.

`seed_count: "adaptive"` replaces the fixed `k` that caused M0's void-bridging failure. `delaunay_max_edge_factor` caps a triangulated edge at a multiple of mean inter-seed spacing, which is what stops the graph bridging empty space between lanes.

Returns `202` with a job handle. Rebuild never blocks dispatch; dispatch pins a `graph_version` for the life of a call.

### 9.2 `GET /v1/graph/jobs/{id}`

`{ "state": "running", "phase": "clustering", "processed": 812, "total": 1503, "version": 43, "algorithm": "hybrid_mapmatch_delaunay", "usable_route_rate": 0.688 }`

### 9.3 `GET /v1/graph/nodes?bbox=` / `GET /v1/graph/segments?bbox=`

Graph inspection for the review console. `segments` returns `confidence`, `derivation`, `algorithm`, `evidence_class`, and `state`, so reviewers can see which paths are single-surveyed and which are still inference-only.

### 9.4 `GET /v1/graph/route?from=&to=&profile=foot`

A* over the walkable graph, used by the M0 spike harness and later validation. Returns legs plus per-segment confidence and evidence class so runs can be scored against ground truth.

### 9.5 `POST /v1/graph/segments/{id}/review`

`{ "passable": true, "note": "confirmed walkable, stepped path" }` — a **human observation**, so this writes a ground-truth assertion and promotes the segment from `state='candidate'` to `state='asserted'`. Reviewer correction of a spurious edge, feeding the next build.

---

## 9A. Assertions — ground truth vs inference (C8)

The endpoints implementing Inference → Candidate → Verification → Ground-truth update. These are the only places a value becomes authoritative, and every one requires an identified observer.

### 9A.1 `GET /v1/structures/{code}/assertions?field=`

Returns the evidence history for a structure's fields, including superseded values — how a reviewer sees *why* the registry believes what it believes.

```json
{ "field": "centroid",
  "current": { "value": {…}, "evidence_class": "ground_truth", "source": "mapper_survey",
               "observed_by": "mapper:4f2a", "observed_at": "2026-03-02T09:14:00Z",
               "state": "asserted" },
  "candidates": [ { "value": {…}, "evidence_class": "inference", "produced_by": "imagery:job-9",
                      "confidence": 0.71, "state": "candidate",
                      "reason": "imagery diff suggests footprint shifted" } ],
  "history": [ { "value": {…}, "evidence_class": "ground_truth", "state": "superseded",
                 "observed_by": "mapper:9c1d", "observed_at": "2026-01-14T11:02:00Z" } ] }
```

A candidate never appears in `current` and never influences a dispatch route's destination.

### 9A.2 `POST /v1/assertions/{id}/verify`

The only path from candidate to ground truth. Requires an authenticated human and records who observed what, when.

```json
{ "outcome": "confirmed", "value": { "lat": 12.9706, "lon": 77.5904 },
  "note": "walked it, gate is on the north side", "supersedes_id": "a07f…" }
```

```json
{ "outcome": "rejected", "note": "imagery shadow, not a real change" }
```

`403 inference_cannot_verify` if the caller is the ML service or any non-human principal. The server writes the new ground-truth row, sets the prior row to `state='superseded'`, and closes the originating task. **Rejection is a first-class outcome** — most imagery candidates should be rejected, and recording that is as valuable as confirming.

### 9A.3 `GET /v1/assertions/candidates?type=&zone=`

The verification worklist: every inference-generated candidate awaiting a human, across change detection, dedup, and path-graph edges. `?type` ∈ `imagery_diff` / `duplicate` / `walk_segment` / `footprint_bootstrap`.

### 9A.4 `POST /v1/inference/candidates`

Internal, ML service only. The **sole** write surface for anything inferred. Enforced three ways: mTLS service identity, a DB role with INSERT-only on `assertion` and no UPDATE grant on `structure`, and the CHECK constraint forcing `state='candidate'`.

```json
{ "entity_table": "structure", "entity_id": "b21c…", "field": "footprint",
  "value": {…}, "produced_by": "imagery:job-9", "confidence": 0.71,
  "reason": "imagery diff suggests footprint shifted" }
```

```json
→ 201 { "assertion_id": "c19a…", "state": "candidate", "verification_task_id": "t88c…",
        "note": "candidate recorded; ground truth untouched" }
```

No endpoint accepts a body by which a caller can set `state='asserted'` on an inference row, and no endpoint lets inference write `structure.code` at all.

---

## 10. Change detection & re-verification (PRD §6.4)

### 10.1 `GET /v1/changes/zones?cadence=slow`

```json
{ "zones": [ { "zone": "C4", "score": 0.71, "signal": "imagery_diff",
               "structures_flagged": 23, "last_imagery_at": "2026-02-28",
               "recommended_window_days": 14 } ],
  "imagery_coverage_gaps": ["C7"] }
```

`score` is an AI prioritization output. It decides **visit order only** and can never change a structure's status, issue a code, or resolve identity. Uncovered zones are returned explicitly rather than silently omitted.

### 10.2 `POST /v1/changes/flags`

Internal (change-detection worker). Records a `verification_event(trigger_kind='slow')` per affected structure and enqueues mapper tasks.

### 10.3 `GET /v1/tasks?assignee=&kind=`

Mapper worklist, combining fast triggers (dispatch failure, grievance) and slow triggers (imagery), with fast-signal items ranked first.

```json
{ "items": [ { "task_id": "t1", "structure_code": "SLR-C40012", "kind": "dispatch_failure",
               "signal": "fast", "priority": 1, "created_at": "2026-03-20T07:41:00Z" },
             { "task_id": "t2", "zone": "C4", "kind": "imagery_resurvey", "signal": "slow",
               "priority": 6 } ] }
```

### 10.4 `POST /v1/tasks/{id}/complete`

`{ "outcome": "confirmed", "fields": { … } }` → writes a verification event and updates the structure.

---

## 11. Admin & audit

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/v1/zones` | Mapped zones, `dispatch_enabled` flags |
| `POST` | `/v1/zones` | Define a zone boundary (pilot setup) |
| `PATCH` | `/v1/zones/{id}` | Toggle `dispatch_enabled` — the pilot's kill switch |
| `GET` | `/v1/users` | Role management, admin only |
| `GET` | `/v1/audit?actor=&target=&from=&to=` | Read-only audit trail |
| `GET` | `/v1/audit/consent-calls` | Every occupant-context access, with actor and timestamp |

---

## 12. Cross-cutting error model

```json
{ "error": "outside_mapped_zone",
  "message": "Structure centroid is outside any dispatch-enabled zone.",
  "code": "SLR-C40012",
  "trace_id": "req_8fa1…" }
```

| Code | HTTP | Notes |
|------|------|-------|
| `dedup_required` | 409 | Identity decision needs a human |
| `structure_in_dedup_review` | 409 | Dispatch blocked until review closes |
| `outside_mapped_zone` | 403 | PRD §3 constraint |
| `no_route` | 422 | Structure exists, path graph disconnected |
| `code_not_finalized` | 409 | No code issued yet |
| `code_superseded` | 404 | Placard/QR is stale — merged away or replaced |
| `rate_limited` | 429 | Grievance channel, with `Retry-After` |
| `stale_version` | 412 | Optimistic concurrency failure on PATCH |
| **`inference_cannot_verify`** | **403** | **Non-human principal attempted to promote a candidate (C8)** |
| **`inference_cannot_overwrite`** | **409** | **Inference write targeted an asserted ground-truth row — trigger refused (C8)** |
| **`service_data_unavailable`** | **403** | **`redacted` policy, or unauthenticated/resident caller (§6.6)** |

Every response carries `X-Request-Id`; every mutating call is written to `audit_log`.

---

## 13. Constraints encoded in this contract

| Constraint | Where it is enforced |
|----------------|----------------------|
| Structure identity not assigned by AI | No AI surface can write `structure.code`; issuance happens only in `POST /dedup/{id}/decision` and `distinct` resolution, both human-triggered. The ML role holds no such grant |
| Possible duplicates require human review | `409 dedup_required`; no merge endpoint exists; CRDT is field-level and confirmed-structures-only |
| Resident identity separate from structural data | Separate DB, separate credentials, no FK; bridged only by the audited §6.3 resolver |
| Offline operation | `client_op_id` idempotency, cursor pull, full-zone bootstrap, all reads locally cached |
| Opportunistic sync | `POST /sync/push` batch + `/sync/health` gate; nothing blocks on connectivity |
| AI limited to defined scope | AI writes only via `POST /v1/inference/candidates` (§9A.4), which can only create `state='candidate'` rows. Path-graph clustering, footprint bootstrap, zone scoring, capture assistance |
| Dispatch within pilot mapped zone | PostGIS containment check in `registry-api` → `403 outside_mapped_zone`; zone toggle is the kill switch |
| **Structure classification is observation, not inference** | `structure_type` / `entrance_independent` are mapper-entered ground-truth assertions; no AI endpoint accepts them |
| **Inference never overwrites ground truth** | `assertion` CHECK forces inference to `state='candidate'`; trigger refuses inference writes over asserted rows → `409 inference_cannot_overwrite`; promotion requires `POST /assertions/{id}/verify` by a human → `403 inference_cannot_verify` |
| **Service data role-gated, never public** | `disclosure_policy` default `aggregate_only`; dispatcher response-shaping; aggregate-only reporting view; unauthenticated → `401`, resident → `403` |
| **Path-graph algorithm not assumed** | `algorithm` recorded per segment; only the M0-approved algorithm serves routes; others stay candidates |

---

## 14. Resolved Questions

**All PRD §7 questions plus the evidence-model and algorithm-gate decisions are RESOLVED.**

1. **§6.1 — RESOLVED.** A structure is *"A physically distinguishable residential unit that can be assigned a unique destination for mapping and emergency dispatch."* Encoded as `structure_type` + `entrance_independent` + `compound_root_id` (§2.1, §4.1). The 12 m threshold is a **candidate-generation** threshold, never the definition; dedup uses GPS proximity, entrance proximity, footprint overlap, photo evidence, mapper assertion, and shared-wall information together (§4.1). Code format remains provisional and decoupled from identity. QR encodes the code and is derived, never an independent identifier (§4.4).
2. **§3 — RESOLVED.** Internal dispatch interface is the only implemented backend. A `DispatchBackend` interface exists (§5.0) so a future CAD/AVL/NGO adapter is additive. No external integration is designed or estimated.
3. **§6.6 — RESOLVED.** *"Structure-level service information is sensitive operational data and is not publicly exposed. Access is role-based; aggregate service statistics may be exposed where appropriate."* Access model per §3.2: public none, mapper field-relevant, dispatcher response-relevant only, municipal/NGO per role, analytics aggregate-only. Service data is **not** PII — it is sensitive without identifying a resident — and is role-gated rather than consent-gated.
4. **Path-graph algorithm — RESOLVED BY MEASUREMENT.** M0 ran against ground truth over 6 seeds. k-means+Delaunay **failed the gate** (dest_reach 0.782, routing 0.818). Adopted a hybrid: map-matching backbone + restricted Delaunay gap-bridging + adaptive density seeding. **PRD §6.2 is contradicted on two points** — k-means+Delaunay under-performs, and seed-and-spline (excluded by §6.2) has the *lowest* spurious-route rate (0.313). Figures are synthetic-trace only; field accuracy remains unvalidated (§8).
5. **Ground truth vs inference — RESOLVED.** `assertion.evidence_class` with a trigger refusing inference over ground truth (§9A). Inference → Candidate → Verification → Ground-truth update is the only permitted flow.

No PRD open questions remain unresolved.

---

## 15. OpenAPI 3.1 artifacts

Generated from this document into `openapi/registry.yaml`, `openapi/consent.yaml`, `openapi/graph.yaml`, `openapi/sync.yaml`. Client SDKs (TS + Dart) generated in CI. Contract tests run against the generated spec in CI so a breaking change fails the build.

*End of API Document*