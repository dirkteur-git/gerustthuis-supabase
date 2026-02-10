-- ============================================================
-- GerustThuis - Households, Rollen & Super Admin
-- Multi-user huishouden management met rolgebaseerde toegang
-- Datum: 2026-02-08
-- ============================================================

-- ============================================================
-- STAP 1: Nieuwe tabellen
-- ============================================================

-- Households: Een huishouden is gekoppeld aan een hue_config (bridge)
CREATE TABLE IF NOT EXISTS households (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    config_id UUID REFERENCES hue_config(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(config_id)
);

CREATE INDEX IF NOT EXISTS idx_households_config ON households(config_id);

-- Household members: koppelt users aan huishoudens met rol
CREATE TABLE IF NOT EXISTS household_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    household_id UUID NOT NULL REFERENCES households(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role VARCHAR(20) NOT NULL DEFAULT 'viewer',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(household_id, user_id),
    CONSTRAINT valid_role CHECK (role IN ('admin', 'viewer'))
);

CREATE INDEX IF NOT EXISTS idx_household_members_household ON household_members(household_id);
CREATE INDEX IF NOT EXISTS idx_household_members_user ON household_members(user_id);

-- Household invitations: uitnodigingen met token
CREATE TABLE IF NOT EXISTS household_invitations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    household_id UUID NOT NULL REFERENCES households(id) ON DELETE CASCADE,
    invited_email VARCHAR(255) NOT NULL,
    role VARCHAR(20) NOT NULL DEFAULT 'viewer',
    token UUID NOT NULL DEFAULT gen_random_uuid(),
    invited_by UUID NOT NULL REFERENCES auth.users(id),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '7 days'),
    accepted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(token),
    CONSTRAINT valid_invitation_role CHECK (role IN ('admin', 'viewer'))
);

CREATE INDEX IF NOT EXISTS idx_household_invitations_token ON household_invitations(token);
CREATE INDEX IF NOT EXISTS idx_household_invitations_household ON household_invitations(household_id);
CREATE INDEX IF NOT EXISTS idx_household_invitations_email ON household_invitations(invited_email);

-- ============================================================
-- STAP 2: User profiles uitbreiden
-- ============================================================

ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS is_superadmin BOOLEAN DEFAULT false;
ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS active_household_id UUID REFERENCES households(id) ON DELETE SET NULL;

-- ============================================================
-- STAP 3: Updated_at triggers
-- ============================================================

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
-- STAP 4: RLS helper functie
-- Retourneert config_ids waar de huidige gebruiker toegang toe heeft
-- ============================================================

CREATE OR REPLACE FUNCTION get_accessible_config_ids()
RETURNS SETOF UUID AS $$
DECLARE
    v_user_id UUID;
    v_is_superadmin BOOLEAN;
    v_active_household_id UUID;
    v_user_email TEXT;
BEGIN
    v_user_id := auth.uid();
    v_user_email := auth.jwt() ->> 'email';

    -- Check superadmin status
    SELECT is_superadmin, active_household_id
    INTO v_is_superadmin, v_active_household_id
    FROM user_profiles
    WHERE id = v_user_id;

    -- Superadmin met actief huishouden → alleen dat huishouden
    IF v_is_superadmin = true AND v_active_household_id IS NOT NULL THEN
        RETURN QUERY
        SELECT h.config_id FROM households h
        WHERE h.id = v_active_household_id
          AND h.config_id IS NOT NULL;
        RETURN;
    END IF;

    -- Superadmin zonder actief huishouden → alles
    IF v_is_superadmin = true THEN
        RETURN QUERY
        SELECT id FROM hue_config;
        RETURN;
    END IF;

    -- Normale user → via household_members
    RETURN QUERY
    SELECT DISTINCT h.config_id
    FROM household_members hm
    JOIN households h ON hm.household_id = h.id
    WHERE hm.user_id = v_user_id
      AND h.config_id IS NOT NULL;

    -- Fallback: directe email match (backward compat voor users zonder huishouden)
    RETURN QUERY
    SELECT id FROM hue_config
    WHERE user_email = v_user_email
      AND id NOT IN (
          SELECT h.config_id
          FROM household_members hm
          JOIN households h ON hm.household_id = h.id
          WHERE hm.user_id = v_user_id
            AND h.config_id IS NOT NULL
      );

    RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- ============================================================
