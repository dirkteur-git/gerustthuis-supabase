-- ============================================================
-- GerustThuis - Clean Rebuild: User Profiles + Households
--
-- Dit script rebuildt ALLES van migraties 009, 010, 011:
--   - user_profiles tabel + trigger
--   - households, household_members, household_invitations
--   - get_accessible_config_ids() functie
--   - RLS policies op alle tabellen (household-gebaseerd)
--   - Views met household filtering
--   - Signup triggers
--
-- VEILIG OM MEERDERE KEREN UIT TE VOEREN (idempotent)
-- Plak dit in de Supabase SQL Editor en voer het uit.
--
-- Datum: 2026-02-09
-- ============================================================

-- ============================================================
-- STAP 0: Helper functie die overal nodig is
-- ============================================================

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- STAP 1: OPRUIMEN — Drop alles van 009/010/011
-- ============================================================

-- Drop views die afhankelijk zijn van get_accessible_config_ids()
DROP VIEW IF EXISTS room_activity_daily CASCADE;
DROP VIEW IF EXISTS recent_activity_by_room CASCADE;
DROP VIEW IF EXISTS room_summary CASCADE;
DROP VIEW IF EXISTS sensor_health_overview CASCADE;
DROP VIEW IF EXISTS sensor_battery_trend CASCADE;
DROP VIEW IF EXISTS room_activity_hourly CASCADE;

-- Drop RLS policies die afhankelijk zijn van get_accessible_config_ids()
-- Deze moeten EERST weg voordat we de functie kunnen droppen
DO $$
BEGIN
    -- hue_config policies
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'hue_config') THEN
        DROP POLICY IF EXISTS "Users view own config" ON hue_config;
        DROP POLICY IF EXISTS "Authenticated users can view hue_config" ON hue_config;
    END IF;

    -- hue_devices policies
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'hue_devices') THEN
        DROP POLICY IF EXISTS "Users view own devices" ON hue_devices;
        DROP POLICY IF EXISTS "Authenticated users can view hue_devices" ON hue_devices;
    END IF;

    -- activity_events policies
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'activity_events') THEN
        DROP POLICY IF EXISTS "Users view own activity_events" ON activity_events;
        DROP POLICY IF EXISTS "Users view own events" ON activity_events;
    END IF;

    -- room_activity policies
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'room_activity') THEN
        DROP POLICY IF EXISTS "Users view own room activity" ON room_activity;
        DROP POLICY IF EXISTS "Users view own room_activity" ON room_activity;
    END IF;

    -- room_activity_hourly policies (tabel uit migration 007)
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'room_activity_hourly') THEN
        DROP POLICY IF EXISTS "Users view own room_activity_hourly" ON room_activity_hourly;
    END IF;

    -- daily_activity_stats policies
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'daily_activity_stats') THEN
        DROP POLICY IF EXISTS "Users view own daily_activity_stats" ON daily_activity_stats;
        DROP POLICY IF EXISTS "Users view own daily stats" ON daily_activity_stats;
    END IF;

    -- sensor_health_history policies
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'sensor_health_history') THEN
        DROP POLICY IF EXISTS "Users view own sensor health" ON sensor_health_history;
    END IF;

    -- physical_devices policies
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'physical_devices') THEN
        DROP POLICY IF EXISTS "Users view own physical_devices" ON physical_devices;
    END IF;
END $$;

-- Drop triggers
DROP TRIGGER IF EXISTS trigger_create_household_on_signup ON user_profiles;
DROP TRIGGER IF EXISTS trigger_households_updated_at ON households;
DROP TRIGGER IF EXISTS trigger_household_members_updated_at ON household_members;
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
DROP TRIGGER IF EXISTS update_user_profiles_updated_at ON user_profiles;

-- Drop FK constraint op user_profiles.active_household_id
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'user_profiles' AND column_name = 'active_household_id'
    ) THEN
        ALTER TABLE user_profiles DROP CONSTRAINT IF EXISTS user_profiles_active_household_id_fkey;
        UPDATE user_profiles SET active_household_id = NULL WHERE active_household_id IS NOT NULL;
    END IF;
END $$;

-- Drop household tabellen (juiste volgorde vanwege FKs)
DROP TABLE IF EXISTS household_invitations CASCADE;
DROP TABLE IF EXISTS household_members CASCADE;
DROP TABLE IF EXISTS households CASCADE;

