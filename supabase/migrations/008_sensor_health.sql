-- ============================================================
-- GerustThuis Supabase - Sensor Health Monitoring
-- Track battery levels and sensor liveness
-- Datum: 2026-01-31
-- ============================================================

-- ============================================================
-- STAP 1: Voeg health tracking kolommen toe aan hue_devices
-- ============================================================

-- Battery percentage (0-100)
ALTER TABLE hue_devices ADD COLUMN IF NOT EXISTS battery_percentage INTEGER;

-- Laatste battery update timestamp
ALTER TABLE hue_devices ADD COLUMN IF NOT EXISTS last_battery_update TIMESTAMPTZ;

-- Health status: healthy, warning, offline, failure
ALTER TABLE hue_devices ADD COLUMN IF NOT EXISTS health_status VARCHAR(20) DEFAULT 'unknown';

-- Index voor health status queries
CREATE INDEX IF NOT EXISTS idx_hue_devices_health_status ON hue_devices(health_status);

-- ============================================================
-- STAP 2: Sensor health history tabel
-- Slaat batterij percentage per uur op
-- ============================================================

CREATE TABLE IF NOT EXISTS sensor_health_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config_id UUID NOT NULL REFERENCES hue_config(id) ON DELETE CASCADE,
    device_id UUID NOT NULL REFERENCES hue_devices(id) ON DELETE CASCADE,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    battery_percentage INTEGER,
    is_alive BOOLEAN DEFAULT true,
    last_event_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Unique constraint: één record per device per uur
CREATE UNIQUE INDEX IF NOT EXISTS idx_sensor_health_history_device_hour
    ON sensor_health_history(device_id, date_trunc('hour', recorded_at));

-- Indexen voor queries
CREATE INDEX IF NOT EXISTS idx_sensor_health_history_config ON sensor_health_history(config_id);
CREATE INDEX IF NOT EXISTS idx_sensor_health_history_device ON sensor_health_history(device_id);
CREATE INDEX IF NOT EXISTS idx_sensor_health_history_recorded ON sensor_health_history(recorded_at DESC);

-- ============================================================
-- STAP 3: RLS voor sensor_health_history
-- ============================================================

ALTER TABLE sensor_health_history ENABLE ROW LEVEL SECURITY;

-- Users zien alleen hun eigen sensor health data
CREATE POLICY "Users view own sensor health" ON sensor_health_history
    FOR SELECT TO authenticated
    USING (config_id IN (
        SELECT id FROM hue_config
        WHERE user_email = auth.jwt() ->> 'email'
    ));

-- Service role heeft volledige toegang
CREATE POLICY "Service role full access sensor_health_history" ON sensor_health_history
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- ============================================================
-- STAP 4: Functie om health status te bepalen
-- ============================================================

CREATE OR REPLACE FUNCTION get_sensor_health_status(p_last_state_at TIMESTAMPTZ)
RETURNS VARCHAR(20) AS $$
BEGIN
    IF p_last_state_at IS NULL THEN
        RETURN 'unknown';
    ELSIF p_last_state_at > NOW() - INTERVAL '90 minutes' THEN
        RETURN 'healthy';
    ELSIF p_last_state_at > NOW() - INTERVAL '24 hours' THEN
        RETURN 'warning';
    ELSIF p_last_state_at > NOW() - INTERVAL '12 months' THEN
        RETURN 'offline';
    ELSE
        RETURN 'failure'; -- Meer dan 12 maanden geen activiteit
    END IF;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- STAP 5: Functie om health status te updaten voor alle sensoren
-- ============================================================

CREATE OR REPLACE FUNCTION update_sensor_health_status()
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER := 0;
BEGIN
    UPDATE hue_devices
    SET health_status = get_sensor_health_status(last_state_at)
    WHERE device_type IN ('motion_sensor', 'contact_sensor');

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- STAP 6: Functie om battery health snapshot te maken
-- Roep dit elk uur aan via cron
-- ============================================================