-- STAP 5: RLS op nieuwe tabellen
-- ============================================================

ALTER TABLE households ENABLE ROW LEVEL SECURITY;
ALTER TABLE household_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE household_invitations ENABLE ROW LEVEL SECURITY;

-- Households: gebruikers zien huishoudens waar ze lid van zijn
DROP POLICY IF EXISTS "Users view own households" ON households;
CREATE POLICY "Users view own households" ON households
    FOR SELECT TO authenticated
    USING (
        id IN (SELECT household_id FROM household_members WHERE user_id = auth.uid())
        OR EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND is_superadmin = true)
    );

DROP POLICY IF EXISTS "Service role full access households" ON households;
CREATE POLICY "Service role full access households" ON households
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- Household members: gebruikers zien leden van hun huishouden
DROP POLICY IF EXISTS "Users view household members" ON household_members;
CREATE POLICY "Users view household members" ON household_members
    FOR SELECT TO authenticated
    USING (
        household_id IN (SELECT household_id FROM household_members WHERE user_id = auth.uid())
        OR EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND is_superadmin = true)
    );

-- Admins kunnen leden toevoegen/verwijderen
DROP POLICY IF EXISTS "Admins manage household members" ON household_members;
CREATE POLICY "Admins manage household members" ON household_members
    FOR ALL TO authenticated
    USING (
        household_id IN (
            SELECT household_id FROM household_members
            WHERE user_id = auth.uid() AND role = 'admin'
        )
        OR EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND is_superadmin = true)
    )
    WITH CHECK (
        household_id IN (
            SELECT household_id FROM household_members
            WHERE user_id = auth.uid() AND role = 'admin'
        )
        OR EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND is_superadmin = true)
    );

DROP POLICY IF EXISTS "Service role full access household_members" ON household_members;
CREATE POLICY "Service role full access household_members" ON household_members
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- Invitations: admins van het huishouden kunnen uitnodigingen beheren
DROP POLICY IF EXISTS "Users view own invitations" ON household_invitations;
CREATE POLICY "Users view own invitations" ON household_invitations
    FOR SELECT TO authenticated
    USING (
        invited_email = auth.jwt() ->> 'email'
        OR household_id IN (
            SELECT household_id FROM household_members
            WHERE user_id = auth.uid() AND role = 'admin'
        )
        OR EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND is_superadmin = true)
    );

DROP POLICY IF EXISTS "Admins manage invitations" ON household_invitations;
CREATE POLICY "Admins manage invitations" ON household_invitations
    FOR INSERT TO authenticated
    WITH CHECK (
        household_id IN (
            SELECT household_id FROM household_members
            WHERE user_id = auth.uid() AND role = 'admin'
        )
        OR EXISTS (SELECT 1 FROM user_profiles WHERE id = auth.uid() AND is_superadmin = true)
    );

DROP POLICY IF EXISTS "Users can accept invitations" ON household_invitations;
CREATE POLICY "Users can accept invitations" ON household_invitations
    FOR UPDATE TO authenticated
    USING (invited_email = auth.jwt() ->> 'email')
    WITH CHECK (invited_email = auth.jwt() ->> 'email');

DROP POLICY IF EXISTS "Service role full access household_invitations" ON household_invitations;
CREATE POLICY "Service role full access household_invitations" ON household_invitations
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- ============================================================
-- STAP 6: Update RLS policies op data-tabellen
-- Vervang email-based filtering door get_accessible_config_ids()
-- ============================================================