-- Drop user_profiles (wordt opnieuw aangemaakt)
DROP TABLE IF EXISTS user_profiles CASCADE;

-- Drop oude functies (nu veilig want policies zijn al weg)
DROP FUNCTION IF EXISTS get_accessible_config_ids();
DROP FUNCTION IF EXISTS accept_household_invitation(UUID);
DROP FUNCTION IF EXISTS create_household_on_signup();
DROP FUNCTION IF EXISTS handle_new_user();
DROP FUNCTION IF EXISTS update_households_updated_at();
DROP FUNCTION IF EXISTS update_household_members_updated_at();

-- ============================================================
-- STAP 2: user_profiles tabel
-- ============================================================

CREATE TABLE user_profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    display_name VARCHAR(255),
    phone_country_code VARCHAR(5) DEFAULT '+31',
    phone_number VARCHAR(20),
    communication_preference VARCHAR(20) DEFAULT 'email',
    is_superadmin BOOLEAN DEFAULT false,
    active_household_id UUID, -- FK wordt later toegevoegd (na households CREATE)
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_user_profiles_id ON user_profiles(id);

-- Updated_at trigger
DROP TRIGGER IF EXISTS update_user_profiles_updated_at ON user_profiles;
CREATE TRIGGER update_user_profiles_updated_at
    BEFORE UPDATE ON user_profiles
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- RLS op user_profiles
ALTER TABLE user_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own profile" ON user_profiles;
CREATE POLICY "Users can view own profile"
    ON user_profiles FOR SELECT
    USING (auth.uid() = id);

DROP POLICY IF EXISTS "Users can update own profile" ON user_profiles;
CREATE POLICY "Users can update own profile"
    ON user_profiles FOR UPDATE
    USING (auth.uid() = id);

-- INSERT policy: allow auth triggers (SECURITY DEFINER) + users zelf
DROP POLICY IF EXISTS "Users can insert own profile" ON user_profiles;
CREATE POLICY "Users can insert own profile"
    ON user_profiles FOR INSERT
    WITH CHECK (auth.uid() = id);

-- Service role full access (nodig voor triggers)
DROP POLICY IF EXISTS "Service role full access user_profiles" ON user_profiles;
CREATE POLICY "Service role full access user_profiles"
    ON user_profiles FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- ============================================================
-- STAP 3: handle_new_user() — trigger op auth.users
-- Maakt automatisch een user_profiles record bij signup
-- ============================================================

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.user_profiles (id)
    VALUES (NEW.id)
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION handle_new_user();

-- ============================================================
-- STAP 4: Household tabellen
-- ============================================================

