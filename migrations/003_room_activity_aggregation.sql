-- ============================================================
-- GerustThuis Supabase - Room Activity Aggregation
-- Aggregeert motion events per kamer per uur
-- ============================================================

-- ============================================================
-- View: room_activity_hourly
-- Toont activiteit per kamer per uur
-- ============================================================
CREATE OR REPLACE VIEW room_activity_hourly AS
SELECT
    d.room_name,
    date_trunc('hour', e.recorded_at) AS hour,
    COUNT(*) FILTER (WHERE e.event_type = 'state_change' AND (e.new_state->>'presence')::boolean = true) AS motion_events,
    COUNT(*) FILTER (WHERE e.event_type = 'state_change' AND d.device_type = 'contact_sensor') AS door_events,
    COUNT(*) FILTER (WHERE e.event_type = 'state_change' AND d.device_type = 'light') AS light_events,
    COUNT(*) AS total_events,
    MIN(e.recorded_at) AS first_event,
    MAX(e.recorded_at) AS last_event
FROM raw_events e
JOIN hue_devices d ON e.device_id = d.id
WHERE d.room_name IS NOT NULL
GROUP BY d.room_name, date_trunc('hour', e.recorded_at)
ORDER BY hour DESC, d.room_name;

-- ============================================================
-- View: room_activity_daily
-- Toont activiteit per kamer per dag
-- ============================================================
CREATE OR REPLACE VIEW room_activity_daily AS
SELECT
    d.room_name,
    date_trunc('day', e.recorded_at) AS day,
    COUNT(*) FILTER (WHERE e.event_type = 'state_change' AND (e.new_state->>'presence')::boolean = true) AS motion_events,
    COUNT(*) FILTER (WHERE e.event_type = 'state_change' AND d.device_type = 'contact_sensor') AS door_events,
    COUNT(*) FILTER (WHERE e.event_type = 'state_change' AND d.device_type = 'light') AS light_events,
    COUNT(*) AS total_events,
    MIN(e.recorded_at) AS first_event,
    MAX(e.recorded_at) AS last_event,
    -- Actieve uren (uren met minimaal 1 event)
    COUNT(DISTINCT date_trunc('hour', e.recorded_at)) AS active_hours
FROM raw_events e
JOIN hue_devices d ON e.device_id = d.id
WHERE d.room_name IS NOT NULL
GROUP BY d.room_name, date_trunc('day', e.recorded_at)
ORDER BY day DESC, d.room_name;

-- ============================================================
-- View: room_summary
-- Huidige status per kamer
-- ============================================================
CREATE OR REPLACE VIEW room_summary AS
SELECT
    d.room_name,
    COUNT(*) FILTER (WHERE d.device_type = 'light') AS light_count,
    COUNT(*) FILTER (WHERE d.device_type = 'motion_sensor') AS motion_sensor_count,
    COUNT(*) FILTER (WHERE d.device_type = 'contact_sensor') AS door_sensor_count,
    COUNT(*) FILTER (WHERE d.device_type NOT IN ('light', 'motion_sensor', 'contact_sensor')) AS other_sensor_count,
    COUNT(*) FILTER (WHERE d.device_type = 'light' AND (d.last_state->>'on')::boolean = true) AS lights_on,
    MAX(d.last_state_at) AS last_activity,
    -- Laatste motion event
    MAX(CASE WHEN d.device_type = 'motion_sensor' THEN d.last_state_at END) AS last_motion,
    -- Laatste deur event
    MAX(CASE WHEN d.device_type = 'contact_sensor' THEN d.last_state_at END) AS last_door
FROM hue_devices d
WHERE d.room_name IS NOT NULL
GROUP BY d.room_name
ORDER BY d.room_name;

-- ============================================================
-- View: recent_activity_by_room
-- Laatste motion en deur events per kamer (laatste 24 uur)
-- ============================================================
CREATE OR REPLACE VIEW recent_activity_by_room AS
SELECT
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
WHERE d.device_type IN ('motion_sensor', 'contact_sensor')
  AND d.room_name IS NOT NULL
  AND e.recorded_at > NOW() - INTERVAL '24 hours'
  AND e.event_type = 'state_change'
ORDER BY e.recorded_at DESC;

-- ============================================================
-- Function: get_room_activity_timeline
-- Haalt activiteit op voor een specifieke kamer en tijdsperiode
-- ============================================================
CREATE OR REPLACE FUNCTION get_room_activity_timeline(
    p_room_name TEXT,
    p_start_time TIMESTAMPTZ DEFAULT NOW() - INTERVAL '24 hours',
    p_end_time TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
    hour TIMESTAMPTZ,
    motion_events BIGINT,
    door_events BIGINT,
    light_events BIGINT,
    total_events BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        date_trunc('hour', e.recorded_at) AS hour,
        COUNT(*) FILTER (WHERE (e.new_state->>'presence')::boolean = true) AS motion_events,
        COUNT(*) FILTER (WHERE d.device_type = 'contact_sensor') AS door_events,
        COUNT(*) FILTER (WHERE d.device_type = 'light') AS light_events,
        COUNT(*) AS total_events
    FROM raw_events e
    JOIN hue_devices d ON e.device_id = d.id
    WHERE d.room_name = p_room_name
      AND e.recorded_at BETWEEN p_start_time AND p_end_time
      AND e.event_type = 'state_change'
    GROUP BY date_trunc('hour', e.recorded_at)
    ORDER BY hour;
END;
$$ LANGUAGE plpgsql;