-- Alle RLS policy updates conditioneel: alleen als de tabel bestaat
DO $$
BEGIN
    -- hue_config
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'hue_config') THEN
        DROP POLICY IF EXISTS "Users view own config" ON hue_config;
        EXECUTE 'CREATE POLICY "Users view own config" ON hue_config
            FOR SELECT TO authenticated
            USING (id IN (SELECT get_accessible_config_ids()))';
        -- Zorg dat RLS aan staat
        ALTER TABLE hue_config ENABLE ROW LEVEL SECURITY;
        RAISE NOTICE 'RLS policy voor hue_config bijgewerkt';
    END IF;

    -- hue_devices
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'hue_devices') THEN
        DROP POLICY IF EXISTS "Users view own devices" ON hue_devices;
        EXECUTE 'CREATE POLICY "Users view own devices" ON hue_devices
            FOR SELECT TO authenticated
            USING (config_id IN (SELECT get_accessible_config_ids()))';
        ALTER TABLE hue_devices ENABLE ROW LEVEL SECURITY;
        RAISE NOTICE 'RLS policy voor hue_devices bijgewerkt';
    END IF;

    -- raw_events
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'raw_events') THEN
        DROP POLICY IF EXISTS "Users view own raw_events" ON raw_events;
        EXECUTE 'CREATE POLICY "Users view own raw_events" ON raw_events
            FOR SELECT TO authenticated
            USING (device_id IN (
                SELECT d.id FROM hue_devices d
                WHERE d.config_id IN (SELECT get_accessible_config_ids())
            ))';
        ALTER TABLE raw_events ENABLE ROW LEVEL SECURITY;
        RAISE NOTICE 'RLS policy voor raw_events bijgewerkt';
    ELSE
        RAISE NOTICE 'raw_events tabel niet gevonden, RLS overgeslagen';
    END IF;

    -- activity_events
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'activity_events') THEN
        DROP POLICY IF EXISTS "Users view own activity_events" ON activity_events;
        EXECUTE 'CREATE POLICY "Users view own activity_events" ON activity_events
            FOR SELECT TO authenticated
            USING (config_id IN (SELECT get_accessible_config_ids()))';
        ALTER TABLE activity_events ENABLE ROW LEVEL SECURITY;
        RAISE NOTICE 'RLS policy voor activity_events bijgewerkt';
    ELSE
        RAISE NOTICE 'activity_events tabel niet gevonden, RLS overgeslagen';
    END IF;

    -- room_activity_hourly is een VIEW, geen tabel — RLS niet mogelijk
    -- Filtering gebeurt via get_accessible_config_ids() in de view-definitie (STAP 7)

    -- sensor_health_history
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'sensor_health_history') THEN
        DROP POLICY IF EXISTS "Users view own sensor health" ON sensor_health_history;
        EXECUTE 'CREATE POLICY "Users view own sensor health" ON sensor_health_history
            FOR SELECT TO authenticated
            USING (config_id IN (SELECT get_accessible_config_ids()))';
        ALTER TABLE sensor_health_history ENABLE ROW LEVEL SECURITY;
        RAISE NOTICE 'RLS policy voor sensor_health_history bijgewerkt';
    ELSE
        RAISE NOTICE 'sensor_health_history tabel niet gevonden, RLS overgeslagen';
    END IF;

    -- physical_devices
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'physical_devices') THEN
        DROP POLICY IF EXISTS "Users view own physical_devices" ON physical_devices;
        EXECUTE 'CREATE POLICY "Users view own physical_devices" ON physical_devices
            FOR SELECT TO authenticated
            USING (config_id IN (SELECT get_accessible_config_ids()))';
        ALTER TABLE physical_devices ENABLE ROW LEVEL SECURITY;
        RAISE NOTICE 'RLS policy voor physical_devices bijgewerkt';
    ELSE
        RAISE NOTICE 'physical_devices tabel niet gevonden, RLS overgeslagen';
    END IF;

    -- daily_activity_stats
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'daily_activity_stats') THEN
        DROP POLICY IF EXISTS "Users view own daily_activity_stats" ON daily_activity_stats;
        EXECUTE 'CREATE POLICY "Users view own daily_activity_stats" ON daily_activity_stats
            FOR SELECT TO authenticated
            USING (config_id IN (SELECT get_accessible_config_ids()))';
        ALTER TABLE daily_activity_stats ENABLE ROW LEVEL SECURITY;
        RAISE NOTICE 'RLS policy voor daily_activity_stats bijgewerkt';
    ELSE
        RAISE NOTICE 'daily_activity_stats tabel niet gevonden, RLS overgeslagen';
    END IF;

    -- room_activity
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'room_activity') THEN
        DROP POLICY IF EXISTS "Users view own room activity" ON room_activity;
        EXECUTE 'CREATE POLICY "Users view own room activity" ON room_activity
            FOR SELECT TO authenticated
            USING (config_id IN (SELECT get_accessible_config_ids()))';
        ALTER TABLE room_activity ENABLE ROW LEVEL SECURITY;
        RAISE NOTICE 'RLS policy voor room_activity bijgewerkt';
    ELSE
        RAISE NOTICE 'room_activity tabel niet gevonden, RLS overgeslagen';
    END IF;