CREATE TABLE households (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    config_id UUID REFERENCES hue_config(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(config_id)
);

CREATE INDEX IF NOT EXISTS idx_households_config ON households(config_id);

-- Nu FK toevoegen op user_profiles
ALTER TABLE user_profiles
    ADD CONSTRAINT user_profiles_active_household_id_fkey
    FOREIGN KEY (active_household_id) REFERENCES households(id) ON DELETE SET NULL;

CREATE TABLE household_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    household_id UUID NOT NULL REFERENCES households(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role VARCHAR(20) NOT NULL DEFAULT 'viewer'
        CHECK (role IN ('admin', 'viewer')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(household_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_household_members_household ON household_members(household_id);
CREATE INDEX IF NOT EXISTS idx_household_members_user ON household_members(user_id);

CREATE TABLE household_invitations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    household_id UUID NOT NULL REFERENCES households(id) ON DELETE CASCADE,
    invited_email VARCHAR(255) NOT NULL,
    role VARCHAR(20) NOT NULL DEFAULT 'viewer'
        CHECK (role IN ('admin', 'viewer')),
    token UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    invited_by UUID NOT NULL REFERENCES auth.users(id),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '7 days'),
    accepted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_household_invitations_token ON household_invitations(token);
CREATE INDEX IF NOT EXISTS idx_household_invitations_household ON household_invitations(household_id);

-- Updated_at triggers
CREATE OR REPLACE FUNCTION update_households_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_households_updated_at ON households;
CREATE TRIGGER trigger_households_updated_at
    BEFORE UPDATE ON households
    FOR EACH ROW
    EXECUTE FUNCTION update_households_updated_at();

CREATE OR REPLACE FUNCTION update_household_members_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_household_members_updated_at ON household_members;
CREATE TRIGGER trigger_household_members_updated_at
    BEFORE UPDATE ON household_members
    FOR EACH ROW
    EXECUTE FUNCTION update_household_members_updated_at();

-- ============================================================
-- STAP 5: RLS op household tabellen
-- ============================================================

ALTER TABLE households ENABLE ROW LEVEL SECURITY;
ALTER TABLE household_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE household_invitations ENABLE ROW LEVEL SECURITY;

-- Households: leden + dirk@boostix.nl
CREATE POLICY "Users view own households" ON households
    FOR SELECT TO authenticated
    USING (
        id IN (SELECT household_id FROM household_members WHERE user_id = auth.uid())
        OR auth.jwt() ->> 'email' = 'dirk@boostix.nl'
    );

CREATE POLICY "Service role full access households" ON households
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- Members: leden van zelfde huishouden + dirk@boostix.nl
CREATE POLICY "Users view household members" ON household_members
    FOR SELECT TO authenticated
    USING (
        household_id IN (SELECT household_id FROM household_members WHERE user_id = auth.uid())
        OR auth.jwt() ->> 'email' = 'dirk@boostix.nl'
    );

CREATE POLICY "Admins manage household members" ON household_members
    FOR ALL TO authenticated
    USING (
        household_id IN (SELECT household_id FROM household_members WHERE user_id = auth.uid() AND role = 'admin')
        OR auth.jwt() ->> 'email' = 'dirk@boostix.nl'
    )
    WITH CHECK (
        household_id IN (SELECT household_id FROM household_members WHERE user_id = auth.uid() AND role = 'admin')
        OR auth.jwt() ->> 'email' = 'dirk@boostix.nl'
    );

CREATE POLICY "Service role full access members" ON household_members
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- Invitations
CREATE POLICY "Users view invitations" ON household_invitations
    FOR SELECT TO authenticated
    USING (
        invited_email = auth.jwt() ->> 'email'
        OR household_id IN (SELECT household_id FROM household_members WHERE user_id = auth.uid() AND role = 'admin')
        OR auth.jwt() ->> 'email' = 'dirk@boostix.nl'
    );

CREATE POLICY "Admins create invitations" ON household_invitations
    FOR INSERT TO authenticated
    WITH CHECK (
        household_id IN (SELECT household_id FROM household_members WHERE user_id = auth.uid() AND role = 'admin')
        OR auth.jwt() ->> 'email' = 'dirk@boostix.nl'
    );

CREATE POLICY "Users accept invitations" ON household_invitations
    FOR UPDATE TO authenticated
    USING (invited_email = auth.jwt() ->> 'email')
    WITH CHECK (invited_email = auth.jwt() ->> 'email');

CREATE POLICY "Service role full access invitations" ON household_invitations
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- ============================================================
-- STAP 6: get_accessible_config_ids() — centrale RLS helper
-- ============================================================

CREATE OR REPLACE FUNCTION get_accessible_config_ids()
RETURNS SETOF UUID AS $$
DECLARE
    v_user_id UUID;
    v_user_email TEXT;
    v_active_household_id UUID;
BEGIN
    v_user_id := auth.uid();
    v_user_email := auth.jwt() ->> 'email';

    -- dirk@boostix.nl = onzichtbare global admin
    IF v_user_email = 'dirk@boostix.nl' THEN
        SELECT active_household_id INTO v_active_household_id
        FROM user_profiles WHERE id = v_user_id;

        IF v_active_household_id IS NOT NULL THEN
            RETURN QUERY
            SELECT h.config_id FROM households h
            WHERE h.id = v_active_household_id AND h.config_id IS NOT NULL;
            RETURN;
        END IF;

        -- Zonder actief huishouden: alles
        RETURN QUERY SELECT id FROM hue_config;
        RETURN;
    END IF;

    -- Normale user: via household_members
    RETURN QUERY
    SELECT DISTINCT h.config_id
    FROM household_members hm
    JOIN households h ON hm.household_id = h.id
    WHERE hm.user_id = v_user_id AND h.config_id IS NOT NULL;

    -- Fallback: directe email match (backward compat voor users zonder huishouden)
    RETURN QUERY
    SELECT id FROM hue_config
    WHERE user_email = v_user_email
      AND id NOT IN (
          SELECT h2.config_id FROM household_members hm2
          JOIN households h2 ON hm2.household_id = h2.id
          WHERE hm2.user_id = v_user_id AND h2.config_id IS NOT NULL
      );

    RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- ============================================================
-- STAP 7: RLS policies op data-tabellen updaten
-- Vervangt email-based filtering door get_accessible_config_ids()
-- ============================================================

DO $$
BEGIN
    -- hue_config
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'hue_config') THEN
        DROP POLICY IF EXISTS "Users view own config" ON hue_config;
        DROP POLICY IF EXISTS "Authenticated users can view hue_config" ON hue_config;
        EXECUTE 'CREATE POLICY "Users view own config" ON hue_config
            FOR SELECT TO authenticated
            USING (id IN (SELECT get_accessible_config_ids()))';
        ALTER TABLE hue_config ENABLE ROW LEVEL SECURITY;
    END IF;

    -- hue_devices
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'hue_devices') THEN
        DROP POLICY IF EXISTS "Users view own devices" ON hue_devices;
        DROP POLICY IF EXISTS "Authenticated users can view hue_devices" ON hue_devices;
        EXECUTE 'CREATE POLICY "Users view own devices" ON hue_devices
            FOR SELECT TO authenticated
            USING (config_id IN (SELECT get_accessible_config_ids()))';
        ALTER TABLE hue_devices ENABLE ROW LEVEL SECURITY;
    END IF;

    -- activity_events
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'activity_events') THEN
        DROP POLICY IF EXISTS "Users view own activity_events" ON activity_events;
        DROP POLICY IF EXISTS "Users view own events" ON activity_events;
        EXECUTE 'CREATE POLICY "Users view own activity_events" ON activity_events
            FOR SELECT TO authenticated
            USING (config_id IN (SELECT get_accessible_config_ids()))';
        ALTER TABLE activity_events ENABLE ROW LEVEL SECURITY;
    END IF;

    -- room_activity
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'room_activity') THEN
        DROP POLICY IF EXISTS "Users view own room activity" ON room_activity;
        DROP POLICY IF EXISTS "Users view own room_activity" ON room_activity;
        EXECUTE 'CREATE POLICY "Users view own room activity" ON room_activity
            FOR SELECT TO authenticated
            USING (config_id IN (SELECT get_accessible_config_ids()))';
        ALTER TABLE room_activity ENABLE ROW LEVEL SECURITY;
    END IF;

    -- room_activity_hourly (TABEL, niet view — uit migration 007)
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'room_activity_hourly') THEN
        DROP POLICY IF EXISTS "Users view own room_activity_hourly" ON room_activity_hourly;
        EXECUTE 'CREATE POLICY "Users view own room_activity_hourly" ON room_activity_hourly
            FOR SELECT TO authenticated
            USING (config_id IN (SELECT get_accessible_config_ids()))';
        ALTER TABLE room_activity_hourly ENABLE ROW LEVEL SECURITY;
    END IF;

    -- daily_activity_stats
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'daily_activity_stats') THEN
        DROP POLICY IF EXISTS "Users view own daily_activity_stats" ON daily_activity_stats;
        DROP POLICY IF EXISTS "Users view own daily stats" ON daily_activity_stats;
        EXECUTE 'CREATE POLICY "Users view own daily_activity_stats" ON daily_activity_stats
            FOR SELECT TO authenticated
            USING (config_id IN (SELECT get_accessible_config_ids()))';
        ALTER TABLE daily_activity_stats ENABLE ROW LEVEL SECURITY;
    END IF;

    -- sensor_health_history
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'sensor_health_history') THEN
        DROP POLICY IF EXISTS "Users view own sensor health" ON sensor_health_history;
        EXECUTE 'CREATE POLICY "Users view own sensor health" ON sensor_health_history
            FOR SELECT TO authenticated
            USING (config_id IN (SELECT get_accessible_config_ids()))';
        ALTER TABLE sensor_health_history ENABLE ROW LEVEL SECURITY;
    END IF;

    -- physical_devices
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'physical_devices') THEN
        DROP POLICY IF EXISTS "Users view own physical_devices" ON physical_devices;
        EXECUTE 'CREATE POLICY "Users view own physical_devices" ON physical_devices
            FOR SELECT TO authenticated
            USING (config_id IN (SELECT get_accessible_config_ids()))';
        ALTER TABLE physical_devices ENABLE ROW LEVEL SECURITY;
    END IF;
