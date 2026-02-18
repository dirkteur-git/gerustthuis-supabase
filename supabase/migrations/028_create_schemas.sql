-- ============================================================
-- GerustThuis - Migratie 028: Database Schema Organisatie
--
-- Maakt aparte schemas aan en verhuist tabellen zodat de
-- frontend code (die al .schema('integrations') etc. gebruikt)
-- correct werkt via PostgREST.
--
-- VEILIG OM MEERDERE KEREN UIT TE VOEREN (idempotent)
-- Datum: 2026-02-18
-- ============================================================

-- ============================================================
-- STAP 1: Schemas aanmaken
-- ============================================================

CREATE SCHEMA IF NOT EXISTS integrations;
CREATE SCHEMA IF NOT EXISTS activity;
CREATE SCHEMA IF NOT EXISTS planning;

-- ============================================================
-- STAP 2: Grants voor PostgREST rollen
-- Zonder USAGE grant kan PostgREST de schemas niet benaderen.
-- ============================================================

GRANT USAGE ON SCHEMA integrations TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA activity TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA planning TO anon, authenticated, service_role;

-- ============================================================
-- STAP 3: Tabellen verhuizen naar integrations schema
-- ALTER TABLE SET SCHEMA behoudt RLS policies, triggers, indexes
-- ============================================================

DO $$
BEGIN
    -- integrations schema
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'hue_config') THEN
        ALTER TABLE public.hue_config SET SCHEMA integrations;
        RAISE NOTICE '  ✓ hue_config → integrations';
    ELSE
        RAISE NOTICE '  - hue_config: al verhuisd of bestaat niet';
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'hue_devices') THEN
        ALTER TABLE public.hue_devices SET SCHEMA integrations;
        RAISE NOTICE '  ✓ hue_devices → integrations';
    ELSE
        RAISE NOTICE '  - hue_devices: al verhuisd of bestaat niet';
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'physical_devices') THEN
        ALTER TABLE public.physical_devices SET SCHEMA integrations;
        RAISE NOTICE '  ✓ physical_devices → integrations';
    ELSE
        RAISE NOTICE '  - physical_devices: al verhuisd of bestaat niet';
    END IF;

    -- activity schema
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'activity_events') THEN
        ALTER TABLE public.activity_events SET SCHEMA activity;
        RAISE NOTICE '  ✓ activity_events → activity';
    ELSE
        RAISE NOTICE '  - activity_events: al verhuisd of bestaat niet';
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'room_activity_hourly') THEN
        ALTER TABLE public.room_activity_hourly SET SCHEMA activity;
        RAISE NOTICE '  ✓ room_activity_hourly → activity';
    ELSE
        RAISE NOTICE '  - room_activity_hourly: al verhuisd of bestaat niet';
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'daily_activity_stats') THEN
        ALTER TABLE public.daily_activity_stats SET SCHEMA activity;
        RAISE NOTICE '  ✓ daily_activity_stats → activity';
    ELSE
        RAISE NOTICE '  - daily_activity_stats: al verhuisd of bestaat niet';
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'sensor_health_history') THEN
        ALTER TABLE public.sensor_health_history SET SCHEMA activity;
        RAISE NOTICE '  ✓ sensor_health_history → activity';
    ELSE
        RAISE NOTICE '  - sensor_health_history: al verhuisd of bestaat niet';
    END IF;

    -- planning schema
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'project_phases') THEN
        ALTER TABLE public.project_phases SET SCHEMA planning;
        RAISE NOTICE '  ✓ project_phases → planning';
    ELSE
        RAISE NOTICE '  - project_phases: al verhuisd of bestaat niet';
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'project_tickets') THEN
        ALTER TABLE public.project_tickets SET SCHEMA planning;
        RAISE NOTICE '  ✓ project_tickets → planning';
    ELSE
        RAISE NOTICE '  - project_tickets: al verhuisd of bestaat niet';
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'phase_criteria') THEN
        ALTER TABLE public.phase_criteria SET SCHEMA planning;
        RAISE NOTICE '  ✓ phase_criteria → planning';
    ELSE
        RAISE NOTICE '  - phase_criteria: al verhuisd of bestaat niet';
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'phase_purchases') THEN
        ALTER TABLE public.phase_purchases SET SCHEMA planning;
        RAISE NOTICE '  ✓ phase_purchases → planning';
    ELSE
        RAISE NOTICE '  - phase_purchases: al verhuisd of bestaat niet';
    END IF;

    -- Optionele tabellen (bestaan mogelijk niet)
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'phase_decisions') THEN
        ALTER TABLE public.phase_decisions SET SCHEMA planning;
        RAISE NOTICE '  ✓ phase_decisions → planning';
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'ticket_dependencies') THEN
        ALTER TABLE public.ticket_dependencies SET SCHEMA planning;
        RAISE NOTICE '  ✓ ticket_dependencies → planning';
    END IF;
