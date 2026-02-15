-- ============================================================
-- GerustThuis - Migratie 024: Fix RLS Recursie & 500 Errors
--
-- PROBLEEM:
--   De RLS policy op household_members verwijst naar zichzelf:
--     USING (household_id IN (SELECT household_id FROM household_members ...))
--   Dit veroorzaakt oneindige recursie in PostgreSQL → HTTP 500 errors.
--
--   Alle queries die (direct of indirect) household_members raadplegen
--   falen: households, activity_events, daily_activity_stats,
--   room_activity_hourly, en household_invitations.
--
-- OPLOSSING:
--   1. SECURITY DEFINER helper-functies die RLS bypassen
--   2. Alle self-referencing policies vervangen
--   3. Migratie 021 STAP 5b fix (room_activity bestaat niet)
--   4. Constraint naming fix (valid_role → household_members_role_check)
--
-- VEILIG OM MEERDERE KEREN UIT TE VOEREN (idempotent)
-- Datum: 2026-02-15
-- ============================================================


-- ============================================================
-- STAP 1: SECURITY DEFINER helper-functies
-- Deze functies draaien als de eigenaar (postgres), waardoor RLS
-- op household_members wordt omzeild. Geen recursie meer.
-- ============================================================

CREATE OR REPLACE FUNCTION get_my_household_ids()
RETURNS SETOF UUID AS $$
BEGIN
    RETURN QUERY
    SELECT hm.household_id
    FROM household_members hm
    WHERE hm.user_id = auth.uid();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION get_my_admin_household_ids()
RETURNS SETOF UUID AS $$
BEGIN
    RETURN QUERY
    SELECT hm.household_id
    FROM household_members hm
    WHERE hm.user_id = auth.uid()
      AND hm.role IN ('admin');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;


-- ============================================================
-- STAP 2: Fix household_members RLS
-- Vervang self-referencing policies door helper-functies
-- ============================================================

DROP POLICY IF EXISTS "Users view household members" ON household_members;
CREATE POLICY "Users view household members" ON household_members
    FOR SELECT TO authenticated
    USING (
        household_id IN (SELECT get_my_household_ids())
    );

DROP POLICY IF EXISTS "Admins manage household members" ON household_members;
CREATE POLICY "Admins manage household members" ON household_members
    FOR ALL TO authenticated
    USING (
        household_id IN (SELECT get_my_admin_household_ids())
    )
    WITH CHECK (
        household_id IN (SELECT get_my_admin_household_ids())
    );


-- ============================================================
-- STAP 3: Fix households RLS
-- Gebruikt nu helper-functie i.p.v. directe household_members query
-- ============================================================

DROP POLICY IF EXISTS "Users view own households" ON households;
CREATE POLICY "Users view own households" ON households
    FOR SELECT TO authenticated
    USING (
        id IN (SELECT get_my_household_ids())
    );


-- ============================================================
-- STAP 4: Fix household_invitations RLS
-- ============================================================

DROP POLICY IF EXISTS "Users view invitations" ON household_invitations;
DROP POLICY IF EXISTS "Users view own invitations" ON household_invitations;
CREATE POLICY "Users view invitations" ON household_invitations
    FOR SELECT TO authenticated
    USING (
        invited_email = auth.jwt() ->> 'email'
        OR household_id IN (SELECT get_my_admin_household_ids())
    );

DROP POLICY IF EXISTS "Admins create invitations" ON household_invitations;
DROP POLICY IF EXISTS "Admins manage invitations" ON household_invitations;
CREATE POLICY "Admins create invitations" ON household_invitations
    FOR INSERT TO authenticated
    WITH CHECK (
        household_id IN (SELECT get_my_admin_household_ids())
    );

DROP POLICY IF EXISTS "Users can accept invitations" ON household_invitations;
CREATE POLICY "Users can accept invitations" ON household_invitations
    FOR UPDATE TO authenticated
    USING (invited_email = auth.jwt() ->> 'email')
    WITH CHECK (invited_email = auth.jwt() ->> 'email');


-- ============================================================
-- STAP 5: Fix data-tabel RLS policies
-- Installer-check uit migratie 021 opnieuw toepassen, nu correct.
-- De EXISTS subquery leest household_members, maar dankzij de
-- helper-functies in STAP 2 is er geen recursie meer.
-- ============================================================

-- 5a. activity_events
DROP POLICY IF EXISTS "Users view own activity_events" ON activity_events;
CREATE POLICY "Users view own activity_events" ON activity_events
    FOR SELECT TO authenticated
    USING (
        config_id IN (SELECT get_accessible_config_ids())
        AND EXISTS (
            SELECT 1 FROM household_members hm
            JOIN households h ON hm.household_id = h.id
            WHERE hm.user_id = auth.uid()
              AND h.config_id = activity_events.config_id
              AND hm.role IN ('admin', 'viewer')
        )
    );

-- 5b. room_activity_hourly
DROP POLICY IF EXISTS "Users view own room_activity_hourly" ON room_activity_hourly;
CREATE POLICY "Users view own room_activity_hourly" ON room_activity_hourly
    FOR SELECT TO authenticated
    USING (
        config_id IN (SELECT get_accessible_config_ids())
        AND EXISTS (
            SELECT 1 FROM household_members hm
            JOIN households h ON hm.household_id = h.id
            WHERE hm.user_id = auth.uid()
              AND h.config_id = room_activity_hourly.config_id
              AND hm.role IN ('admin', 'viewer')
        )
    );