END $$;

-- ============================================================
-- STAP 8: Views opnieuw aanmaken met get_accessible_config_ids()
-- ============================================================

DO $$
BEGIN
    -- room_activity views
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'room_activity') THEN
        EXECUTE '
        CREATE OR REPLACE VIEW room_activity_daily AS
        SELECT
            ra.config_id,
            ra.room_name,
            date_trunc(''day'', ra.activity_window) AS day,
            SUM(ra.trigger_count) AS total_events,
            COUNT(DISTINCT date_trunc(''hour'', ra.activity_window)) AS active_hours,
            MIN(ra.first_trigger_at) AS first_event,
            MAX(ra.last_trigger_at) AS last_event
        FROM room_activity ra
        WHERE ra.config_id IN (SELECT get_accessible_config_ids())
        GROUP BY ra.config_id, ra.room_name, date_trunc(''day'', ra.activity_window)
        ORDER BY day DESC, ra.room_name';

        RAISE NOTICE 'View room_activity_daily aangemaakt';
    ELSE
        RAISE NOTICE 'room_activity tabel niet gevonden, room_activity_daily overgeslagen';
    END IF;

    -- recent_activity_by_room
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'activity_events') THEN
        EXECUTE '
        CREATE OR REPLACE VIEW recent_activity_by_room AS
        SELECT
            ae.config_id,
            ae.room_name,
            ae.recorded_at,
            ae.device_type,
            ae.is_on AS triggered,
            hd.name AS sensor_name
        FROM activity_events ae
        JOIN hue_devices hd ON ae.device_id = hd.id
        WHERE ae.device_type IN (''motion_sensor'', ''contact_sensor'')
          AND ae.room_name IS NOT NULL
          AND ae.recorded_at > NOW() - INTERVAL ''24 hours''
          AND ae.config_id IN (SELECT get_accessible_config_ids())
        ORDER BY ae.recorded_at DESC';

        RAISE NOTICE 'View recent_activity_by_room aangemaakt';
    END IF;

    -- room_summary + sensor_health_overview
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'hue_devices') THEN
        EXECUTE '
        CREATE OR REPLACE VIEW room_summary AS
        SELECT
            d.config_id,
            d.room_name,
            COUNT(*) FILTER (WHERE d.device_type = ''light'') AS light_count,
            COUNT(*) FILTER (WHERE d.device_type = ''motion_sensor'') AS motion_sensor_count,
            COUNT(*) FILTER (WHERE d.device_type = ''contact_sensor'') AS door_sensor_count,
            COUNT(*) FILTER (WHERE d.device_type NOT IN (''light'', ''motion_sensor'', ''contact_sensor'')) AS other_sensor_count,
            COUNT(*) FILTER (WHERE d.device_type = ''light'' AND (d.last_state->>''on'')::boolean = true) AS lights_on,
            MAX(d.last_state_at) AS last_activity,
            MAX(CASE WHEN d.device_type = ''motion_sensor'' THEN d.last_state_at END) AS last_motion,
            MAX(CASE WHEN d.device_type = ''contact_sensor'' THEN d.last_state_at END) AS last_door
        FROM hue_devices d
        WHERE d.room_name IS NOT NULL
          AND d.config_id IN (SELECT get_accessible_config_ids())
        GROUP BY d.config_id, d.room_name
        ORDER BY d.room_name';

        EXECUTE '
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
        WHERE d.device_type IN (''motion_sensor'', ''contact_sensor'')
          AND d.config_id IN (SELECT get_accessible_config_ids())
        ORDER BY
            CASE d.health_status
                WHEN ''failure'' THEN 1
                WHEN ''offline'' THEN 2
                WHEN ''warning'' THEN 3
                WHEN ''unknown'' THEN 4
                ELSE 5
            END,
            d.room_name,
            d.name';

        RAISE NOTICE 'Views room_summary en sensor_health_overview aangemaakt';
    END IF;

    -- sensor_battery_trend
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'sensor_health_history') THEN
        EXECUTE '
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
        WHERE h.config_id IN (SELECT get_accessible_config_ids())
          AND h.recorded_at > NOW() - INTERVAL ''30 days''
        ORDER BY h.device_id, h.recorded_at DESC';

        RAISE NOTICE 'View sensor_battery_trend aangemaakt';
    END IF;
