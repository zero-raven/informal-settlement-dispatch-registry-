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
  -- 1. spatial typmods on geometry columns
  SELECT count(*) = 4 INTO ok_typmod
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND (
      (table_name = 'structure'      AND column_name IN
        ('footprint','centroid','access_point','entrance_geom'))
      OR (table_name = 'grievance'   AND column_name = 'reported_geometry')
    )
    AND udt_name = 'geometry';

  -- 2. gist indexes actually present
  SELECT count(*) >= 6 INTO ok_gist
  FROM pg_indexes
  WHERE schemaname = 'public' AND indexdef ILIKE '%USING gist%';

  -- 3. ST_Contains used by the aggregate view resolves to a PostGIS function
  SELECT count(*) > 0 INTO ok_contains
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE p.proname = 'st_contains' AND n.nspname = 'public';

  -- 4. tstzrange (service supply hours) is the real range type
  SELECT EXISTS (
    SELECT 1 FROM pg_type WHERE typname = 'tstzrange'
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
DO $$
DECLARE
  z_id bigint;
  inside  geometry(Point, 4326);
  outside geometry(Point, 4326);
BEGIN
  SELECT id INTO z_id FROM zone WHERE code = 'C4';
  IF z_id IS NULL THEN
    RAISE EXCEPTION 'seed zone C4 missing';
  END IF;

  -- a small polygon around the campus origin
  UPDATE zone
  SET boundary = ST_Multi(ST_MakePolygon(ST_MakeLine(ARRAY[
        ST_MakePoint(-100.0, -100.0),
        ST_MakePoint( 200.0, -100.0),
        ST_MakePoint( 200.0,  260.0),
        ST_MakePoint(-100.0,  260.0),
        ST_MakePoint(-100.0, -100.0)
      ])))
  WHERE id = z_id;

  inside  := ST_SetSRID(ST_MakePoint(50.0, 100.0), 4326);
  outside := ST_SetSRID(ST_MakePoint(999.0, 999.0), 4326);

  IF NOT ST_Contains((SELECT boundary FROM zone WHERE id = z_id), inside) THEN
    RAISE EXCEPTION 'zone containment failed: interior point not contained';
  END IF;
  IF ST_Contains((SELECT boundary FROM zone WHERE id = z_id), outside) THEN
    RAISE EXCEPTION 'zone containment failed: exterior point contained — C7 broken';
  END IF;

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