END $$;

-- ============================================================
-- STAP 7: Update views met get_accessible_config_ids()
-- Gebruikt correcte tabellen: activity_events, room_activity (NIET raw_events)
-- ============================================================

DO $$
BEGIN
    -- room_activity_daily view (gebaseerd op room_activity tabel)
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

        -- room_activity_hourly view: DROP eerst (kolommen wijzigen vereist dit)
        EXECUTE 'DROP VIEW IF EXISTS room_activity_hourly';
        EXECUTE '
        CREATE VIEW room_activity_hourly AS
        SELECT
            ra.config_id,
            ra.room_name,
            date_trunc(''hour'', ra.activity_window) AS hour,
            COUNT(*) AS event_count,
            MAX(ra.last_trigger_at) AS last_event
        FROM room_activity ra
        WHERE ra.config_id IN (SELECT get_accessible_config_ids())
        GROUP BY ra.config_id, ra.room_name, date_trunc(''hour'', ra.activity_window)
        ORDER BY hour DESC, ra.room_name';

        RAISE NOTICE 'Views room_activity_daily en room_activity_hourly aangemaakt';
    ELSE
        RAISE NOTICE 'room_activity tabel niet gevonden, views overgeslagen';
    END IF;

    -- recent_activity_by_room view (gebaseerd op activity_events tabel)
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
    ELSE
        RAISE NOTICE 'activity_events tabel niet gevonden, recent_activity_by_room overgeslagen';
    END IF;

    -- room_summary view (gebruikt alleen hue_devices)
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

        -- sensor_health_overview view
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

    -- sensor_battery_trend view (gebruikt sensor_health_history)
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
    ELSE
        RAISE NOTICE 'sensor_health_history tabel niet gevonden, sensor_battery_trend view overgeslagen';
    END IF;
END $$;

-- ============================================================
-- STAP 8: Data migratie
-- Maak huishoudens aan voor bestaande hue_configs
-- ============================================================

-- Maak een household per bestaande hue_config
INSERT INTO households (name, config_id)
SELECT
    COALESCE(c.user_email, 'Huishouden') AS name,
    c.id
FROM hue_config c
WHERE NOT EXISTS (
    SELECT 1 FROM households h WHERE h.config_id = c.id
)
ON CONFLICT (config_id) DO NOTHING;

-- Voeg config-eigenaren toe als admin van hun huishouden
INSERT INTO household_members (household_id, user_id, role)
SELECT
    h.id,
    u.id,
    'admin'
