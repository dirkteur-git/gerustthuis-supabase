-- ============================================================
-- GerustThuis Supabase - Row Level Security Policies
-- Alleen ingelogde gebruikers kunnen data zien
-- ============================================================

-- ============================================================
-- Enable RLS on all tables
-- ============================================================

ALTER TABLE hue_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE hue_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE raw_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE physical_devices ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- hue_config policies
-- Gebruikers kunnen alleen hun eigen config zien/bewerken
-- ============================================================

-- Drop existing policies if any
DROP POLICY IF EXISTS "Users can view own hue_config" ON hue_config;
DROP POLICY IF EXISTS "Users can insert own hue_config" ON hue_config;
DROP POLICY IF EXISTS "Users can update own hue_config" ON hue_config;
DROP POLICY IF EXISTS "Service role full access hue_config" ON hue_config;

-- Authenticated users can read all configs (single tenant for now)
CREATE POLICY "Authenticated users can view hue_config"
ON hue_config FOR SELECT
TO authenticated
USING (true);

-- Only service role can insert/update (via Edge Functions)
CREATE POLICY "Service role can insert hue_config"
ON hue_config FOR INSERT
TO service_role
WITH CHECK (true);

CREATE POLICY "Service role can update hue_config"
ON hue_config FOR UPDATE
TO service_role
USING (true);

-- ============================================================
-- hue_devices policies
-- Authenticated users can read, service role can write
-- ============================================================

DROP POLICY IF EXISTS "Authenticated users can view hue_devices" ON hue_devices;
DROP POLICY IF EXISTS "Service role full access hue_devices" ON hue_devices;

CREATE POLICY "Authenticated users can view hue_devices"
ON hue_devices FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Service role can insert hue_devices"
ON hue_devices FOR INSERT
TO service_role
WITH CHECK (true);

CREATE POLICY "Service role can update hue_devices"
ON hue_devices FOR UPDATE
TO service_role
USING (true);

-- ============================================================
-- raw_events policies
-- Authenticated users can read, service role can write
-- ============================================================

DROP POLICY IF EXISTS "Authenticated users can view raw_events" ON raw_events;
DROP POLICY IF EXISTS "Service role full access raw_events" ON raw_events;

CREATE POLICY "Authenticated users can view raw_events"
ON raw_events FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Service role can insert raw_events"
ON raw_events FOR INSERT
TO service_role
WITH CHECK (true);

CREATE POLICY "Service role can delete raw_events"
ON raw_events FOR DELETE
TO service_role
USING (true);

-- ============================================================
-- physical_devices policies
-- Authenticated users can read, service role can write
-- ============================================================

DROP POLICY IF EXISTS "Authenticated users can view physical_devices" ON physical_devices;
DROP POLICY IF EXISTS "Service role full access physical_devices" ON physical_devices;

CREATE POLICY "Authenticated users can view physical_devices"
ON physical_devices FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Service role can insert physical_devices"
ON physical_devices FOR INSERT
TO service_role
WITH CHECK (true);

CREATE POLICY "Service role can update physical_devices"
ON physical_devices FOR UPDATE
TO service_role
USING (true);

-- ============================================================
-- room_activity_hourly policies (already has RLS enabled)
-- Update policies for authenticated users
-- ============================================================

DROP POLICY IF EXISTS "Allow public read access" ON room_activity_hourly;
DROP POLICY IF EXISTS "Allow service role insert" ON room_activity_hourly;
DROP POLICY IF EXISTS "Allow service role update" ON room_activity_hourly;

CREATE POLICY "Authenticated users can view room_activity_hourly"
ON room_activity_hourly FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Service role can insert room_activity_hourly"
ON room_activity_hourly FOR INSERT
TO service_role
WITH CHECK (true);

CREATE POLICY "Service role can update room_activity_hourly"
ON room_activity_hourly FOR UPDATE
TO service_role
USING (true);