END $$;

-- ============================================================
-- STAP 9: Data migratie — maak huishoudens voor bestaande data
-- ============================================================

-- 1. Maak een household per bestaande hue_config
INSERT INTO households (name, config_id)
SELECT
    COALESCE(c.user_email, 'Huishouden') AS name,
    c.id
FROM hue_config c
ON CONFLICT (config_id) DO NOTHING;

-- 2. Zorg dat alle bestaande users een user_profiles record hebben
INSERT INTO user_profiles (id)
SELECT id FROM auth.users
ON CONFLICT (id) DO NOTHING;

-- 3. Voeg config-eigenaren toe als admin van hun huishouden
INSERT INTO household_members (household_id, user_id, role)
SELECT
    h.id,
    u.id,
    'admin'
FROM hue_config c
JOIN households h ON h.config_id = c.id
JOIN auth.users u ON u.email = c.user_email
ON CONFLICT (household_id, user_id) DO NOTHING;

-- 4. Users zonder huishouden krijgen een persoonlijk huishouden
-- dirk@boostix.nl wordt NIET als lid toegevoegd (krijgt access via SQL functie)
DO $$
DECLARE
    r RECORD;
    new_household_id UUID;
BEGIN
    FOR r IN
        SELECT u.id AS user_id, u.email
        FROM auth.users u
        WHERE u.email != 'dirk@boostix.nl'
          AND NOT EXISTS (
              SELECT 1 FROM household_members hm WHERE hm.user_id = u.id
          )
    LOOP
        INSERT INTO households (name, config_id)
        VALUES (COALESCE(r.email, 'Mijn huishouden'), NULL)
        RETURNING id INTO new_household_id;

        INSERT INTO household_members (household_id, user_id, role)
        VALUES (new_household_id, r.user_id, 'admin')
        ON CONFLICT (household_id, user_id) DO NOTHING;
    END LOOP;
