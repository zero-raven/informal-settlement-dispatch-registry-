# Informal-Settlement Address & Emergency Dispatch Registry — PRD

**Status:** Draft v2 — open for team review
**Owners:** [add names]
**Last updated:** 2026-09-30

A living, offline-first structural registry for un-addressed dwellings, feeding real emergency dispatch — closing the loop that one-time addressing efforts leave open.

---

## Table of Contents

1. [Problem](#1-problem)
2. [Goal](#2-goal)
3. [Pilot Scope](#3-pilot-scope)
4. [System Architecture](#4-system-architecture)
5. [System Flow](#5-system-flow)
6. [Design Decisions](#6-design-decisions)
7. [Open Questions](#7-open-questions)
8. [Known Risks](#8-known-risks)
9. [Contributing](#9-contributing)

---

## 1. Problem

Informal settlements lack addresses. Prior work (Addressing the Unaddressed, Cape Town's QR pilot) solves *initial* addressing only — one-time, static, built for postal/KYC. None close the loop when structures change, get demolished, or turn out unreachable. None route live emergency dispatch.

## 2. Goal

A registry that:

- Assigns stable IDs to un-addressed structures
- Builds a routable path-graph through informal footpaths
- Stays current via feedback, not manual resurvey
- Feeds a real dispatch backend
- Keeps identity separate from location (consent-by-design)

## 3. Pilot Scope

Partial coverage. College campus, standing in for a settlement. Dispatch functions only inside the mapped zone. No real-site access this term.

## 4. System Architecture

| Component | Responsibility |
|---|---|
| Mapper app | Offline capture: pin, photo, breadcrumb, services |
| Structural registry | ID, location, footprint, status, services, last-verified. No PII |
| Consent vault | Resident identity. Separate store. Opt-in only |
| Path-graph service | Walkable network, built from merged breadcrumbs |
| Dedup/review queue | Human check on possible-duplicate structures at sync |
| Dispatch console | Code → location + route lookup |
| Change-detection pipeline | Prioritizes re-survey zones from imagery |
| Grievance channel | In-app complaint, geo+photo tagged |

## 5. System Flow

1. **Bootstrap** — Candidate structure footprints pre-loaded from open building-footprint datasets, where regional coverage exists.
2. **Map** — Mapper walks offline. Confirms/adjusts bootstrapped pins or drops new ones. Captures photo, material, service connections, GPS breadcrumb from road to door.
3. **ID assignment** — One stable code per structure, checked against the dedup queue before finalizing (§6.1).
4. **Sync** — Opportunistic, whenever connectivity appears. Full offline capability otherwise.
5. **Path-graph build** — Breadcrumbs across mappers merged into one walkable graph (§6.2).
6. **Dispatch** — Dispatcher looks up code, gets location + route, sends responder.
7. **Feedback loop** — Failed dispatch or resident complaint both re-trigger verification. Same mechanism updates emergency and service data.
8. **Change detection** — Imagery diffing flags likely-changed zones for mapper revisit. Slow cadence, not real-time (§6.4).

## 6. Design Decisions

### 6.1 Structure identity & dedup
One code per physical structure, idempotent on revisit — not geohash-derived. Idempotency enforced, not assumed: on sync, any new structure within a tuned proximity radius of an already-synced one is flagged as a possible duplicate and routed to human review, rather than auto-merged. CRDT-style merge used only for field-level edits to an *already-confirmed* structure, never for identity resolution.

### 6.2 Path-graph construction
Breadcrumbs merged via incremental k-means-style clustering plus weighted Delaunay triangulation for connectivity, over seed-and-spline map-matching — the latter has no mechanism to suppress spurious paths from noisy traces, a real risk in dense, irregular alley layouts. Scoped as its own validated sub-milestone (synthetic/campus traces) before integration.

### 6.3 Consent
Identity opt-in, stored separately from structural data, by default. Dispatch carries no occupant context unless the resident opted in — accepted trade-off, since occupant context is normally only available after responders reach the scene anyway.

### 6.4 Imagery & re-verification cadence
Two-speed model:
- **Fast signal:** dispatch failure + resident complaint. Real-time.
- **Slow signal:** imagery diffing. Weeks-to-months cadence, bounded by free-imagery refresh rates — commissioned few-day capture is out of scope (cost, drone logistics).

Free open building-footprint datasets used as bootstrap layer and slow-cadence baseline, not a live-change source.

### 6.5 Grievance channel
QR placard dropped as a required dependency; grievance reporting lives entirely in-app. Each report is geo- and photo-tagged, cross-checked against the structure's registered location, rate-limited per device/account, and weighted by `verification_method` (dispatch-feedback-sourced updates outrank a single unverified resident report until corroborated).

### 6.6 Service-connection data
Stored as structured records per service (type, source, supply hours, quality, shared-with count, last-verified, verification method), not a binary flag. Same re-verification mechanism as structural status: full survey once, cheap "still true?" checks after.

### 6.7 AI scope
Used for: path-graph clustering, structure-footprint bootstrapping, change-detection prioritization, low-literacy capture assistance. Deliberately excluded from: ID assignment, sync conflict/identity resolution.

### 6.8 Dispatch backend (pilot)
For the campus pilot: the team builds both the mapper app and a minimal internal dispatcher console — no real municipal/NGO backend integration this term. Interface is a synchronous lookup (code → location + route); a lightweight "changed since last look" flag is a stretch goal, not a requirement. Demo is a live simulated call → lookup → route → feedback walkthrough, since this is what proves the core "living registry" claim end-to-end. Real-backend integration is documented as future work, not solved now. See §7 for the deployment-scale version of this question, still open.

### 6.9 Service-data privacy posture (pilot default)
Adopted as the pilot's working stance, pending mentor input (§7):
- **Threat model:** treat structure-level service data as re-identifiable in practice (location + attributes can be matched to a resident by anyone locally familiar with the area), even with no PII fields.
- **Access:** role-gated internally — a dispatcher sees location/route on lookup, not full service history; aggregate service data is separated from per-structure detail.
- **Purpose limitation:** any real-world handoff states this data is for dispatch/service-prioritization only, not enforcement or planning — a stated principle now, not a technically enforced control, since no real partner exists yet to bind it to.
- **Retention:** bounded — archive (not delete) on confirmed demolition/departure, with a removal-request path folded into the existing grievance channel.

## 7. Open Questions

Each of these is unresolved and needs a team/mentor decision before implementation locks in. Options are listed neutrally; a **✅ Leaning** marker shows the pilot's working default where one has been proposed — not a final answer.

### 7.1 Structure definition for partitioned/shared dwellings
*For mentor discussion — no default proposed.*

| Option | Description |
|---|---|
| Physical/footprint-based | One structure = one contiguous roofline/footprint, regardless of how many households live inside |
| Household/unit-based | One structure = one dwelling unit; a partitioned building with 3 families becomes 3 registry entries at one location |
| Hybrid (building + unit) | Physical structure is the primary entity (gets the code); dwelling units are sub-records nested under it for service/complaint data |

This decision sets the dedup radius (§6.1) and how granular service-connection data (§6.6) can get — downstream of everything else, so worth settling early.

### 7.2 Dispatch backend, deployment scale
*Pilot default set in §6.8 (build both sides internally, synchronous lookup, simulated demo). This question is about beyond the pilot.*

| Option | Merit | Demerit |
|---|---|---|
| ✅ Build both sides internally (pilot default) | Full control, no external dependency, matches campus scope | Doesn't prove real-world adoption friction |
| Partner with a real org (e.g. campus security as stand-in) | Genuine institutional user, tests real usage | Needs approval lead time, scope-creep risk |
| Mock a real backend's API shape, no real partner | Signals production-readiness | Designing against unconfirmed assumptions |

### 7.3 Service-data privacy risk
*Pilot default set in §6.9. Recommended for mentor discussion since community-facing data ethics isn't a purely internal engineering call.*

| Stance | Merit | Demerit |
|---|---|---|
| ✅ Treat as re-identifiable despite no PII (pilot default) | Forces real access-control design, matches how location+attribute data is actually treated in privacy research | Adds friction; complicates the "no PII, low risk" pitch in the original abstract |
| Treat as low-risk since no PII attached | Simpler system, matches original abstract framing | Ignores indirect re-identification and purpose-drift risk (e.g. repurposing for eviction targeting) |
| Open access within the org, no role-gating | Simplest to build at pilot scale | No blast-radius containment if credentials leak or a partner repurposes access later |

## 8. Known Risks

- Path-graph clustering accuracy under real GPS noise — unvalidated beyond synthetic/campus traces
- Open building-footprint model accuracy on informal structures specifically — historically the hardest case for these models
- Manual dedup review queue is a scaling bottleneck beyond pilot size
- Regional coverage gaps in free imagery/footprint datasets
- Purpose-limitation principles (§6.9) are stated, not technically enforced — a real deployment needs a governance mechanism this pilot doesn't build

## 9. Contributing

This PRD is a living document for the team. To propose a change:

1. Open a discussion/PR against this file rather than editing silently — design decisions (§6) affect downstream architecture.
2. If resolving an open question (§7), update both the decision's home section *and* remove/update its §7 entry in the same change.
3. Flag anything that changes an already-adopted decision clearly (e.g. `~~old~~ → new`) so the rationale trail isn't lost.
