-- 002_feedback.sql — feedback and re-verification engine (PRD 6.4, C8).
--
-- Adds the mapper worklist and the candidate lifecycle. A rejected candidate is
-- a distinct terminal state, NOT a deletion: recording that most imagery
-- candidates are rejected is a result the system must be able to report.

-- ---------------------------------------------------------------------------
-- Extend assertion_state with 'rejected'.
--
-- assertion_state is SHARED by assertion.state, walk_segment.state and
-- zone_priority.state. Dropping and recreating the type breaks all three, so
-- the enum is altered IN PLACE, which preserves every dependent column.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'assertion_state' AND n.nspname = 'public'
  ) THEN
    CREATE TYPE assertion_state AS ENUM ('asserted', 'candidate', 'superseded');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'assertion_state' AND n.nspname = 'public'
      AND e.enumlabel = 'rejected'
  ) THEN
    ALTER TYPE assertion_state ADD VALUE 'rejected';
  END IF;
END $$;

-- The mapper worklist. signal_rank keeps fast work above slow work in the
-- ORDER BY, so a ranking bug cannot demote an emergency.
CREATE TABLE IF NOT EXISTS task (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  structure_id uuid REFERENCES structure(id),
  zone         text,
  kind         text NOT NULL,
  signal       text NOT NULL CHECK (signal IN ('fast','slow','manual','bootstrap')),
  signal_rank  smallint NOT NULL DEFAULT 1,
  priority     integer NOT NULL DEFAULT 5,
  state        text NOT NULL DEFAULT 'open'
                 CHECK (state IN ('open','in_progress','deferred','done','cancelled')),
  assignee     text,
  note         text,
  outcome      text CHECK (outcome IN ('confirmed','rejected','inconclusive')),
  payload_json jsonb,
  completed_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS task_worklist_idx
  ON task (state, signal_rank, priority, created_at) WHERE state = 'open';

-- Candidate worklist: every inference awaiting a human, newest first.
CREATE INDEX IF NOT EXISTS assertion_pending_idx
  ON assertion (source, created_at DESC)
  WHERE evidence_class = 'inference' AND state = 'candidate';

-- An inference candidate can never become the current value for a field.
-- This is the C8 invariant at the storage layer: no code path, including a
-- future migration, can promote inference to ground truth by accident.
ALTER TABLE assertion DROP CONSTRAINT IF EXISTS inference_only_candidates;
ALTER TABLE assertion ADD CONSTRAINT inference_never_asserted CHECK (
  evidence_class <> 'inference' OR state <> 'asserted'
);

-- A zone- or bootstrap-level task has no single structure; the audit trail must
-- accept that rather than refusing the record.
ALTER TABLE verification_event
  ALTER COLUMN structure_id DROP NOT NULL;
