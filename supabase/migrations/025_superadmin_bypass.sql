-- ============================================================
-- GerustThuis - Migratie 025: Superadmin bypass voor Admin Portaal
--
-- DOEL:
--   Het admin portaal (gerustthuis-admin_portal) heeft toegang nodig
--   tot ALLE huishoudens, leden en profielen. Reguliere RLS beperkt
--   dit tot de eigen huishoudens van de ingelogde gebruiker.
--
-- AANPAK:
--   1. Voeg is_superadmin kolom terug toe aan user_profiles
--   2. Maak is_superadmin() SECURITY DEFINER helper (geen RLS recursie)
--   3. Breid SELECT policies uit met OR is_superadmin()
--   4. Stel dirk.bakker@gmx.net in als superadmin
--
-- VEILIGHEID:
--   - is_superadmin() is SECURITY DEFINER → leest user_profiles
--     zonder RLS, dus geen recursie
--   - Alleen SELECT policies worden uitgebreid (readonly)
--   - Bestaande policies voor reguliere gebruikers blijven ongewijzigd
--
-- VEILIG OM MEERDERE KEREN UIT TE VOEREN (idempotent)
-- Datum: 2026-02-15
-- ============================================================


-- ============================================================
-- STAP 1: Voeg is_superadmin kolom toe aan user_profiles
-- ============================================================

ALTER TABLE user_profiles
    ADD COLUMN IF NOT EXISTS is_superadmin BOOLEAN DEFAULT false;


-- ============================================================
-- STAP 2: SECURITY DEFINER helper functie
-- Leest user_profiles direct (omzeilt RLS) → geen recursie
-- ============================================================

CREATE OR REPLACE FUNCTION is_superadmin()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM user_profiles
        WHERE id = auth.uid()
          AND is_superadmin = true
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;


-- ============================================================
-- STAP 3: Breid RLS SELECT policies uit
-- Reguliere gebruikers: ongewijzigd
-- Superadmins: mogen alles zien (alleen SELECT)
-- ============================================================

-- 3a. households
DROP POLICY IF EXISTS "Users view own households" ON households;
CREATE POLICY "Users view own households" ON households
    FOR SELECT TO authenticated
    USING (
        id IN (SELECT get_my_household_ids())
        OR is_superadmin()
    );

-- 3b. household_members (SELECT)
DROP POLICY IF EXISTS "Users view household members" ON household_members;
CREATE POLICY "Users view household members" ON household_members
    FOR SELECT TO authenticated
    USING (
        household_id IN (SELECT get_my_household_ids())
        OR is_superadmin()
    );

-- 3c. household_invitations (SELECT)
DROP POLICY IF EXISTS "Users view invitations" ON household_invitations;
CREATE POLICY "Users view invitations" ON household_invitations
    FOR SELECT TO authenticated
    USING (
        invited_email = auth.jwt() ->> 'email'
        OR household_id IN (SELECT get_my_admin_household_ids())
        OR is_superadmin()
    );

-- 3d. user_profiles (SELECT) — superadmin kan alle profielen zien
DROP POLICY IF EXISTS "Superadmin view all profiles" ON user_profiles;
CREATE POLICY "Superadmin view all profiles" ON user_profiles
    FOR SELECT TO authenticated
    USING (is_superadmin());

-- 3e. hue_config (SELECT) — superadmin kan alle configs zien
DROP POLICY IF EXISTS "Superadmin view all configs" ON hue_config;
CREATE POLICY "Superadmin view all configs" ON hue_config
    FOR SELECT TO authenticated
    USING (is_superadmin());


-- ============================================================
-- STAP 3f: get_accessible_config_ids() — superadmin bypass
-- Data-tabellen (activity_events, room_activity_hourly,
-- daily_activity_stats) gebruiken deze functie in hun RLS.
-- Door hier superadmin-check toe te voegen werkt het overal.
-- ============================================================

CREATE OR REPLACE FUNCTION get_accessible_config_ids()
RETURNS SETOF UUID AS $$
DECLARE
    v_user_id UUID;
    v_user_email TEXT;
