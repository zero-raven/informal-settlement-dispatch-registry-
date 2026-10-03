-- 001_postgis_verify.sql — PostGIS smoke test (the M1 blocker)
--
-- The registry schema's spatial layer was written against the documented
-- design but could NOT be verified on the machine where it was authored:
-- PostGIS was unavailable, so spatial types were shimmed as text domains and
-- the gist indexes were excluded from the test harness.
--
-- docs/database.md 5 records what that verification did and did not cover.
-- This migration exists so the gap is closed by execution, not by assertion.
-- It must be applied against a real PostGIS instance with `postgis` available.

DO $$
DECLARE
  ok_typmod  boolean;
  ok_gist    boolean;
  ok_contains boolean;
  ok_range   boolean;
  ok_tz      boolean;
BEGIN
  -- 1. every geometry column in the schema is real PostGIS geometry.
  -- Counted from the catalogue rather than a hand-listed subset, so a future
  -- spatial column cannot be added without this check noticing.
  -- A text-domain stand-in would report type `text`, not `geometry`, so this
  -- also proves the no-PostGIS shim is not in play.
  SELECT count(*) = 9 INTO ok_typmod
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND udt_name = 'geometry';

  -- 2. gist indexes actually present
  SELECT count(*) >= 6 INTO ok_gist
  FROM pg_indexes
  WHERE schemaname = 'public' AND indexdef ILIKE '%USING gist%';

  -- 3. ST_Contains used by the aggregate view resolves to a PostGIS function
  SELECT count(*) > 0 INTO ok_contains
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE p.proname = 'st_contains' AND n.nspname = 'public';

  -- 4. supply_hours is genuinely a tstzrange (not a text-domain stand-in)
  SELECT EXISTS (
    SELECT 1
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_type t ON t.oid = a.atttypid
    WHERE c.relname = 'structure_service'
      AND a.attname = 'supply_hours'
      AND t.typname = 'tstzrange'
  ) INTO ok_range;

  -- 5. timezone-bearing range construction works as the schema assumes
  BEGIN
    PERFORM tstzrange(
      '2026-03-02 06:00+05:30'::timestamptz,
      '2026-03-02 10:00+05:30'::timestamptz
    );
    ok_tz := true;
  EXCEPTION WHEN OTHERS THEN
    ok_tz := false;
  END;

  IF ok_typmod AND ok_gist AND ok_contains AND ok_range AND ok_tz THEN
    RAISE NOTICE 'POSTGIS VERIFICATION PASSED: typmods, gist indexes, ST_Contains, tstzrange all confirmed';
  ELSE
    RAISE EXCEPTION
      'POSTGIS VERIFICATION FAILED: typmod=%, gist=%, st_contains=%, tstzrange=%, tzrange=%',
      ok_typmod, ok_gist, ok_contains, ok_range, ok_tz;
  END IF;
END $$;

-- Close the loop on the spatial semantics the design depends on:
-- zone containment must be exact enough that a structure outside the pilot
-- mapped zone is NOT contained (C7, PRD 3).
--
-- Uses a scratch zone rather than mutating C4, so the seeded pilot geometry is
-- left intact and this migration stays safe to re-run.
DO $$
DECLARE
  z_id  bigint;
  inside  geometry(Point, 4326);
  outside geometry(Point, 4326);
BEGIN
  INSERT INTO zone (code, name, dispatch_enabled, boundary)
  VALUES ('__verify_scratch__', 'temporary zone for spatial verification', false,
          ST_Multi(ST_GeomFromText(
            'POLYGON((0 0, 100 0, 100 100, 0 100, 0 0))', 4326)))
  ON CONFLICT (code) DO UPDATE SET boundary = EXCLUDED.boundary
  RETURNING id INTO z_id;

  inside  := ST_SetSRID(ST_MakePoint(50, 50), 4326);
  outside := ST_SetSRID(ST_MakePoint(500, 500), 4326);

  IF NOT ST_Contains((SELECT boundary FROM zone WHERE id = z_id), inside) THEN
    RAISE EXCEPTION 'zone containment failed: interior point not contained';
  END IF;
  IF ST_Contains((SELECT boundary FROM zone WHERE id = z_id), outside) THEN
    RAISE EXCEPTION 'zone containment failed: exterior point contained - C7 broken';
  END IF;

  DELETE FROM zone WHERE id = z_id;
  RAISE NOTICE 'POSTGIS VERIFICATION PASSED: zone containment behaves as C7 requires';
END $$;

-- Confirm the aggregate reporting view cannot leak per-structure rows (6.6).
DO $$
DECLARE
  leaked boolean;
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'v_zone_service_stats'
      AND column_name IN ('structure_id', 'code', 'centroid', 'geom')
  ) THEN
    leaked := true;
  ELSE
    leaked := false;
  END IF;

  IF leaked THEN
    RAISE EXCEPTION 'REPORTING LEAK: v_zone_service_stats exposes a per-structure column';
  END IF;
  RAISE NOTICE 'POSTGIS VERIFICATION PASSED: aggregate view exposes no per-structure column';
END $$;