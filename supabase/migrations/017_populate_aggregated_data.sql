-- ============================================================
-- GerustThuis - Vul aggregatietabellen met bestaande data
--
-- Na migratie 016 bestaan de tabellen room_activity_hourly en
-- daily_activity_stats, maar ze zijn leeg. Dit script:
--   1. Fixt RLS policies (zeker stellen dat get_accessible_config_ids() wordt gebruikt)
--   2. Fixt calculate_daily_activity_stats als SECURITY DEFINER
--   3. Vult room_activity_hourly vanuit activity_events (laatste 30 dagen)
--   4. Vult daily_activity_stats vanuit activity_events (laatste 30 dagen)
--
-- Datum: 2026-02-09
-- ============================================================

-- ============================================================
-- STAP 1: Fix RLS policies op daily_activity_stats
-- De originele policy uit migratie 006 gebruikte directe email match,
-- niet get_accessible_config_ids(). Vervang deze.
-- ============================================================

-- Drop alle mogelijke oude policies
DROP POLICY IF EXISTS "Users view own daily stats" ON daily_activity_stats;
DROP POLICY IF EXISTS "Users view own daily_activity_stats" ON daily_activity_stats;
DROP POLICY IF EXISTS "Service role full access" ON daily_activity_stats;
DROP POLICY IF EXISTS "Service role full access daily_activity_stats" ON daily_activity_stats;

-- Maak correcte policies aan
CREATE POLICY "Users view own daily_activity_stats" ON daily_activity_stats
    FOR SELECT TO authenticated
    USING (config_id IN (SELECT get_accessible_config_ids()));

CREATE POLICY "Service role full access daily_activity_stats" ON daily_activity_stats
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- ============================================================
-- STAP 2: Fix calculate_daily_activity_stats als SECURITY DEFINER
-- Zodat de functie ook vanuit RLS-context kan draaien
-- ============================================================

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

    -- Upsert
    INSERT INTO daily_activity_stats (
        config_id, date, first_activity, last_activity, total_events,
        events_per_hour, active_hours, rooms_active, rooms_available,
        longest_gap_minutes, night_events, night_active_hours, updated_at
    ) VALUES (
        p_config_id, p_date, v_events.first_activity, v_events.last_activity,
        COALESCE(v_events.total_events, 0), v_events_per_hour, v_active_hours,
        COALESCE(v_events.rooms_active, 0), v_rooms_available,
        COALESCE(v_events.longest_gap, 0), v_night_events, v_night_hours, NOW()
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
        updated_at = NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- STAP 3: Fix refresh_daily_activity_stats als SECURITY DEFINER
-- ============================================================

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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- STAP 4: Vul room_activity_hourly (laatste 30 dagen)
-- ============================================================

SELECT aggregate_hourly_activity(720);

-- ============================================================
-- STAP 5: Vul daily_activity_stats (laatste 30 dagen)
-- ============================================================

SELECT * FROM refresh_daily_activity_stats(NULL, 30);

-- ============================================================
-- STAP 6: Verificatie
-- ============================================================

DO $$
DECLARE
    v_hourly_count INTEGER;
    v_daily_count INTEGER;
    v_events_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_events_count FROM activity_events;
    SELECT COUNT(*) INTO v_hourly_count FROM room_activity_hourly;
    SELECT COUNT(*) INTO v_daily_count FROM daily_activity_stats;

    RAISE NOTICE '';
    RAISE NOTICE '=== Data Verificatie ===';
    RAISE NOTICE 'activity_events: % rijen', v_events_count;
    RAISE NOTICE 'room_activity_hourly: % rijen (was leeg, nu gevuld)', v_hourly_count;
    RAISE NOTICE 'daily_activity_stats: % rijen', v_daily_count;

    IF v_hourly_count > 0 THEN
        RAISE NOTICE '✓ room_activity_hourly heeft data';
    ELSE
        RAISE WARNING '✗ room_activity_hourly is nog steeds leeg (geen activity_events data?)';
    END IF;

    IF v_daily_count > 0 THEN
        RAISE NOTICE '✓ daily_activity_stats heeft data';
    ELSE
        RAISE WARNING '✗ daily_activity_stats is nog steeds leeg';
    END IF;
END $$;
