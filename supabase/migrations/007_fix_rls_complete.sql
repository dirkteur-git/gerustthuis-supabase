-- ============================================================
-- GerustThuis Supabase - Complete RLS Fix
-- KRITIEK: Fix data isolation tussen gebruikers
-- Datum: 2026-01-31
-- ============================================================

-- ============================================================
-- STAP 1: Drop de room_activity_hourly VIEW en maak een TABEL
-- De view heeft geen config_id, we moeten een tabel maken
-- ============================================================

-- Drop de view als die bestaat
DROP VIEW IF EXISTS room_activity_hourly CASCADE;

-- Maak de tabel (opnieuw) met config_id
DROP TABLE IF EXISTS room_activity_hourly CASCADE;

CREATE TABLE room_activity_hourly (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config_id UUID NOT NULL REFERENCES hue_config(id) ON DELETE CASCADE,
    room_name TEXT NOT NULL,
    hour TIMESTAMPTZ NOT NULL,
    motion_events INTEGER DEFAULT 0,
    door_events INTEGER DEFAULT 0,
    total_events INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    -- Unique constraint met config_id
    UNIQUE(config_id, room_name, hour)
);

-- Indexen
CREATE INDEX idx_room_activity_hourly_config ON room_activity_hourly(config_id);
CREATE INDEX idx_room_activity_hourly_hour ON room_activity_hourly(hour DESC);
CREATE INDEX idx_room_activity_hourly_room ON room_activity_hourly(room_name);
CREATE INDEX idx_room_activity_hourly_config_hour ON room_activity_hourly(config_id, hour DESC);

-- Trigger voor updated_at
CREATE OR REPLACE FUNCTION update_room_activity_hourly_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_room_activity_hourly_updated_at ON room_activity_hourly;
CREATE TRIGGER trigger_room_activity_hourly_updated_at
    BEFORE UPDATE ON room_activity_hourly
    FOR EACH ROW
    EXECUTE FUNCTION update_room_activity_hourly_updated_at();

-- ============================================================
-- STAP 2: Maak activity_events tabel (ontbreekt!)
-- ============================================================

CREATE TABLE IF NOT EXISTS activity_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config_id       UUID NOT NULL REFERENCES hue_config(id) ON DELETE CASCADE,
    device_id       UUID REFERENCES hue_devices(id) ON DELETE CASCADE,
    device_type     VARCHAR(50) NOT NULL,
    room_name       VARCHAR(255),
    is_on           BOOLEAN,
    recorded_at     TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Indexen
CREATE INDEX IF NOT EXISTS idx_activity_events_config ON activity_events(config_id);
CREATE INDEX IF NOT EXISTS idx_activity_events_config_time ON activity_events(config_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_events_room_time ON activity_events(room_name, recorded_at DESC);

-- ============================================================
-- STAP 3: Drop alle bestaande RLS policies
-- ============================================================

-- hue_config
DROP POLICY IF EXISTS "Authenticated users can view hue_config" ON hue_config;
DROP POLICY IF EXISTS "Service role can insert hue_config" ON hue_config;
DROP POLICY IF EXISTS "Service role can update hue_config" ON hue_config;
DROP POLICY IF EXISTS "Users can view own hue_config" ON hue_config;
DROP POLICY IF EXISTS "Users view own config" ON hue_config;
DROP POLICY IF EXISTS "Service role full access hue_config" ON hue_config;

-- hue_devices
DROP POLICY IF EXISTS "Authenticated users can view hue_devices" ON hue_devices;
DROP POLICY IF EXISTS "Service role can insert hue_devices" ON hue_devices;
DROP POLICY IF EXISTS "Service role can update hue_devices" ON hue_devices;
DROP POLICY IF EXISTS "Users view own devices" ON hue_devices;
DROP POLICY IF EXISTS "Service role full access hue_devices" ON hue_devices;

-- raw_events
DROP POLICY IF EXISTS "Authenticated users can view raw_events" ON raw_events;
DROP POLICY IF EXISTS "Service role can insert raw_events" ON raw_events;
DROP POLICY IF EXISTS "Service role can delete raw_events" ON raw_events;
DROP POLICY IF EXISTS "Users view own raw_events" ON raw_events;
DROP POLICY IF EXISTS "Service role full access raw_events" ON raw_events;

-- physical_devices (als bestaat)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'physical_devices') THEN
        DROP POLICY IF EXISTS "Authenticated users can view physical_devices" ON physical_devices;
        DROP POLICY IF EXISTS "Service role can insert physical_devices" ON physical_devices;
        DROP POLICY IF EXISTS "Service role can update physical_devices" ON physical_devices;
        DROP POLICY IF EXISTS "Users view own physical_devices" ON physical_devices;
        DROP POLICY IF EXISTS "Service role full access physical_devices" ON physical_devices;
    END IF;
END $$;