END $$;

-- 5. Zet active_household_id voor alle users die er nog geen hebben
UPDATE user_profiles up
SET active_household_id = (
    SELECT hm.household_id
    FROM household_members hm
    WHERE hm.user_id = up.id
    LIMIT 1
)
WHERE up.active_household_id IS NULL
  AND EXISTS (SELECT 1 FROM household_members hm WHERE hm.user_id = up.id);

-- ============================================================
-- STAP 10: Trigger — automatisch huishouden bij nieuwe user signup
-- ============================================================

CREATE OR REPLACE FUNCTION create_household_on_signup()
RETURNS TRIGGER AS $$
DECLARE
    new_household_id UUID;
    user_email TEXT;
BEGIN
    -- Haal email op van de nieuwe user
    SELECT email INTO user_email FROM auth.users WHERE id = NEW.id;

    -- dirk@boostix.nl krijgt geen eigen huishouden (onzichtbare global admin)
    IF user_email = 'dirk@boostix.nl' THEN
        RETURN NEW;
    END IF;

    -- Maak een huishouden aan
    INSERT INTO households (name, config_id)
    VALUES (COALESCE(user_email, 'Mijn huishouden'), NULL)
    RETURNING id INTO new_household_id;

    -- Voeg user toe als admin
    INSERT INTO household_members (household_id, user_id, role)
    VALUES (new_household_id, NEW.id, 'admin');

    -- Zet als actief huishouden
    UPDATE user_profiles SET active_household_id = new_household_id WHERE id = NEW.id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_create_household_on_signup ON user_profiles;
CREATE TRIGGER trigger_create_household_on_signup
    AFTER INSERT ON user_profiles
    FOR EACH ROW
    EXECUTE FUNCTION create_household_on_signup();

-- ============================================================
-- STAP 11: RPC — uitnodiging accepteren
-- ============================================================

CREATE OR REPLACE FUNCTION accept_household_invitation(p_token UUID)
RETURNS JSON AS $$
DECLARE
    v_invitation household_invitations%ROWTYPE;
    v_user_id UUID;
    v_user_email TEXT;