END $$;

-- ============================================================
-- STAP 4: Grants op tabellen in nieuwe schemas
-- PostgREST heeft SELECT/INSERT/UPDATE/DELETE nodig
-- ============================================================

-- integrations
GRANT ALL ON ALL TABLES IN SCHEMA integrations TO anon, authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA integrations TO anon, authenticated, service_role;

-- activity
GRANT ALL ON ALL TABLES IN SCHEMA activity TO anon, authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA activity TO anon, authenticated, service_role;

-- planning
GRANT ALL ON ALL TABLES IN SCHEMA planning TO anon, authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA planning TO anon, authenticated, service_role;

-- Default privileges voor toekomstige tabellen
ALTER DEFAULT PRIVILEGES IN SCHEMA integrations GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA activity GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA planning GRANT ALL ON TABLES TO anon, authenticated, service_role;

-- ============================================================
-- STAP 5: SECURITY DEFINER functies updaten met search_path
--
-- Door SET search_path toe te voegen kunnen de functies
-- tabellen in alle schemas vinden zonder de body te wijzigen.
-- ============================================================

-- 5a. get_accessible_config_ids (uit migratie 025)
-- Referenties: user_profiles (public), hue_config (integrations),
--              household_members (public), households (public)
CREATE OR REPLACE FUNCTION get_accessible_config_ids()
RETURNS SETOF UUID AS $$
DECLARE
    v_user_id UUID;
    v_user_email TEXT;
BEGIN
    v_user_id := auth.uid();
    v_user_email := auth.jwt() ->> 'email';

    -- Superadmin: alle configs
    IF EXISTS (
        SELECT 1 FROM user_profiles
        WHERE id = v_user_id AND is_superadmin = true
    ) THEN
        RETURN QUERY SELECT id FROM hue_config;
        RETURN;
    END IF;

    -- Reguliere user: via household_members
    RETURN QUERY
    SELECT DISTINCT h.config_id
    FROM household_members hm
    JOIN households h ON hm.household_id = h.id
    WHERE hm.user_id = v_user_id AND h.config_id IS NOT NULL;

    -- Fallback: directe email match (backward compat)
    RETURN QUERY
    SELECT id FROM hue_config
    WHERE user_email = v_user_email
      AND id NOT IN (
          SELECT h2.config_id FROM household_members hm2
          JOIN households h2 ON hm2.household_id = h2.id
          WHERE hm2.user_id = v_user_id AND h2.config_id IS NOT NULL
      );

    RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE
   SET search_path = public, integrations;

-- 5b. aggregate_hourly_activity (uit migratie 016)
-- Referenties: room_activity_hourly (activity), activity_events (activity),
--              hue_devices (integrations)
CREATE OR REPLACE FUNCTION aggregate_hourly_activity(p_hours_back INTEGER DEFAULT 2)
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER := 0;
BEGIN
    INSERT INTO room_activity_hourly (config_id, room_name, hour, motion_events, door_events, total_events)
    SELECT
        d.config_id,
        d.room_name,
        date_trunc('hour', e.recorded_at) AS hour,
        COUNT(*) FILTER (WHERE d.device_type = 'motion_sensor') AS motion_events,
        COUNT(*) FILTER (WHERE d.device_type = 'contact_sensor') AS door_events,
        COUNT(*) AS total_events
    FROM activity_events e
    JOIN hue_devices d ON e.device_id = d.id
    WHERE d.room_name IS NOT NULL
      AND d.config_id IS NOT NULL
      AND e.recorded_at >= NOW() - (p_hours_back || ' hours')::INTERVAL
    GROUP BY d.config_id, d.room_name, date_trunc('hour', e.recorded_at)
    ON CONFLICT (config_id, room_name, hour)
    DO UPDATE SET
        motion_events = EXCLUDED.motion_events,
        door_events = EXCLUDED.door_events,
        total_events = EXCLUDED.total_events,
        updated_at = NOW();

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
   SET search_path = public, activity, integrations;

