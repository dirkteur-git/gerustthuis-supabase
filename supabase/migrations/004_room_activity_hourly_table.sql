-- ============================================================
-- GerustThuis Supabase - Room Activity Hourly Table
-- Vervangt de view met een tabel voor betere performance en RLS
-- ============================================================

-- Drop de oude view als die bestaat
DROP VIEW IF EXISTS room_activity_hourly;

-- Maak de tabel
CREATE TABLE IF NOT EXISTS room_activity_hourly (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_name TEXT NOT NULL,
    hour TIMESTAMPTZ NOT NULL,
    motion_events INTEGER DEFAULT 0,
    door_events INTEGER DEFAULT 0,
    total_events INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    -- Unique constraint op room + hour
    UNIQUE(room_name, hour)
);

-- Indexen voor snelle queries
CREATE INDEX IF NOT EXISTS idx_room_activity_hourly_hour ON room_activity_hourly(hour DESC);
CREATE INDEX IF NOT EXISTS idx_room_activity_hourly_room ON room_activity_hourly(room_name);
CREATE INDEX IF NOT EXISTS idx_room_activity_hourly_room_hour ON room_activity_hourly(room_name, hour DESC);

-- RLS inschakelen
ALTER TABLE room_activity_hourly ENABLE ROW LEVEL SECURITY;

-- Policy: iedereen mag lezen (voor dashboard)
CREATE POLICY "Allow public read access" ON room_activity_hourly
    FOR SELECT USING (true);

-- Policy: alleen service role mag schrijven
CREATE POLICY "Allow service role insert" ON room_activity_hourly
    FOR INSERT WITH CHECK (true);

CREATE POLICY "Allow service role update" ON room_activity_hourly
    FOR UPDATE USING (true);

-- Trigger voor updated_at
CREATE OR REPLACE FUNCTION update_room_activity_hourly_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_room_activity_hourly_updated_at
    BEFORE UPDATE ON room_activity_hourly
    FOR EACH ROW
    EXECUTE FUNCTION update_room_activity_hourly_updated_at();

-- ============================================================
-- Function: aggregate_hourly_activity
-- Aggregeert raw_events naar room_activity_hourly
-- Draait typisch elk uur via cron
-- ============================================================
CREATE OR REPLACE FUNCTION aggregate_hourly_activity(p_hours_back INTEGER DEFAULT 2)
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER := 0;
BEGIN
    -- Upsert activity counts per room per hour
    INSERT INTO room_activity_hourly (room_name, hour, motion_events, door_events, total_events)
    SELECT
        d.room_name,
        date_trunc('hour', e.recorded_at) AS hour,
        -- Tel ALLE motion sensor events, niet alleen presence=true
        COUNT(*) FILTER (WHERE e.event_type = 'state_change' AND d.device_type = 'motion_sensor') AS motion_events,
        COUNT(*) FILTER (WHERE e.event_type = 'state_change' AND d.device_type = 'contact_sensor') AS door_events,
        COUNT(*) AS total_events
    FROM raw_events e
    JOIN hue_devices d ON e.device_id = d.id
    WHERE d.room_name IS NOT NULL
      AND e.recorded_at >= NOW() - (p_hours_back || ' hours')::INTERVAL
    GROUP BY d.room_name, date_trunc('hour', e.recorded_at)
    ON CONFLICT (room_name, hour)
    DO UPDATE SET
        motion_events = EXCLUDED.motion_events,
        door_events = EXCLUDED.door_events,
        total_events = EXCLUDED.total_events,
        updated_at = NOW();

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Vul de tabel met historische data (laatste 30 dagen)
SELECT aggregate_hourly_activity(720); -- 30 dagen = 720 uur