-- daily_activity_stats (als bestaat)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'daily_activity_stats') THEN
        DROP POLICY IF EXISTS "Users view own daily stats" ON daily_activity_stats;
        DROP POLICY IF EXISTS "Service role full access" ON daily_activity_stats;
    END IF;
END $$;

-- ============================================================
-- STAP 4: Enable RLS op alle tabellen
-- ============================================================

ALTER TABLE hue_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE hue_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE raw_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE room_activity_hourly ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_events ENABLE ROW LEVEL SECURITY;

-- physical_devices alleen als de tabel bestaat
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'physical_devices') THEN
        ALTER TABLE physical_devices ENABLE ROW LEVEL SECURITY;
    END IF;
END $$;

-- daily_activity_stats alleen als de tabel bestaat
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'daily_activity_stats') THEN
        ALTER TABLE daily_activity_stats ENABLE ROW LEVEL SECURITY;
    END IF;
END $$;

-- ============================================================
-- STAP 5: Nieuwe RLS policies - USER ISOLATION
-- ============================================================

-- -----------------------------
-- hue_config: Gebruikers zien alleen hun eigen config
-- -----------------------------
CREATE POLICY "Users view own config" ON hue_config
    FOR SELECT TO authenticated
    USING (user_email = auth.jwt() ->> 'email');

CREATE POLICY "Service role full access hue_config" ON hue_config
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- -----------------------------
-- hue_devices: Filter via config_id → user_email
-- -----------------------------
CREATE POLICY "Users view own devices" ON hue_devices
    FOR SELECT TO authenticated
    USING (config_id IN (
        SELECT id FROM hue_config
        WHERE user_email = auth.jwt() ->> 'email'
    ));

CREATE POLICY "Service role full access hue_devices" ON hue_devices
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- -----------------------------
-- raw_events: Filter via device_id → config_id → user_email
-- -----------------------------
CREATE POLICY "Users view own raw_events" ON raw_events
    FOR SELECT TO authenticated
    USING (device_id IN (
        SELECT d.id FROM hue_devices d
        JOIN hue_config c ON d.config_id = c.id
        WHERE c.user_email = auth.jwt() ->> 'email'
    ));

CREATE POLICY "Service role full access raw_events" ON raw_events
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- -----------------------------
-- activity_events: Filter via config_id → user_email
-- -----------------------------
CREATE POLICY "Users view own activity_events" ON activity_events
    FOR SELECT TO authenticated
    USING (config_id IN (
        SELECT id FROM hue_config
        WHERE user_email = auth.jwt() ->> 'email'
    ));

CREATE POLICY "Service role full access activity_events" ON activity_events
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- -----------------------------
-- room_activity_hourly: Filter via config_id → user_email
-- -----------------------------
CREATE POLICY "Users view own room_activity_hourly" ON room_activity_hourly
    FOR SELECT TO authenticated
    USING (config_id IN (
        SELECT id FROM hue_config
        WHERE user_email = auth.jwt() ->> 'email'
    ));

CREATE POLICY "Service role full access room_activity_hourly" ON room_activity_hourly
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- -----------------------------
-- physical_devices: Filter via config_id → user_email (als tabel bestaat)
-- -----------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'physical_devices') THEN
        EXECUTE 'CREATE POLICY "Users view own physical_devices" ON physical_devices
            FOR SELECT TO authenticated
            USING (config_id IN (
                SELECT id FROM hue_config
                WHERE user_email = auth.jwt() ->> ''email''
            ))';

        EXECUTE 'CREATE POLICY "Service role full access physical_devices" ON physical_devices
            FOR ALL TO service_role
            USING (true) WITH CHECK (true)';
    END IF;
END $$;

-- -----------------------------
-- daily_activity_stats: Filter via config_id → user_email (als tabel bestaat)
-- -----------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'daily_activity_stats') THEN
        EXECUTE 'CREATE POLICY "Users view own daily_activity_stats" ON daily_activity_stats
            FOR SELECT TO authenticated
            USING (config_id IN (
                SELECT id FROM hue_config
                WHERE user_email = auth.jwt() ->> ''email''
            ))';

        EXECUTE 'CREATE POLICY "Service role full access daily_activity_stats" ON daily_activity_stats
            FOR ALL TO service_role
            USING (true) WITH CHECK (true)';
    END IF;
END $$;

-- ============================================================
-- STAP 6: Update aggregate_hourly_activity functie
-- Nu met config_id support
-- ============================================================

CREATE OR REPLACE FUNCTION aggregate_hourly_activity(p_hours_back INTEGER DEFAULT 2)
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER := 0;
BEGIN
    -- Upsert activity counts per config per room per hour
    INSERT INTO room_activity_hourly (config_id, room_name, hour, motion_events, door_events, total_events)
    SELECT
        d.config_id,
        d.room_name,
        date_trunc('hour', e.recorded_at) AS hour,
        COUNT(*) FILTER (WHERE e.event_type = 'state_change' AND d.device_type = 'motion_sensor') AS motion_events,
        COUNT(*) FILTER (WHERE e.event_type = 'state_change' AND d.device_type = 'contact_sensor') AS door_events,
        COUNT(*) AS total_events
    FROM raw_events e
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
-- STAP 7: Herbouw historische data (laatste 30 dagen)
-- ============================================================

