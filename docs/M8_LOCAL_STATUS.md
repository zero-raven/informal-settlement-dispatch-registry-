M8 — Integration + Local Test Results (Synthetic / Deferred)
==============================================================
Status: PARTIAL (local synthetic only; deployment-dependent deferred)
Updated: per user's M7/M8 scope directive.

M0 Regression (Synthetic)
-------------------------
- Source: `spike/data/` synthetic traces only. No `lane_entry_exit.gpx`.
- Command: `cd spike && ./.venv-spike/bin/python m0_multiseed.py`
- Result: hybrid passes corrected gate (`usable_route_rate` 0.396 > baseline 0.036); single-component; destination reach 1.000.
- Field accuracy: UNVERIFIED. No campus GPS capture performed. No field recordings claimed.
- Note: M0's original gate (destination reach) mis-specified; corrected to `usable_route_rate`. PRD §6.2 superseded remains superseded; PRD unchanged.

100-Structure Dry Run
--------------------
- Status: NOT PERFORMED. Requires either:
  a) 100 synthetic structures in `spike/fixtures/` (current fixtures: 50 seed structures in `services/registry-api/migrations/000_init.sql`), OR
  b) Real campus capture (blocked by GPS device absence).
- Current synthetic set: 50 structures, 200 breadcrumbs, 10 grievances.
- Action required from user: confirm dry-run scale (synthetic 100 vs real field survey) and provide GPS capture device for real survey.

Synthetic Imagery Pipeline (M7)
-------------------------------
- `imagery_diff.js`: skeleton implemented. Produces candidates with `state='candidate'`.
- Coverage gaps: explicitly reported (`imagery_coverage_gaps`) — never silently omitted.
- Real imagery source: NOT INTEGRATED. Free imagery for zones C4/C9 unavailable.
- Change detection claims for zones C4/C9: NONE. Synthetic-only.

Grievance Workflow (M7 — Implemented)
-------------------------------------
- Endpoints: `POST /v1/grievances`, `GET /v1/grievances`, `POST /v1/grievances/{id}/triage`
- Rate limits: 5/hour, 20/day per `device_hash` (in-memory synthetic enforcement)
- State machine: received -> corroborating -> confirmed/rejected (documented in `docs/M7_TRIGE_STATE_MACHINE.md`)
- Evidence weights: dispatch_feedback (1.0) > grievance_corroborated (0.7) > mapper_survey (0.6) > imagery_diff (0.4) > resident_report (0.1)
- Corroboration threshold: weight >= 0.5
- Cross-check: offset > 25m from registered structure -> `dedup_candidate` (not direct assertion)
- Mapper task trigger: `corroborating` or `confirmed` opens priority-1 task
- Synthetic label: `synthetic=true` present on all grievance endpoint responses
- Tests: 7 synthetic assertions pass (`test/grievance.test.js`)

Deferred to Later Phase (Explicit)
----------------------------------
- Live-cluster load test (25 concurrent mappers, sync burst) — deferred until deployment infrastructure available.
- Security review (audit verification, backup/restore) — deferred until live deployment.
- Real field GPS capture (`lane_entry_exit.gpx`) — deferred until capture device available.
- Real imagery-source integration (free imagery for C4/C9) — deferred.
- PRD amendment (§6.2 superseded) — NOT DONE (per user's instruction: keep PRD unchanged).

Verified Baseline (Unchanged)
----------------------------
- `scripts/verify-all.sh`: 70 assertions across 6 suites — ALL GREEN.
- Constraint tests C1–C9: enforced (database triggers, permissions, assertions).
- New grievance assertions: 7 synthetic assertions added; do NOT replace the 70 verified assertions.