-- 5c. refresh_daily_activity_stats (uit migratie 017)
-- Referenties: hue_config (integrations), daily_activity_stats (activity)
CREATE OR REPLACE FUNCTION refresh_daily_activity_stats(
    p_config_id UUID DEFAULT NULL,
    p_days_back INTEGER DEFAULT 7
) RETURNS TABLE(config_id UUID, date DATE, total_events INTEGER) AS $$
DECLARE
    v_config RECORD;
    v_date DATE;
BEGIN
    FOR v_config IN
        SELECT hc.id FROM hue_config hc
        WHERE (p_config_id IS NULL OR hc.id = p_config_id)
          AND hc.status = 'active'
    LOOP
        FOR v_date IN
            SELECT generate_series(
                CURRENT_DATE - p_days_back,
                CURRENT_DATE,
                '1 day'::interval
            )::date
        LOOP
            PERFORM calculate_daily_activity_stats(v_config.id, v_date);

            RETURN QUERY
            SELECT v_config.id, v_date,
                   (SELECT das.total_events FROM daily_activity_stats das
                    WHERE das.config_id = v_config.id AND das.date = v_date);
        END LOOP;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
   SET search_path = public, activity, integrations;

-- 5d. calculate_daily_activity_stats (uit migratie 020)
-- Referenties: hue_devices (integrations), activity_events (activity),
--              daily_activity_stats (activity)
CREATE OR REPLACE FUNCTION calculate_daily_activity_stats(
    p_config_id UUID,
    p_date DATE
) RETURNS void AS $$
DECLARE
    v_events RECORD;
    v_rooms_available INTEGER;
    v_events_per_hour INTEGER[] := ARRAY[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0];
    v_active_hours INTEGER := 0;
    v_night_events INTEGER := 0;
    v_night_hours INTEGER := 0;
    v_motion_events INTEGER := 0;
    v_door_events INTEGER := 0;
    v_hour INTEGER;
    v_hour_count INTEGER;
BEGIN
    -- Bereken rooms_available
    SELECT COUNT(DISTINCT room_name) INTO v_rooms_available
    FROM hue_devices
    WHERE config_id = p_config_id
      AND device_type IN ('motion_sensor', 'contact_sensor', 'light');

    -- Haal event stats op
    SELECT
        COUNT(*) as total_events,
        MIN(recorded_at)::time as first_activity,
        MAX(recorded_at)::time as last_activity,
        COUNT(DISTINCT room_name) as rooms_active,
        COALESCE(
            (SELECT MAX(gap_minutes) FROM (
                SELECT EXTRACT(EPOCH FROM (
                    recorded_at - LAG(recorded_at) OVER (ORDER BY recorded_at)
                )) / 60 as gap_minutes
                FROM activity_events ae_inner
                WHERE ae_inner.config_id = p_config_id
                  AND ae_inner.recorded_at::date = p_date
            ) gaps WHERE gap_minutes IS NOT NULL),
            0
        )::integer as longest_gap
    INTO v_events
    FROM activity_events
    WHERE config_id = p_config_id
      AND recorded_at::date = p_date;

    -- Events per uur
    FOR v_hour IN 0..23 LOOP
        SELECT COUNT(*) INTO v_hour_count
        FROM activity_events
        WHERE config_id = p_config_id
          AND recorded_at::date = p_date
          AND EXTRACT(HOUR FROM recorded_at) = v_hour;

        v_events_per_hour[v_hour + 1] := v_hour_count;

        IF v_hour_count > 0 THEN
            v_active_hours := v_active_hours + 1;
            IF v_hour >= 23 OR v_hour < 6 THEN
                v_night_hours := v_night_hours + 1;
            END IF;
        END IF;
    END LOOP;

    -- Night events
    SELECT COUNT(*) INTO v_night_events
    FROM activity_events
    WHERE config_id = p_config_id
      AND recorded_at::date = p_date
      AND (EXTRACT(HOUR FROM recorded_at) >= 23 OR EXTRACT(HOUR FROM recorded_at) < 6);

    -- Motion events (bewegingssensoren)
    SELECT COUNT(*) INTO v_motion_events
    FROM activity_events
    WHERE config_id = p_config_id
      AND recorded_at::date = p_date
      AND device_type = 'motion_sensor';

    -- Door events (contact sensoren)
    SELECT COUNT(*) INTO v_door_events
    FROM activity_events
    WHERE config_id = p_config_id
      AND recorded_at::date = p_date
      AND device_type = 'contact_sensor';

    -- Upsert
    INSERT INTO daily_activity_stats (
        config_id, date, first_activity, last_activity, total_events,
        events_per_hour, active_hours, rooms_active, rooms_available,
        longest_gap_minutes, night_events, night_active_hours,
        motion_events, door_events, updated_at
    ) VALUES (
        p_config_id, p_date, v_events.first_activity, v_events.last_activity,
        COALESCE(v_events.total_events, 0), v_events_per_hour, v_active_hours,
        COALESCE(v_events.rooms_active, 0), v_rooms_available,
        COALESCE(v_events.longest_gap, 0), v_night_events, v_night_hours,
        v_motion_events, v_door_events, NOW()
    )
    ON CONFLICT (config_id, date) DO UPDATE SET
        first_activity = EXCLUDED.first_activity,
        last_activity = EXCLUDED.last_activity,
        total_events = EXCLUDED.total_events,
        events_per_hour = EXCLUDED.events_per_hour,
        active_hours = EXCLUDED.active_hours,
        rooms_active = EXCLUDED.rooms_active,
        rooms_available = EXCLUDED.rooms_available,
        longest_gap_minutes = EXCLUDED.longest_gap_minutes,
        night_events = EXCLUDED.night_events,
        night_active_hours = EXCLUDED.night_active_hours,
        motion_events = EXCLUDED.motion_events,
        door_events = EXCLUDED.door_events,
        updated_at = NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
   SET search_path = public, activity, integrations;

