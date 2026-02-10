-- ============================================================
-- GerustThuis - Superadmin RLS op user_profiles
--
-- dirk@boostix.nl krijgt SELECT + UPDATE toegang tot ALLE user_profiles
-- Zodat superadmin alle gebruikers kan zien en beheren
--
-- Datum: 2026-02-09
-- ============================================================

-- Superadmin kan alle profielen zien
DROP POLICY IF EXISTS "Superadmin can view all profiles" ON user_profiles;
CREATE POLICY "Superadmin can view all profiles"
    ON user_profiles FOR SELECT TO authenticated
    USING (auth.jwt() ->> 'email' = 'dirk@boostix.nl');

-- Superadmin kan alle profielen updaten
DROP POLICY IF EXISTS "Superadmin can update all profiles" ON user_profiles;
CREATE POLICY "Superadmin can update all profiles"
    ON user_profiles FOR UPDATE TO authenticated
    USING (auth.jwt() ->> 'email' = 'dirk@boostix.nl');

-- Verificatie
DO $$
BEGIN
    RAISE NOTICE '✓ Superadmin SELECT policy op user_profiles aangemaakt';
    RAISE NOTICE '✓ Superadmin UPDATE policy op user_profiles aangemaakt';
    RAISE NOTICE 'dirk@boostix.nl kan nu alle gebruikersprofielen zien en bewerken';
END $$;