SELECT aggregate_hourly_activity(720); -- 30 dagen = 720 uur

-- ============================================================
-- STAP 8: Update andere views om config_id te includen
-- ============================================================

-- room_activity_daily view met config_id filtering
CREATE OR REPLACE VIEW room_activity_daily AS
SELECT
    d.config_id,
    d.room_name,
    date_trunc('day', e.recorded_at) AS day,
    COUNT(*) FILTER (WHERE e.event_type = 'state_change' AND (e.new_state->>'presence')::boolean = true) AS motion_events,
    COUNT(*) FILTER (WHERE e.event_type = 'state_change' AND d.device_type = 'contact_sensor') AS door_events,
    COUNT(*) FILTER (WHERE e.event_type = 'state_change' AND d.device_type = 'light') AS light_events,
    COUNT(*) AS total_events,
    MIN(e.recorded_at) AS first_event,
    MAX(e.recorded_at) AS last_event,
    COUNT(DISTINCT date_trunc('hour', e.recorded_at)) AS active_hours
FROM raw_events e
JOIN hue_devices d ON e.device_id = d.id
JOIN hue_config c ON d.config_id = c.id
WHERE d.room_name IS NOT NULL
  AND c.user_email = auth.jwt() ->> 'email'
GROUP BY d.config_id, d.room_name, date_trunc('day', e.recorded_at)
ORDER BY day DESC, d.room_name;

-- room_summary view met config_id filtering
CREATE OR REPLACE VIEW room_summary AS
SELECT
    d.config_id,
    d.room_name,
    COUNT(*) FILTER (WHERE d.device_type = 'light') AS light_count,
    COUNT(*) FILTER (WHERE d.device_type = 'motion_sensor') AS motion_sensor_count,
    COUNT(*) FILTER (WHERE d.device_type = 'contact_sensor') AS door_sensor_count,
    COUNT(*) FILTER (WHERE d.device_type NOT IN ('light', 'motion_sensor', 'contact_sensor')) AS other_sensor_count,
    COUNT(*) FILTER (WHERE d.device_type = 'light' AND (d.last_state->>'on')::boolean = true) AS lights_on,
    MAX(d.last_state_at) AS last_activity,
    MAX(CASE WHEN d.device_type = 'motion_sensor' THEN d.last_state_at END) AS last_motion,
    MAX(CASE WHEN d.device_type = 'contact_sensor' THEN d.last_state_at END) AS last_door
FROM hue_devices d
JOIN hue_config c ON d.config_id = c.id
WHERE d.room_name IS NOT NULL
  AND c.user_email = auth.jwt() ->> 'email'
GROUP BY d.config_id, d.room_name
ORDER BY d.room_name;

-- recent_activity_by_room view met config_id filtering
CREATE OR REPLACE VIEW recent_activity_by_room AS
SELECT
    d.config_id,
    d.room_name,
    e.recorded_at,
    d.device_type,
    CASE
        WHEN d.device_type = 'motion_sensor' THEN (e.new_state->>'presence')::boolean
        WHEN d.device_type = 'contact_sensor' THEN (e.new_state->>'open')::boolean
        ELSE NULL
    END AS triggered,
    d.name AS sensor_name
FROM raw_events e
JOIN hue_devices d ON e.device_id = d.id
JOIN hue_config c ON d.config_id = c.id
WHERE d.device_type IN ('motion_sensor', 'contact_sensor')
  AND d.room_name IS NOT NULL
  AND e.recorded_at > NOW() - INTERVAL '24 hours'
  AND e.event_type = 'state_change'
  AND c.user_email = auth.jwt() ->> 'email'
ORDER BY e.recorded_at DESC;

-- ============================================================
-- COMMENTAAR
-- ============================================================

COMMENT ON TABLE room_activity_hourly IS 'Hourly activity aggregation per room per user config';
COMMENT ON TABLE activity_events IS 'All activity events with user isolation via config_id';
COMMENT ON POLICY "Users view own config" ON hue_config IS 'Users see only their own config based on JWT email';
COMMENT ON POLICY "Users view own devices" ON hue_devices IS 'Users see only devices from their own config';
COMMENT ON POLICY "Users view own raw_events" ON raw_events IS 'Users see only events from their own devices';
COMMENT ON POLICY "Users view own activity_events" ON activity_events IS 'Users see only activity events from their own config';
COMMENT ON POLICY "Users view own room_activity_hourly" ON room_activity_hourly IS 'Users see only hourly stats from their own config';
