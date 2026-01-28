-- ============================================================
-- GerustThuis Supabase - Physical Devices Grouping
-- Groepeert Hue motion sensor capabilities in fysieke devices
-- ============================================================

-- ============================================================
-- Table: physical_devices
-- Fysieke devices die meerdere sensor capabilities bevatten
-- Bijv. Hue motion sensor = motion + temperature + light_level
-- ============================================================
CREATE TABLE physical_devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config_id UUID REFERENCES hue_config(id) ON DELETE CASCADE,

    -- Identifier (MAC prefix uit hue_unique_id, eerste 23 karakters)
    mac_prefix VARCHAR(23) NOT NULL,

    -- Device info (opgeslagen op physical level, niet per capability)
    name VARCHAR(255),
    room_name VARCHAR(255),
    manufacturer VARCHAR(100) DEFAULT 'Philips',
    model VARCHAR(100),

    -- Batterij (gedeeld door alle capabilities)
    battery_level INTEGER,
    battery_updated_at TIMESTAMPTZ,

    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(config_id, mac_prefix)
);

CREATE INDEX idx_physical_devices_config ON physical_devices(config_id);
CREATE INDEX idx_physical_devices_room ON physical_devices(room_name);

-- ============================================================
-- Add FK to hue_devices
-- Link capabilities aan hun physical device
-- ============================================================
ALTER TABLE hue_devices
ADD COLUMN physical_device_id UUID REFERENCES physical_devices(id);

CREATE INDEX idx_hue_devices_physical ON hue_devices(physical_device_id);

-- ============================================================
-- Migrate existing data
-- Maak physical devices aan voor bestaande multi-capability sensors
-- ============================================================

-- Insert physical device voor elke unieke MAC prefix
-- Gebruik de motion_sensor naam als primaire naam (vandaar de ORDER BY)
INSERT INTO physical_devices (config_id, mac_prefix, name, room_name)
SELECT DISTINCT ON (config_id, LEFT(hue_unique_id, 23))
    config_id,
    LEFT(hue_unique_id, 23) as mac_prefix,
    name,
    room_name
FROM hue_devices
WHERE hue_unique_id IS NOT NULL
  AND device_type IN ('motion_sensor', 'temperature_sensor', 'light_sensor')
ORDER BY config_id, LEFT(hue_unique_id, 23),
    CASE device_type
        WHEN 'motion_sensor' THEN 1
        WHEN 'temperature_sensor' THEN 2
        WHEN 'light_sensor' THEN 3
        ELSE 4
    END;

-- Link bestaande capabilities aan hun physical device
UPDATE hue_devices d
SET physical_device_id = p.id
FROM physical_devices p
WHERE d.config_id = p.config_id
  AND LEFT(d.hue_unique_id, 23) = p.mac_prefix
  AND d.device_type IN ('motion_sensor', 'temperature_sensor', 'light_sensor');

-- ============================================================
-- Trigger: update updated_at
-- ============================================================
CREATE TRIGGER update_physical_devices_updated_at
    BEFORE UPDATE ON physical_devices
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- Disable RLS (consistent met andere tabellen)
-- ============================================================
ALTER TABLE physical_devices DISABLE ROW LEVEL SECURITY;

-- ============================================================
-- View: physical_devices_with_capabilities
-- Handige view voor queries met alle capabilities
-- ============================================================
CREATE OR REPLACE VIEW physical_devices_with_capabilities AS
SELECT
    p.id,
    p.config_id,
    p.mac_prefix,
    p.name,
    p.room_name,
    p.manufacturer,
    p.model,
    p.battery_level,
    p.battery_updated_at,
    p.created_at,
    p.updated_at,
    -- Capabilities als JSONB array
    COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id', d.id,
                'device_type', d.device_type,
                'hue_id', d.hue_id,
                'hue_unique_id', d.hue_unique_id,
                'last_state', d.last_state,
                'last_state_at', d.last_state_at
            )
        ) FILTER (WHERE d.id IS NOT NULL),
        '[]'::jsonb
    ) AS capabilities,
    -- Laatste activiteit over alle capabilities
    MAX(d.last_state_at) AS last_activity
FROM physical_devices p
LEFT JOIN hue_devices d ON d.physical_device_id = p.id
GROUP BY p.id;

-- ============================================================
-- Update room_summary view
-- Tel physical devices in plaats van individuele capabilities
-- ============================================================
CREATE OR REPLACE VIEW room_summary AS
SELECT
    COALESCE(p.room_name, d.room_name) as room_name,
    COUNT(*) FILTER (WHERE d.device_type = 'light') AS light_count,
    -- Tel unieke physical devices voor motion sensors
    COUNT(DISTINCT p.id) FILTER (WHERE d.device_type = 'motion_sensor') AS motion_sensor_count,
    COUNT(*) FILTER (WHERE d.device_type = 'contact_sensor') AS door_sensor_count,
    COUNT(*) FILTER (WHERE d.device_type NOT IN ('light', 'motion_sensor', 'contact_sensor', 'temperature_sensor', 'light_sensor')) AS other_sensor_count,
    COUNT(*) FILTER (WHERE d.device_type = 'light' AND (d.last_state->>'on')::boolean = true) AS lights_on,
    MAX(d.last_state_at) AS last_activity,
    MAX(CASE WHEN d.device_type = 'motion_sensor' THEN d.last_state_at END) AS last_motion,
    MAX(CASE WHEN d.device_type = 'contact_sensor' THEN d.last_state_at END) AS last_door
FROM hue_devices d
LEFT JOIN physical_devices p ON d.physical_device_id = p.id
WHERE COALESCE(p.room_name, d.room_name) IS NOT NULL
GROUP BY COALESCE(p.room_name, d.room_name)
ORDER BY room_name;