FROM hue_config c
JOIN households h ON h.config_id = c.id
JOIN auth.users u ON u.email = c.user_email
WHERE NOT EXISTS (
    SELECT 1 FROM household_members hm
    WHERE hm.household_id = h.id AND hm.user_id = u.id
)
ON CONFLICT (household_id, user_id) DO NOTHING;

-- Zorg dat ALLE bestaande users een user_profiles record hebben
INSERT INTO user_profiles (id)
SELECT id FROM auth.users
ON CONFLICT (id) DO NOTHING;

-- Maak alle bestaande users admin van hun huishouden
-- Users die nog geen lid zijn (bijv. geen hue_config bezitten) krijgen een eigen huishouden
DO $$
DECLARE
    r RECORD;
    new_household_id UUID;
BEGIN
    FOR r IN
        SELECT u.id AS user_id, u.email,
               u.raw_user_meta_data->>'full_name' AS full_name
        FROM auth.users u
        WHERE NOT EXISTS (
            SELECT 1 FROM household_members hm WHERE hm.user_id = u.id
        )
    LOOP
        -- Maak een persoonlijk huishouden aan
        INSERT INTO households (name, config_id)
        VALUES (COALESCE(r.full_name, r.email, 'Huishouden'), NULL)
        RETURNING id INTO new_household_id;

        -- Voeg user toe als admin
        INSERT INTO household_members (household_id, user_id, role)
        VALUES (new_household_id, r.user_id, 'admin')
        ON CONFLICT (household_id, user_id) DO NOTHING;
    END LOOP;
END $$;

-- Zet superadmin voor dirk@boostix.nl
UPDATE user_profiles
SET is_superadmin = true
WHERE id IN (
    SELECT id FROM auth.users WHERE email = 'dirk@boostix.nl'
);

-- Zet active_household_id voor alle users die er nog geen hebben
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
-- STAP 8b: Trigger voor automatisch huishouden bij nieuwe users
-- ============================================================

CREATE OR REPLACE FUNCTION create_household_on_signup()
RETURNS TRIGGER AS $$
DECLARE
    new_household_id UUID;
    user_email TEXT;
BEGIN
    -- Haal email op van de nieuwe user
    SELECT email INTO user_email FROM auth.users WHERE id = NEW.id;

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
-- STAP 9: Functie voor uitnodiging accepteren
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

    -- Haal uitnodiging op
    SELECT * INTO v_invitation
    FROM household_invitations
    WHERE token = p_token
      AND accepted_at IS NULL
      AND expires_at > NOW();

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Uitnodiging niet gevonden of verlopen');
    END IF;

    -- Check of email overeenkomt
    IF v_invitation.invited_email != v_user_email THEN
        RETURN json_build_object('success', false, 'error', 'Deze uitnodiging is voor een ander e-mailadres');
    END IF;

    -- Voeg toe als lid
    INSERT INTO household_members (household_id, user_id, role)
    VALUES (v_invitation.household_id, v_user_id, v_invitation.role)
    ON CONFLICT (household_id, user_id) DO UPDATE SET role = v_invitation.role;

    -- Markeer als geaccepteerd
    UPDATE household_invitations
    SET accepted_at = NOW()
    WHERE id = v_invitation.id;

    RETURN json_build_object('success', true, 'household_id', v_invitation.household_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- COMMENTAAR
-- ============================================================

COMMENT ON TABLE households IS 'Huishoudens - gekoppeld aan een Hue Bridge config';
COMMENT ON TABLE household_members IS 'Leden van een huishouden met admin/viewer rol';
COMMENT ON TABLE household_invitations IS 'Uitnodigingen voor nieuwe huishoudenleden';
COMMENT ON FUNCTION get_accessible_config_ids IS 'Retourneert config_ids waar de huidige user toegang toe heeft';
COMMENT ON FUNCTION accept_household_invitation IS 'Accepteer een uitnodiging en word lid van het huishouden';
