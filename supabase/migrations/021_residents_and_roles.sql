-- ============================================================
-- GerustThuis - Migratie 021: Residents & Installer Rol
--
-- Voegt toe:
--   1. residents tabel (bewonersprofielen per huishouden)
--   2. installer rol op household_members en household_invitations
--   3. RLS policies voor residents
--   4. RLS aanpassing: installer kan GEEN activiteitsdata zien
--   5. Supabase Storage bucket voor bewoner-foto's
--   6. updated_at trigger op residents
--
-- Datum: 2026-02-15
-- ============================================================


-- ============================================================
-- STAP 1: residents tabel
-- ============================================================

CREATE TABLE IF NOT EXISTS residents (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    household_id    UUID NOT NULL REFERENCES households(id) ON DELETE CASCADE,
    first_name      VARCHAR(100) NOT NULL,
    relationship    VARCHAR(50) NOT NULL
        CHECK (relationship IN ('mama', 'papa', 'opa', 'oma', 'partner', 'broer', 'zus', 'vriend', 'buurman', 'anders')),
    photo_path      TEXT,                  -- pad in Supabase Storage bucket 'resident-photos'
    date_of_birth   DATE,                  -- optioneel, voor leeftijdscontext
    notes           TEXT,                  -- optioneel, vrije notities
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_residents_household ON residents(household_id);

-- updated_at trigger
DROP TRIGGER IF EXISTS trigger_residents_updated_at ON residents;
CREATE TRIGGER trigger_residents_updated_at
    BEFORE UPDATE ON residents
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();


-- ============================================================
-- STAP 2: household_members.role uitbreiden met 'installer'
-- ============================================================

ALTER TABLE household_members
    DROP CONSTRAINT IF EXISTS household_members_role_check,
    ADD CONSTRAINT household_members_role_check
        CHECK (role IN ('admin', 'viewer', 'installer'));


-- ============================================================
-- STAP 3: household_invitations.role uitbreiden met 'installer'
-- ============================================================

ALTER TABLE household_invitations
    DROP CONSTRAINT IF EXISTS household_invitations_role_check,
    ADD CONSTRAINT household_invitations_role_check
        CHECK (role IN ('admin', 'viewer', 'installer'));


-- ============================================================
-- STAP 4: RLS policies voor residents
-- ============================================================

ALTER TABLE residents ENABLE ROW LEVEL SECURITY;

-- Alle leden van het huishouden kunnen bewoners zien
-- (incl. installer — het is iemand uit de kring, ze kennen de bewoner)
DROP POLICY IF EXISTS "Members view residents" ON residents;
CREATE POLICY "Members view residents" ON residents
    FOR SELECT TO authenticated
    USING (
        household_id IN (
            SELECT household_id FROM household_members
            WHERE user_id = auth.uid()
        )
    );

-- Alleen admins kunnen bewoners aanmaken/bewerken/verwijderen
DROP POLICY IF EXISTS "Admins manage residents" ON residents;
CREATE POLICY "Admins manage residents" ON residents
    FOR ALL TO authenticated
    USING (
        household_id IN (
            SELECT household_id FROM household_members
            WHERE user_id = auth.uid() AND role = 'admin'
        )
    )
    WITH CHECK (
        household_id IN (
            SELECT household_id FROM household_members
            WHERE user_id = auth.uid() AND role = 'admin'
        )
    );

-- Service role full access (nodig voor backend/edge functions)
DROP POLICY IF EXISTS "Service role full access residents" ON residents;
CREATE POLICY "Service role full access residents" ON residents
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);


-- ============================================================
-- STAP 5: RLS aanpassing — installer kan GEEN activiteitsdata zien
--
-- De huidige policies gebruiken get_accessible_config_ids() zonder
-- rol-check. We voegen een extra EXISTS check toe die de installer
-- rol uitsluit van privacygevoelige tabellen.
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

-- 5b. room_activity
DROP POLICY IF EXISTS "Users view own room activity" ON room_activity;
CREATE POLICY "Users view own room activity" ON room_activity
    FOR SELECT TO authenticated
    USING (
        config_id IN (SELECT get_accessible_config_ids())
        AND EXISTS (
            SELECT 1 FROM household_members hm
            JOIN households h ON hm.household_id = h.id
            WHERE hm.user_id = auth.uid()
              AND h.config_id = room_activity.config_id
              AND hm.role IN ('admin', 'viewer')
        )
    );

-- 5c. room_activity_hourly
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

-- 5d. daily_activity_stats
DROP POLICY IF EXISTS "Users view own daily_activity_stats" ON daily_activity_stats;
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


-- ============================================================
-- STAP 6: Supabase Storage bucket voor bewoner-foto's
-- ============================================================
-- NB: Storage buckets worden aangemaakt via de Supabase Dashboard
-- of via de storage API. Dit is ter documentatie:
--
-- Bucket: resident-photos
--   - Public: false (private, signed URLs)
--   - Pad conventie: {household_id}/{resident_id}.jpg
--   - Max bestandsgrootte: 2MB
--   - Toegestane types: image/jpeg, image/png, image/webp
--
-- Storage policies worden apart geconfigureerd via Dashboard.


-- ============================================================
-- Klaar! Verificatie queries:
-- ============================================================
-- 1. SELECT * FROM residents;  (tabel moet bestaan, leeg)
-- 2. SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--    WHERE conname LIKE '%role%';
-- 3. SELECT policyname, tablename FROM pg_policies
--    WHERE schemaname = 'public' AND tablename = 'residents';
-- 4. SELECT policyname, tablename FROM pg_policies
--    WHERE schemaname = 'public' AND tablename IN
--    ('activity_events','room_activity','room_activity_hourly','daily_activity_stats');