BEGIN
    v_user_id := auth.uid();
    v_user_email := auth.jwt() ->> 'email';

    SELECT * INTO v_invitation
    FROM household_invitations
    WHERE token = p_token
      AND accepted_at IS NULL
      AND expires_at > NOW();

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Uitnodiging niet gevonden of verlopen');
    END IF;

    IF v_invitation.invited_email != v_user_email THEN
        RETURN json_build_object('success', false, 'error', 'Deze uitnodiging is voor een ander e-mailadres');
    END IF;

    INSERT INTO household_members (household_id, user_id, role)
    VALUES (v_invitation.household_id, v_user_id, v_invitation.role)
    ON CONFLICT (household_id, user_id) DO UPDATE SET role = v_invitation.role;

    UPDATE household_invitations
    SET accepted_at = NOW()
    WHERE id = v_invitation.id;

    RETURN json_build_object('success', true, 'household_id', v_invitation.household_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- STAP 12: Commentaar
-- ============================================================

COMMENT ON TABLE user_profiles IS 'Gebruikersprofielen gekoppeld aan auth.users';
COMMENT ON TABLE households IS 'Huishoudens - gekoppeld aan een Hue Bridge config';
COMMENT ON TABLE household_members IS 'Leden van een huishouden met admin/viewer rol';
COMMENT ON TABLE household_invitations IS 'Uitnodigingen voor nieuwe huishoudenleden';
COMMENT ON FUNCTION get_accessible_config_ids IS 'Retourneert config_ids waar de huidige user toegang toe heeft';
COMMENT ON FUNCTION handle_new_user IS 'Maakt automatisch user_profiles record bij signup';
COMMENT ON FUNCTION create_household_on_signup IS 'Maakt automatisch huishouden bij nieuwe user';
COMMENT ON FUNCTION accept_household_invitation IS 'Accepteer een uitnodiging en word lid van het huishouden';

-- ============================================================
-- KLAAR! Signup en login zouden nu moeten werken.
-- ============================================================

-- Verificatie: check of triggers bestaan
DO $$
BEGIN
    -- Check on_auth_user_created trigger
    IF EXISTS (
        SELECT 1 FROM information_schema.triggers
        WHERE trigger_name = 'on_auth_user_created'
          AND event_object_schema = 'auth'
          AND event_object_table = 'users'
    ) THEN
        RAISE NOTICE '✓ Trigger on_auth_user_created op auth.users bestaat';
    ELSE
        RAISE WARNING '✗ Trigger on_auth_user_created ONTBREEKT op auth.users!';
    END IF;

    -- Check create_household_on_signup trigger
    IF EXISTS (
        SELECT 1 FROM information_schema.triggers
        WHERE trigger_name = 'trigger_create_household_on_signup'
          AND event_object_table = 'user_profiles'
    ) THEN
        RAISE NOTICE '✓ Trigger trigger_create_household_on_signup op user_profiles bestaat';
    ELSE
        RAISE WARNING '✗ Trigger trigger_create_household_on_signup ONTBREEKT op user_profiles!';
    END IF;

    -- Check user_profiles tabel
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'user_profiles') THEN
        RAISE NOTICE '✓ Tabel user_profiles bestaat';
    ELSE
        RAISE WARNING '✗ Tabel user_profiles ONTBREEKT!';
    END IF;

    -- Check households tabel
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'households') THEN
        RAISE NOTICE '✓ Tabel households bestaat';
    ELSE
        RAISE WARNING '✗ Tabel households ONTBREEKT!';
    END IF;

    -- Check household_members tabel
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'household_members') THEN
        RAISE NOTICE '✓ Tabel household_members bestaat';
    ELSE
        RAISE WARNING '✗ Tabel household_members ONTBREEKT!';
    END IF;

    -- Check get_accessible_config_ids functie
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'get_accessible_config_ids') THEN
        RAISE NOTICE '✓ Functie get_accessible_config_ids bestaat';
    ELSE
        RAISE WARNING '✗ Functie get_accessible_config_ids ONTBREEKT!';
    END IF;

    -- Count bestaande users en households
    RAISE NOTICE 'Aantal users met profile: %', (SELECT COUNT(*) FROM user_profiles);
    RAISE NOTICE 'Aantal households: %', (SELECT COUNT(*) FROM households);
    RAISE NOTICE 'Aantal household_members: %', (SELECT COUNT(*) FROM household_members);
END $$;
