-- ============================================================
-- GerustThuis - Fix ontbrekende tabellen en RLS
--
-- Diagnose: Console toont 404 errors voor:
--   - room_activity_hourly (tabel niet gevonden)
--   - daily_activity_stats (RLS denial of tabel niet gevonden)
--   - room_activity_daily (view niet gevonden)
--
-- Dit script:
--   1. Maakt ontbrekende tabellen aan (IF NOT EXISTS)
--   2. Zorgt dat RLS policies bestaan met get_accessible_config_ids()
--   3. Maakt ontbrekende views aan
--
-- Datum: 2026-02-09
-- ============================================================

-- ============================================================
-- STAP 1: room_activity_hourly tabel
-- (Oorspronkelijk uit migratie 007, mogelijk verloren door CASCADE drops)
-- ============================================================

CREATE TABLE IF NOT EXISTS room_activity_hourly (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config_id UUID NOT NULL REFERENCES hue_config(id) ON DELETE CASCADE,
    room_name TEXT NOT NULL,
    hour TIMESTAMPTZ NOT NULL,
    motion_events INTEGER DEFAULT 0,
    door_events INTEGER DEFAULT 0,
    total_events INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(config_id, room_name, hour)
);

CREATE INDEX IF NOT EXISTS idx_room_activity_hourly_config ON room_activity_hourly(config_id);
CREATE INDEX IF NOT EXISTS idx_room_activity_hourly_hour ON room_activity_hourly(hour DESC);
CREATE INDEX IF NOT EXISTS idx_room_activity_hourly_room ON room_activity_hourly(room_name);
CREATE INDEX IF NOT EXISTS idx_room_activity_hourly_config_hour ON room_activity_hourly(config_id, hour DESC);

ALTER TABLE room_activity_hourly ENABLE ROW LEVEL SECURITY;

-- RLS policies
DROP POLICY IF EXISTS "Users view own room_activity_hourly" ON room_activity_hourly;
CREATE POLICY "Users view own room_activity_hourly" ON room_activity_hourly
    FOR SELECT TO authenticated
    USING (config_id IN (SELECT get_accessible_config_ids()));

DROP POLICY IF EXISTS "Service role full access room_activity_hourly" ON room_activity_hourly;
CREATE POLICY "Service role full access room_activity_hourly" ON room_activity_hourly
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- ============================================================
-- STAP 2: daily_activity_stats tabel
-- (Oorspronkelijk uit migratie 006)
-- ============================================================

CREATE TABLE IF NOT EXISTS daily_activity_stats (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config_id UUID NOT NULL REFERENCES hue_config(id) ON DELETE CASCADE,
    date DATE NOT NULL,
    total_events INTEGER DEFAULT 0,
    first_activity TEXT,
    last_activity TEXT,
    active_hours INTEGER DEFAULT 0,
    rooms_active INTEGER DEFAULT 0,
    events_per_hour INTEGER[] DEFAULT ARRAY[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
    longest_gap_minutes INTEGER DEFAULT 0,
    night_events INTEGER DEFAULT 0,
    night_active_hours INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(config_id, date)
);

CREATE INDEX IF NOT EXISTS idx_daily_activity_stats_config ON daily_activity_stats(config_id);
CREATE INDEX IF NOT EXISTS idx_daily_activity_stats_date ON daily_activity_stats(date DESC);
CREATE INDEX IF NOT EXISTS idx_daily_activity_stats_config_date ON daily_activity_stats(config_id, date DESC);

ALTER TABLE daily_activity_stats ENABLE ROW LEVEL SECURITY;

-- RLS policies
DROP POLICY IF EXISTS "Users view own daily_activity_stats" ON daily_activity_stats;
DROP POLICY IF EXISTS "Users view own daily stats" ON daily_activity_stats;
CREATE POLICY "Users view own daily_activity_stats" ON daily_activity_stats
    FOR SELECT TO authenticated
    USING (config_id IN (SELECT get_accessible_config_ids()));

DROP POLICY IF EXISTS "Service role full access daily_activity_stats" ON daily_activity_stats;
CREATE POLICY "Service role full access daily_activity_stats" ON daily_activity_stats
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- ============================================================
-- STAP 3: activity_events tabel (veiligheidscheck)
-- ============================================================

CREATE TABLE IF NOT EXISTS activity_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config_id UUID NOT NULL REFERENCES hue_config(id) ON DELETE CASCADE,
    device_id UUID REFERENCES hue_devices(id) ON DELETE CASCADE,
    device_type VARCHAR(50) NOT NULL,
    room_name VARCHAR(255),
    is_on BOOLEAN,
    recorded_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_activity_events_config ON activity_events(config_id);
CREATE INDEX IF NOT EXISTS idx_activity_events_config_time ON activity_events(config_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_events_room_time ON activity_events(room_name, recorded_at DESC);

ALTER TABLE activity_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users view own activity_events" ON activity_events;
CREATE POLICY "Users view own activity_events" ON activity_events
    FOR SELECT TO authenticated
    USING (config_id IN (SELECT get_accessible_config_ids()));

DROP POLICY IF EXISTS "Service role full access activity_events" ON activity_events;
CREATE POLICY "Service role full access activity_events" ON activity_events
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- ============================================================
-- STAP 4: Aggregatie functies
-- ============================================================

-- Hourly activity aggregation
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- STAP 5: Verificatie
-- ============================================================

DO $$
DECLARE
    v_table TEXT;
    v_tables TEXT[] := ARRAY['hue_config', 'hue_devices', 'raw_events', 'activity_events',
                             'room_activity_hourly', 'daily_activity_stats',
                             'user_profiles', 'households', 'household_members'];
BEGIN
    FOREACH v_table IN ARRAY v_tables
    LOOP
        IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = v_table) THEN
            RAISE NOTICE '✓ Tabel % bestaat', v_table;
        ELSE
            RAISE WARNING '✗ Tabel % ONTBREEKT!', v_table;
        END IF;
    END LOOP;

    -- Check get_accessible_config_ids
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'get_accessible_config_ids') THEN
        RAISE NOTICE '✓ Functie get_accessible_config_ids bestaat';
    ELSE
        RAISE WARNING '✗ Functie get_accessible_config_ids ONTBREEKT!';
    END IF;

    -- Check households met config_id
    RAISE NOTICE '';
    RAISE NOTICE 'Household → config koppeling:';
    PERFORM 1 FROM households WHERE config_id IS NOT NULL LIMIT 1;
    IF FOUND THEN
        RAISE NOTICE '✓ Er zijn households met config_id';
    ELSE
        RAISE WARNING '✗ Geen enkel household heeft een config_id! Voer migratie 015 uit.';
    END IF;
END $$;