BEGIN
    v_user_id := auth.uid();
    v_user_email := auth.jwt() ->> 'email';

    -- Superadmin: alle configs
    IF EXISTS (
        SELECT 1 FROM user_profiles
        WHERE id = v_user_id AND is_superadmin = true
    ) THEN
        RETURN QUERY SELECT id FROM hue_config;
        RETURN;
    END IF;

    -- Reguliere user: via household_members
    RETURN QUERY
    SELECT DISTINCT h.config_id
    FROM household_members hm
    JOIN households h ON hm.household_id = h.id
    WHERE hm.user_id = v_user_id AND h.config_id IS NOT NULL;

    -- Fallback: directe email match (backward compat)
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
-- STAP 3g: Data-tabel RLS policies — superadmin bypass
-- De policies uit migratie 024 hebben een dubbele check:
--   config_id IN get_accessible_config_ids() AND EXISTS(household_members...)
-- De EXISTS faalt voor superadmins die geen lid zijn van het huishouden.
-- Oplossing: OR is_superadmin() als eerste check.
-- ============================================================

-- room_activity_hourly
DROP POLICY IF EXISTS "Users view own room_activity_hourly" ON room_activity_hourly;
CREATE POLICY "Users view own room_activity_hourly" ON room_activity_hourly
    FOR SELECT TO authenticated
    USING (
        is_superadmin()
        OR (
            config_id IN (SELECT get_accessible_config_ids())
            AND EXISTS (
                SELECT 1 FROM household_members hm
                JOIN households h ON hm.household_id = h.id
                WHERE hm.user_id = auth.uid()
                  AND h.config_id = room_activity_hourly.config_id
                  AND hm.role IN ('admin', 'viewer')
            )
        )
    );

-- activity_events
DROP POLICY IF EXISTS "Users view own activity_events" ON activity_events;
CREATE POLICY "Users view own activity_events" ON activity_events
    FOR SELECT TO authenticated
    USING (
        is_superadmin()
        OR (
            config_id IN (SELECT get_accessible_config_ids())
            AND EXISTS (
                SELECT 1 FROM household_members hm
                JOIN households h ON hm.household_id = h.id
                WHERE hm.user_id = auth.uid()
                  AND h.config_id = activity_events.config_id
                  AND hm.role IN ('admin', 'viewer')
            )
        )
    );

-- daily_activity_stats
DROP POLICY IF EXISTS "Users view own daily_activity_stats" ON daily_activity_stats;
CREATE POLICY "Users view own daily_activity_stats" ON daily_activity_stats
    FOR SELECT TO authenticated
    USING (
        is_superadmin()
        OR (
            config_id IN (SELECT get_accessible_config_ids())
            AND EXISTS (
                SELECT 1 FROM household_members hm
                JOIN households h ON hm.household_id = h.id
                WHERE hm.user_id = auth.uid()
                  AND h.config_id = daily_activity_stats.config_id
                  AND hm.role IN ('admin', 'viewer')
            )
        )
    );


-- ============================================================
-- STAP 4: Stel dirk.bakker@gmx.net in als superadmin
-- ============================================================

DO $$
DECLARE
    v_user_id UUID;
BEGIN
    SELECT id INTO v_user_id
    FROM auth.users
    WHERE email = 'dirk.bakker@gmx.net';

    IF v_user_id IS NOT NULL THEN
        UPDATE user_profiles
        SET is_superadmin = true
        WHERE id = v_user_id;

        IF NOT FOUND THEN
            -- Profiel bestaat nog niet, maak aan
            INSERT INTO user_profiles (id, is_superadmin)
            VALUES (v_user_id, true)
            ON CONFLICT (id) DO UPDATE SET is_superadmin = true;
        END IF;

        RAISE NOTICE '✓ dirk.bakker@gmx.net ingesteld als superadmin';
    ELSE
        RAISE WARNING 'dirk.bakker@gmx.net niet gevonden in auth.users';
    END IF;
END $$;


-- ============================================================
-- STAP 5: Verificatie
-- ============================================================

DO $$
BEGIN
    -- Check kolom bestaat
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'user_profiles' AND column_name = 'is_superadmin'
    ) THEN
        RAISE NOTICE '✓ Kolom is_superadmin aanwezig op user_profiles';
    ELSE
        RAISE WARNING '✗ Kolom is_superadmin ONTBREEKT!';
    END IF;

    -- Check functie bestaat
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'is_superadmin') THEN
        RAISE NOTICE '✓ Functie is_superadmin() bestaat';
    ELSE
        RAISE WARNING '✗ Functie is_superadmin() ONTBREEKT!';
    END IF;

    -- Check superadmin policies
    IF EXISTS (
        SELECT 1 FROM pg_policies
        WHERE qual::text LIKE '%is_superadmin%'
    ) THEN
        RAISE NOTICE '✓ Superadmin bypass actief in RLS policies';
    ELSE
        RAISE WARNING '✗ Geen superadmin RLS policies gevonden';
    END IF;

    RAISE NOTICE '';
    RAISE NOTICE 'Migratie 025 voltooid — superadmin bypass voor admin portaal';
END $$;
