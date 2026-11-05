# SOP / Runbook — Pilot Operation

## Mapper
1. Offline-first: SQLite local; pin drop + photo (SHA-256); `entrance_independent` observed, not inferred.
2. Sync: opportunistic push on connectivity; replay by `client_op_id`; kill/relaunch safe.

## Dispatcher
- Only enabled zones (§3); `supportsExternalHandoff: false`; code validation + zone containment before route.
- Occupant context absent; `present: false`; no PII in response.

## Reviewer (dedup / code)
- Human-only; no auto-merge; code issued only inside a decision; survivor coded.

## Grievance (M7)
- Rate: 5/h + 20/d per device; weight order enforced (`dispatch_feedback` > corroborated > mapper > imagery > resident).
- >25m from registered → dedup, not assertion. Photo + geo required.

## Imagery (M7)
- Produces `candidate` only; no FK to `structure`; `imagery_coverage_gaps` reported explicitly.

## Security
- Audit includes refusals; consent revocation = deep-equal to never-linked; PII zeroed; structural data untouched.
