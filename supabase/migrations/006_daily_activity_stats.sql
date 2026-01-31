-- Migration: daily_activity_stats
-- Beschrijving: Dagelijkse activiteitsstatistieken per bewoner
-- Datum: 2026-01-31

-- =============================================================================
-- TABEL: daily_activity_stats
-- =============================================================================

CREATE TABLE IF NOT EXISTS daily_activity_stats (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config_id             UUID NOT NULL REFERENCES hue_config(id) ON DELETE CASCADE,
    date                  DATE NOT NULL,
    first_activity        TIME,                    -- Tijdstip eerste event
    last_activity         TIME,                    -- Tijdstip laatste event
    total_events          INTEGER DEFAULT 0,       -- Totaal aantal events
    events_per_hour       INTEGER[] DEFAULT ARRAY[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
    active_hours          INTEGER DEFAULT 0,       -- Uren met ≥1 event
    rooms_active          INTEGER DEFAULT 0,       -- Unieke kamers met activiteit
    rooms_available       INTEGER DEFAULT 0,       -- Totaal kamers met sensoren
    longest_gap_minutes   INTEGER DEFAULT 0,       -- Langste gap tussen events
    night_events          INTEGER DEFAULT 0,       -- Events 23:00-06:00
    night_active_hours    INTEGER DEFAULT 0,       -- Actieve uren 23:00-06:00
    created_at            TIMESTAMPTZ DEFAULT NOW(),
    updated_at            TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(config_id, date)
);

-- Indexen
CREATE INDEX IF NOT EXISTS idx_daily_activity_stats_config ON daily_activity_stats(config_id);
CREATE INDEX IF NOT EXISTS idx_daily_activity_stats_date ON daily_activity_stats(date DESC);

-- =============================================================================
-- FUNCTIE: calculate_daily_activity_stats
-- Berekent stats voor één config op één dag (incrementeel)
-- =============================================================================

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
    -- Bereken rooms_available (kamers met sensoren voor deze config)
    SELECT COUNT(DISTINCT room_name) INTO v_rooms_available
    FROM hue_devices
    WHERE config_id = p_config_id
      AND device_type IN ('motion_sensor', 'contact_sensor', 'light');

    -- Haal event stats op voor deze dag
    SELECT
        COUNT(*) as total_events,
        MIN(recorded_at)::time as first_activity,
        MAX(recorded_at)::time as last_activity,
        COUNT(DISTINCT room_name) as rooms_active,
        -- Longest gap berekening
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

    -- Bereken events per uur
    FOR v_hour IN 0..23 LOOP
        SELECT COUNT(*) INTO v_hour_count
        FROM activity_events
        WHERE config_id = p_config_id
          AND recorded_at::date = p_date
          AND EXTRACT(HOUR FROM recorded_at) = v_hour;

        v_events_per_hour[v_hour + 1] := v_hour_count;

        IF v_hour_count > 0 THEN
            v_active_hours := v_active_hours + 1;

            -- Night hours: 23, 0, 1, 2, 3, 4, 5
            IF v_hour >= 23 OR v_hour < 6 THEN
                v_night_hours := v_night_hours + 1;
            END IF;
        END IF;
    END LOOP;

    -- Night events (23:00-06:00)
    SELECT COUNT(*) INTO v_night_events
    FROM activity_events
    WHERE config_id = p_config_id
      AND recorded_at::date = p_date
      AND (EXTRACT(HOUR FROM recorded_at) >= 23 OR EXTRACT(HOUR FROM recorded_at) < 6);

    -- Upsert de stats
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
$$ LANGUAGE plpgsql;

-- =============================================================================
-- FUNCTIE: refresh_daily_activity_stats
-- Batch functie voor meerdere dagen/configs
-- =============================================================================

CREATE OR REPLACE FUNCTION refresh_daily_activity_stats(
    p_config_id UUID DEFAULT NULL,
    p_days_back INTEGER DEFAULT 7
) RETURNS TABLE(config_id UUID, date DATE, total_events INTEGER) AS $$
DECLARE
    v_config RECORD;
    v_date DATE;
BEGIN
    -- Loop door alle configs (of specifieke)
    FOR v_config IN
        SELECT hc.id FROM hue_config hc
        WHERE (p_config_id IS NULL OR hc.id = p_config_id)
          AND hc.status = 'active'
    LOOP
        -- Loop door de laatste X dagen
        FOR v_date IN
            SELECT generate_series(
                CURRENT_DATE - p_days_back,
                CURRENT_DATE,
                '1 day'::interval
            )::date
        LOOP
            PERFORM calculate_daily_activity_stats(v_config.id, v_date);

            -- Return progress
            RETURN QUERY
            SELECT v_config.id, v_date,
                   (SELECT das.total_events FROM daily_activity_stats das
                    WHERE das.config_id = v_config.id AND das.date = v_date);
        END LOOP;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================

ALTER TABLE daily_activity_stats ENABLE ROW LEVEL SECURITY;

-- Users zien alleen hun eigen stats
CREATE POLICY "Users view own daily stats" ON daily_activity_stats
    FOR SELECT TO authenticated
    USING (config_id IN (
        SELECT id FROM hue_config
        WHERE user_email = auth.jwt() ->> 'email'
    ));

-- Service role heeft volledige toegang
CREATE POLICY "Service role full access" ON daily_activity_stats
    FOR ALL TO service_role
    USING (true)
    WITH CHECK (true);

-- =============================================================================
-- COMMENTAAR
-- =============================================================================

COMMENT ON TABLE daily_activity_stats IS 'Dagelijkse activiteitsstatistieken per bewoner';
COMMENT ON COLUMN daily_activity_stats.events_per_hour IS 'Array[24] met event counts per uur (index 0 = 00:00-01:00)';
COMMENT ON COLUMN daily_activity_stats.longest_gap_minutes IS 'Langste periode zonder events tussen first en last activity';
COMMENT ON COLUMN daily_activity_stats.night_events IS 'Events tussen 23:00-06:00';
COMMENT ON COLUMN daily_activity_stats.night_active_hours IS 'Uren met activiteit tussen 23:00-06:00';
COMMENT ON FUNCTION calculate_daily_activity_stats IS 'Berekent daily stats voor één config op één dag';
COMMENT ON FUNCTION refresh_daily_activity_stats IS 'Batch functie: herberekent stats voor meerdere dagen';