-- 5c. daily_activity_stats
DROP POLICY IF EXISTS "Users view own daily_activity_stats" ON daily_activity_stats;
DROP POLICY IF EXISTS "Users view own daily stats" ON daily_activity_stats;
CREATE POLICY "Users view own daily_activity_stats" ON daily_activity_stats
    FOR SELECT TO authenticated
    USING (
        config_id IN (SELECT get_accessible_config_ids())
        AND EXISTS (
            SELECT 1 FROM household_members hm
            JOIN households h ON hm.household_id = h.id
            WHERE hm.user_id = auth.uid()
              AND h.config_id = daily_activity_stats.config_id
              AND hm.role IN ('admin', 'viewer')
        )
    );

-- 5d. room_activity (alleen als de tabel bestaat)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'room_activity') THEN
        DROP POLICY IF EXISTS "Users view own room activity" ON room_activity;
        EXECUTE 'CREATE POLICY "Users view own room activity" ON room_activity
            FOR SELECT TO authenticated
            USING (
                config_id IN (SELECT get_accessible_config_ids())
                AND EXISTS (
                    SELECT 1 FROM household_members hm
                    JOIN households h ON hm.household_id = h.id
                    WHERE hm.user_id = auth.uid()
                      AND h.config_id = room_activity.config_id
                      AND hm.role IN (''admin'', ''viewer'')
                )
            )';
    END IF;
END $$;


-- ============================================================
-- STAP 6: Fix residents RLS (uit migratie 021, nu met helper-functies)
-- ============================================================

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'residents') THEN
        DROP POLICY IF EXISTS "Members view residents" ON residents;
        EXECUTE 'CREATE POLICY "Members view residents" ON residents
            FOR SELECT TO authenticated
            USING (
                household_id IN (SELECT get_my_household_ids())
            )';

        DROP POLICY IF EXISTS "Admins manage residents" ON residents;
        EXECUTE 'CREATE POLICY "Admins manage residents" ON residents
            FOR ALL TO authenticated
            USING (
                household_id IN (SELECT get_my_admin_household_ids())
            )
            WITH CHECK (
                household_id IN (SELECT get_my_admin_household_ids())
            )';
    END IF;
END $$;


-- ============================================================
-- STAP 7: Fix constraint naming
-- Migratie 021 voegt household_members_role_check toe maar dropt
-- niet de originele valid_role constraint uit migratie 010.
-- ============================================================

ALTER TABLE household_members
    DROP CONSTRAINT IF EXISTS valid_role;

ALTER TABLE household_members
    DROP CONSTRAINT IF EXISTS household_members_role_check;

ALTER TABLE household_members
    ADD CONSTRAINT household_members_role_check
        CHECK (role IN ('admin', 'viewer', 'installer'));

ALTER TABLE household_invitations
    DROP CONSTRAINT IF EXISTS valid_invitation_role;

ALTER TABLE household_invitations
    DROP CONSTRAINT IF EXISTS household_invitations_role_check;

ALTER TABLE household_invitations
    ADD CONSTRAINT household_invitations_role_check
        CHECK (role IN ('admin', 'viewer', 'installer'));


-- ============================================================
-- STAP 8: Verificatie
-- ============================================================

DO $$
DECLARE
    v_policy RECORD;
    v_recursion_found BOOLEAN := false;
BEGIN
    -- Check dat geen enkele policy op household_members naar zichzelf verwijst
    FOR v_policy IN
        SELECT policyname, qual
        FROM pg_policies
        WHERE tablename = 'household_members'
          AND schemaname = 'public'
    LOOP
        IF v_policy.qual LIKE '%household_members%' AND v_policy.qual NOT LIKE '%get_my_%' THEN
            v_recursion_found := true;
            RAISE WARNING 'Self-referencing policy gevonden: %', v_policy.policyname;
        END IF;
    END LOOP;

    IF NOT v_recursion_found THEN
        RAISE NOTICE '✓ Geen self-referencing policies op household_members';
    END IF;

    -- Check helper functies
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'get_my_household_ids') THEN
        RAISE NOTICE '✓ Functie get_my_household_ids() bestaat';
    ELSE
        RAISE WARNING '✗ Functie get_my_household_ids() ONTBREEKT!';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'get_my_admin_household_ids') THEN
        RAISE NOTICE '✓ Functie get_my_admin_household_ids() bestaat';
    ELSE
        RAISE WARNING '✗ Functie get_my_admin_household_ids() ONTBREEKT!';
    END IF;

    -- Check constraints
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'household_members_role_check'
          AND conrelid = 'household_members'::regclass
    ) THEN
        RAISE NOTICE '✓ Constraint household_members_role_check aanwezig';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'valid_role'
          AND conrelid = 'household_members'::regclass
    ) THEN
        RAISE NOTICE '✓ Oude constraint valid_role verwijderd';
    ELSE
        RAISE WARNING '✗ Oude constraint valid_role bestaat nog!';
    END IF;

    RAISE NOTICE '';
    RAISE NOTICE 'Migratie 024 voltooid — RLS recursie opgelost';
END $$;
