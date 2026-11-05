M7 Grievance — Triage State Machine and Evidence Criteria
============================================================

Status: DESIGNED (pre-implementation). No real-world grievance data claimed.
Synthetic test inputs only. Field validation deferred.

State Machine
-------------

received (default)
  |
  | POST /v1/grievances/{id}/triage  -> state='corroborating'
  v
corroborating
  |  - Evidence weight < 0.5: stays corroborating until additional signal
  |  - Evidence weight >= 0.5 (e.g. dispatch_feedback=1.0, grievance_corroborated=0.7,
  |    or combined signals crossing threshold): can transition to confirmed
  v
confirmed  (weight >= 0.5, mapped to mapper priority 1 task)
  |
  | If rejected (false report, resolved, no structure match): terminal
  v
rejected  (terminal; ground truth untouched)

Criteria for corroborated
--------------------------
- Source signal must have WEIGHT_ORDER >= 0.6, OR
- Multiple independent signals with combined evidence >= 0.7, OR
- A single `dispatch_feedback` (1.0) automatically corroborates.
- A single unverified `resident_report` (0.1) NEVER corroborates alone (per PRD §6.4 / docs/development-plan.md).

Mapper task trigger
-------------------
- On transition to `corroborating`: open a mapper task at priority 1 (fast signal outranks slow).
- On transition to `confirmed`: task remains open until mapper verifies or rejects.
- On `rejected`: task is closed; no ground-truth mutation occurs.

Rate limits (per device_hash)
----------------------------
- 5/hour, 20/day. Exceed -> 429 with Retry-After.
- Applied at HTTP edge before DB write.

Cross-check (>25m offset)
-------------------------
- `offset_from_registered_m` computed against `structure` entry_point.
- If > 25 m: create/link `dedup_candidate` instead of asserting wrong structure (per docs/api.md §7.1).

Synthetic test scope (this phase)
--------------------------------
- Complaints use synthetic `structure_code`, synthetic geo, synthetic photo_sha256.
- No real settlement data, no real resident PII.
- All test outputs explicitly labelled synthetic.
