# ADR — Informal Settlement Registry (clg/el)

## ADR-001: Algorithm choice (M0)
- PRD §6.2 proposed: k-means + weighted Delaunay → REJECTED (dest reach 0.782, 7 components, void-seeding failure).
- PRD §6.2 excluded: seed-and-spline → ADOPTED (lowest spurious rate 0.313; contradiction of PRD rationale documented).
- Final: hybrid (map-matching backbone + restricted Delaunay + adaptive seeding + explicit spurious suppression).

## ADR-002: Identity isolation (C3)
- Separate Postgres container (`identity_db`); different credentials; no FK; consent-api is the only read-only audited bridge; absence = default response.

## ADR-003: Inference over ground truth (C8)
- `assertion` table with `evidence_class`; DB trigger rejects inference writes over ground truth. Candidate → verified → superseded is a literal transaction.

## ADR-004: Service data vs PII (M6)
- Service data = role-gated (never consent-gated); aggregate view (`zone_priority`) exposes no per-structure column; dispatcher shaping is response-shaping (omits types, does not mask fields).