CREATE OR REPLACE FUNCTION record_sensor_health_snapshot()
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER := 0;
BEGIN
    -- Insert health snapshot voor alle sensoren
    INSERT INTO sensor_health_history (config_id, device_id, recorded_at, battery_percentage, is_alive, last_event_at)
    SELECT
        d.config_id,
        d.id,
        date_trunc('hour', NOW()),
        d.battery_percentage,
        CASE
            WHEN d.last_state_at > NOW() - INTERVAL '90 minutes' THEN true
            ELSE false
        END,
        d.last_state_at
    FROM hue_devices d
    WHERE d.device_type IN ('motion_sensor', 'contact_sensor')
      AND d.config_id IS NOT NULL
    ON CONFLICT (device_id, date_trunc('hour', recorded_at))
    DO UPDATE SET
        battery_percentage = EXCLUDED.battery_percentage,
        is_alive = EXCLUDED.is_alive,
        last_event_at = EXCLUDED.last_event_at;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    -- Update ook de health status
    PERFORM update_sensor_health_status();

    RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- STAP 7: View voor sensor health overzicht
-- ============================================================

CREATE OR REPLACE VIEW sensor_health_overview AS
SELECT
    d.id,
    d.name,
    d.room_name,
    d.device_type,
    d.config_id,
    d.battery_percentage,
    d.last_battery_update,
    d.health_status,
    d.last_state_at,
    EXTRACT(EPOCH FROM (NOW() - d.last_state_at)) / 60 AS minutes_since_last_event,
    EXTRACT(EPOCH FROM (NOW() - d.last_state_at)) / 3600 AS hours_since_last_event,
    EXTRACT(EPOCH FROM (NOW() - d.last_state_at)) / 86400 AS days_since_last_event,
    c.user_email
FROM hue_devices d
JOIN hue_config c ON d.config_id = c.id
WHERE d.device_type IN ('motion_sensor', 'contact_sensor')
  AND c.user_email = auth.jwt() ->> 'email'
ORDER BY
    CASE d.health_status
        WHEN 'failure' THEN 1
        WHEN 'offline' THEN 2
        WHEN 'warning' THEN 3
        WHEN 'unknown' THEN 4
        ELSE 5
    END,
    d.room_name,
    d.name;

-- ============================================================
-- STAP 8: View voor battery trends
-- ============================================================

CREATE OR REPLACE VIEW sensor_battery_trend AS
SELECT
    h.device_id,
    d.name AS device_name,
    d.room_name,
    h.recorded_at,
    h.battery_percentage,
    h.is_alive,
    c.user_email
FROM sensor_health_history h
JOIN hue_devices d ON h.device_id = d.id
JOIN hue_config c ON h.config_id = c.id
WHERE c.user_email = auth.jwt() ->> 'email'
  AND h.recorded_at > NOW() - INTERVAL '30 days'
ORDER BY h.device_id, h.recorded_at DESC;

-- ============================================================
-- STAP 9: Initiële health status update
-- ============================================================

SELECT update_sensor_health_status();

-- ============================================================
-- COMMENTAAR
-- ============================================================

COMMENT ON TABLE sensor_health_history IS 'Hourly snapshots of sensor battery and liveness status';
COMMENT ON COLUMN sensor_health_history.is_alive IS 'True if sensor had activity within last 90 minutes at snapshot time';
COMMENT ON COLUMN hue_devices.health_status IS 'Current health: healthy (active), warning (24h), offline (12mo), failure (>12mo)';
COMMENT ON FUNCTION get_sensor_health_status IS 'Determine health status based on last_state_at timestamp';
COMMENT ON FUNCTION update_sensor_health_status IS 'Update health_status for all motion/contact sensors';
COMMENT ON FUNCTION record_sensor_health_snapshot IS 'Create hourly health snapshot - call via cron job';
COMMENT ON VIEW sensor_health_overview IS 'Current health status of all sensors for logged-in user';
COMMENT ON VIEW sensor_battery_trend IS 'Battery percentage history for last 30 days';