-- ============================================================
-- STAP 6: PostgREST schema exposure
-- Op Supabase hosted moet dit via het Dashboard:
--   Settings → API → Extra schemas → activity, integrations, planning
-- ============================================================

DO $$
BEGIN
    -- Probeer via ALTER ROLE (werkt mogelijk niet op Supabase hosted)
    EXECUTE 'ALTER ROLE authenticator SET pgrst.db_extra_search_path TO ''public, activity, integrations, planning''';
    RAISE NOTICE '✓ PostgREST extra search_path ingesteld via ALTER ROLE';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '⚠ ALTER ROLE niet mogelijk — configureer extra schemas via Supabase Dashboard';
    RAISE NOTICE '  Settings → API → Extra schemas → activity, integrations, planning';
END $$;

-- Herlaad PostgREST configuratie
NOTIFY pgrst, 'reload config';
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- STAP 7: Verificatie
-- ============================================================

DO $$
DECLARE
    v_table TEXT;
    v_schema TEXT;
    v_check RECORD;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== Verificatie Schema Migratie ===';

    -- Check integrations tabellen
    FOR v_check IN
        SELECT unnest(ARRAY['hue_config', 'hue_devices', 'physical_devices']) as tbl
    LOOP
        IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'integrations' AND table_name = v_check.tbl) THEN
            RAISE NOTICE '✓ integrations.% bestaat', v_check.tbl;
        ELSE
            RAISE WARNING '✗ integrations.% ONTBREEKT!', v_check.tbl;
        END IF;
    END LOOP;

    -- Check activity tabellen
    FOR v_check IN
        SELECT unnest(ARRAY['activity_events', 'room_activity_hourly', 'daily_activity_stats']) as tbl
    LOOP
        IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'activity' AND table_name = v_check.tbl) THEN
            RAISE NOTICE '✓ activity.% bestaat', v_check.tbl;
        ELSE
            RAISE WARNING '✗ activity.% ONTBREEKT!', v_check.tbl;
        END IF;
    END LOOP;

    -- Check planning tabellen
    FOR v_check IN
        SELECT unnest(ARRAY['project_phases', 'project_tickets', 'phase_criteria', 'phase_purchases']) as tbl
    LOOP
        IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'planning' AND table_name = v_check.tbl) THEN
            RAISE NOTICE '✓ planning.% bestaat', v_check.tbl;
        ELSE
            RAISE WARNING '✗ planning.% ONTBREEKT!', v_check.tbl;
        END IF;
    END LOOP;

    -- Check functies
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'get_accessible_config_ids') THEN
        RAISE NOTICE '✓ Functie get_accessible_config_ids bestaat';
    ELSE
        RAISE WARNING '✗ Functie get_accessible_config_ids ONTBREEKT!';
    END IF;

    RAISE NOTICE '';
    RAISE NOTICE '=== HANDMATIGE STAP NODIG ===';
    RAISE NOTICE 'Ga naar Supabase Dashboard → Settings → API → Extra schemas';
    RAISE NOTICE 'Voeg toe: activity, integrations, planning';
    RAISE NOTICE 'Migratie 028_create_schemas voltooid';
END $$;
