-- ============================================================
-- GerustThuis - Remove Superadmin (dirk@boostix.nl)
--
-- Verwijdert alle superadmin/dirk@boostix.nl hardcoded logica:
--   - get_accessible_config_ids() functie (verwijder dirk branch)
--   - RLS policies op households, household_members, household_invitations
--   - Superadmin policies op user_profiles
--   - Signup trigger (verwijder dirk skip)
--   - is_superadmin kolom van user_profiles
--   - Data fix: maak huishouden voor dirk@boostix.nl
--
-- VEILIG OM MEERDERE KEREN UIT TE VOEREN (idempotent)
-- Datum: 2026-02-10
-- ============================================================

-- ============================================================
-- STAP 1: Fix get_accessible_config_ids() — verwijder dirk branch
-- ============================================================

CREATE OR REPLACE FUNCTION get_accessible_config_ids()
RETURNS SETOF UUID AS $$
DECLARE
    v_user_id UUID;
    v_user_email TEXT;
BEGIN
    v_user_id := auth.uid();
    v_user_email := auth.jwt() ->> 'email';

    -- Via household_members
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
-- STAP 2: Fix RLS policies op households — verwijder dirk clause
-- ============================================================

DROP POLICY IF EXISTS "Users view own households" ON households;
CREATE POLICY "Users view own households" ON households
    FOR SELECT TO authenticated
    USING (
        id IN (SELECT household_id FROM household_members WHERE user_id = auth.uid())
    );

-- ============================================================
-- STAP 3: Fix RLS policies op household_members
-- ============================================================

DROP POLICY IF EXISTS "Users view household members" ON household_members;
CREATE POLICY "Users view household members" ON household_members
    FOR SELECT TO authenticated
    USING (
        household_id IN (SELECT household_id FROM household_members WHERE user_id = auth.uid())
    );

DROP POLICY IF EXISTS "Admins manage household members" ON household_members;
CREATE POLICY "Admins manage household members" ON household_members
    FOR ALL TO authenticated
    USING (
        household_id IN (SELECT household_id FROM household_members WHERE user_id = auth.uid() AND role = 'admin')
    )
    WITH CHECK (
        household_id IN (SELECT household_id FROM household_members WHERE user_id = auth.uid() AND role = 'admin')
    );

-- ============================================================
-- STAP 4: Fix RLS policies op household_invitations
-- ============================================================

DROP POLICY IF EXISTS "Users view invitations" ON household_invitations;
CREATE POLICY "Users view invitations" ON household_invitations
    FOR SELECT TO authenticated
    USING (
        invited_email = auth.jwt() ->> 'email'
        OR household_id IN (SELECT household_id FROM household_members WHERE user_id = auth.uid() AND role = 'admin')
    );

DROP POLICY IF EXISTS "Admins create invitations" ON household_invitations;
CREATE POLICY "Admins create invitations" ON household_invitations
    FOR INSERT TO authenticated
    WITH CHECK (
        household_id IN (SELECT household_id FROM household_members WHERE user_id = auth.uid() AND role = 'admin')
    );

-- ============================================================
-- STAP 5: Verwijder superadmin policies op user_profiles
-- ============================================================

DROP POLICY IF EXISTS "Superadmin can view all profiles" ON user_profiles;
DROP POLICY IF EXISTS "Superadmin can update all profiles" ON user_profiles;

-- ============================================================
-- STAP 6: Fix signup trigger — verwijder dirk skip
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

-- ============================================================
-- STAP 7: Data fix — maak huishouden voor dirk@boostix.nl als die er niet is
-- ============================================================

DO $$
DECLARE
    v_user_id UUID;
    v_household_id UUID;
BEGIN
    -- Zoek dirk@boostix.nl user
    SELECT id INTO v_user_id FROM auth.users WHERE email = 'dirk@boostix.nl';

    IF v_user_id IS NOT NULL THEN
        -- Check of dirk al een household_members record heeft
        SELECT hm.household_id INTO v_household_id
        FROM household_members hm
        WHERE hm.user_id = v_user_id
        LIMIT 1;

        IF v_household_id IS NULL THEN
            -- Maak een huishouden aan
            INSERT INTO households (name, config_id)
            VALUES ('dirk@boostix.nl', NULL)
            RETURNING id INTO v_household_id;

            -- Voeg als admin toe
            INSERT INTO household_members (household_id, user_id, role)
            VALUES (v_household_id, v_user_id, 'admin')
            ON CONFLICT (household_id, user_id) DO NOTHING;

            RAISE NOTICE 'Huishouden aangemaakt voor dirk@boostix.nl: %', v_household_id;
        ELSE
            RAISE NOTICE 'dirk@boostix.nl heeft al een huishouden: %', v_household_id;
        END IF;

        -- Zet active_household_id als die leeg is
        UPDATE user_profiles
        SET active_household_id = v_household_id
        WHERE id = v_user_id AND active_household_id IS NULL;

        -- Zorg dat user_profiles record bestaat
        INSERT INTO user_profiles (id)
        VALUES (v_user_id)
        ON CONFLICT (id) DO NOTHING;
    ELSE
        RAISE NOTICE 'dirk@boostix.nl niet gevonden in auth.users — overgeslagen';
    END IF;
END $$;

-- ============================================================
-- STAP 8: Verwijder is_superadmin kolom
-- ============================================================

ALTER TABLE user_profiles DROP COLUMN IF EXISTS is_superadmin;

-- ============================================================
-- STAP 9: Verificatie
-- ============================================================

DO $$
BEGIN
    -- Check dat dirk@boostix.nl niet meer in policies zit
    IF EXISTS (
        SELECT 1 FROM pg_policies
        WHERE policyname LIKE '%superadmin%'
          OR policyname LIKE '%Superadmin%'
    ) THEN
        RAISE WARNING 'Er zijn nog superadmin policies! Check pg_policies.';
    ELSE
        RAISE NOTICE '✓ Geen superadmin policies meer gevonden';
    END IF;

    -- Check dat dirk een huishouden heeft
    IF EXISTS (
        SELECT 1 FROM auth.users u
        JOIN household_members hm ON hm.user_id = u.id
        WHERE u.email = 'dirk@boostix.nl'
    ) THEN
        RAISE NOTICE '✓ dirk@boostix.nl is lid van een huishouden';
    END IF;

    -- Check dat is_superadmin kolom weg is
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'user_profiles' AND column_name = 'is_superadmin'
    ) THEN
        RAISE NOTICE '✓ is_superadmin kolom verwijderd';
    ELSE
        RAISE WARNING '✗ is_superadmin kolom bestaat nog!';
    END IF;

    RAISE NOTICE 'Migratie 018_remove_superadmin voltooid';
END $$;
