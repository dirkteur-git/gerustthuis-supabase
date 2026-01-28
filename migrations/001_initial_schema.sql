-- ============================================================
-- GerustThuis Supabase - Initial Schema
-- Simpele Hue monitoring: state changes + batterij levels
-- ============================================================

-- ============================================================
-- Table: hue_config
-- OAuth tokens en bridge configuratie
-- ============================================================
CREATE TABLE hue_config (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_email VARCHAR(255) NOT NULL,

    -- OAuth tokens
    access_token TEXT NOT NULL,
    refresh_token TEXT NOT NULL,
    token_expires_at TIMESTAMPTZ NOT NULL,

    -- Bridge info
    bridge_username VARCHAR(255),
    bridge_id VARCHAR(255),

    -- Status
    status VARCHAR(20) DEFAULT 'active',  -- active, error, expired
    last_sync_at TIMESTAMPTZ,
    last_error TEXT,

    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Eén config per email (voor nu)
CREATE UNIQUE INDEX idx_hue_config_email ON hue_config(user_email);

-- ============================================================
-- Table: hue_devices
-- Bekende devices + laatste state (voor change detection)
-- ============================================================
CREATE TABLE hue_devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config_id UUID REFERENCES hue_config(id) ON DELETE CASCADE,

    -- Hue identifiers
    hue_id VARCHAR(255) NOT NULL,        -- v1 API ID (bijv. "1", "2")
    hue_unique_id VARCHAR(255),          -- MAC-based unique ID

    -- Device info
    device_type VARCHAR(50) NOT NULL,    -- light, motion_sensor, contact_sensor, temperature_sensor, button
    name VARCHAR(255),
    room_name VARCHAR(255),

    -- Laatste state (voor change detection)
    last_state JSONB DEFAULT '{}',
    last_state_at TIMESTAMPTZ,

    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(config_id, hue_unique_id)
);

CREATE INDEX idx_hue_devices_config ON hue_devices(config_id);
CREATE INDEX idx_hue_devices_type ON hue_devices(device_type);

-- ============================================================
-- Table: raw_events
-- Alleen state changes worden opgeslagen
-- ============================================================
CREATE TABLE raw_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id UUID REFERENCES hue_devices(id) ON DELETE CASCADE,

    -- Event data
    event_type VARCHAR(50) NOT NULL,     -- state_change, battery_update
    previous_state JSONB,                -- State voor de change
    new_state JSONB NOT NULL,            -- Nieuwe state

    -- Timestamps
    recorded_at TIMESTAMPTZ NOT NULL,    -- Wanneer de change plaatsvond
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Query patronen: device + tijd, alleen tijd, event type
CREATE INDEX idx_raw_events_device_time ON raw_events(device_id, recorded_at DESC);
CREATE INDEX idx_raw_events_time ON raw_events(recorded_at DESC);
CREATE INDEX idx_raw_events_type ON raw_events(event_type);

-- ============================================================
-- Geen RLS voor testen
-- ============================================================
ALTER TABLE hue_config DISABLE ROW LEVEL SECURITY;
ALTER TABLE hue_devices DISABLE ROW LEVEL SECURITY;
ALTER TABLE raw_events DISABLE ROW LEVEL SECURITY;

-- ============================================================
-- Helper function: update updated_at timestamp
-- ============================================================
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_hue_config_updated_at
    BEFORE UPDATE ON hue_config
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_hue_devices_updated_at
    BEFORE UPDATE ON hue_devices
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
