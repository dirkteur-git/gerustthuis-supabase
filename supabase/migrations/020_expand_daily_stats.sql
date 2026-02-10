-- ============================================================
-- GerustThuis - Uitbreiding daily_activity_stats met device type kolommen
--
-- Voegt motion_events en door_events kolommen toe aan daily_activity_stats
-- zodat het anomaly detection algoritme per sensor type kan analyseren.
--
-- Wijzigingen:
--   1. ALTER TABLE: motion_events, door_events kolommen
--   2. CREATE OR REPLACE FUNCTION: calculate_daily_activity_stats
--      met motion/door counts
--   3. Backfill laatste 30 dagen
--
-- Datum: 2026-02-10
-- ============================================================

-- ============================================================
-- STAP 1: Nieuwe kolommen toevoegen
-- ============================================================

ALTER TABLE daily_activity_stats
    ADD COLUMN IF NOT EXISTS motion_events INTEGER DEFAULT 0,
    ADD COLUMN IF NOT EXISTS door_events INTEGER DEFAULT 0;

COMMENT ON COLUMN daily_activity_stats.motion_events IS 'Bewegingssensor events per dag (device_type = motion_sensor)';
COMMENT ON COLUMN daily_activity_stats.door_events IS 'Deur/contact sensor events per dag (device_type = contact_sensor)';

-- ============================================================
-- STAP 2: Functie uitbreiden met motion/door counts
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- STAP 3: Backfill laatste 30 dagen
-- ============================================================

SELECT * FROM refresh_daily_activity_stats(NULL, 30);

-- ============================================================
-- STAP 4: Verificatie
-- ============================================================

DO $$
DECLARE
    v_total INTEGER;
    v_with_motion INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_total FROM daily_activity_stats;
    SELECT COUNT(*) INTO v_with_motion FROM daily_activity_stats WHERE motion_events > 0 OR door_events > 0;

    RAISE NOTICE '';
    RAISE NOTICE '=== Migratie 020 Verificatie ===';
    RAISE NOTICE 'daily_activity_stats totaal: % rijen', v_total;
    RAISE NOTICE 'Rijen met motion/door data: %', v_with_motion;

    IF v_with_motion > 0 THEN
        RAISE NOTICE 'OK: motion_events en door_events zijn gevuld';
    ELSE
        RAISE WARNING 'LET OP: geen rijen met motion/door data (mogelijk geen activity_events met device_type)';
    END IF;
END $$;
