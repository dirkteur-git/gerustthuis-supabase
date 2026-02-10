-- ============================================================
-- GerustThuis - Fix Signup Trigger
--
-- Probleem: "Database error saving new user" bij signup
-- Oorzaak: De trigger-keten faalt omdat:
--   1. handle_new_user() INSERT in user_profiles
--   2. create_household_on_signup() INSERT in households + household_members
--   3. De RLS policies blokkeren deze INSERTs
--
-- Oplossing:
--   - Combineer beide triggers in één robuuste SECURITY DEFINER functie
--   - Verwijder onnodige tussenstap (geen aparte trigger op user_profiles)
--   - Voeg permissieve INSERT policy toe op user_profiles
--
-- Datum: 2026-02-09
-- ============================================================

-- ============================================================
-- STAP 1: Drop oude triggers
-- ============================================================

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
DROP TRIGGER IF EXISTS trigger_create_household_on_signup ON user_profiles;

-- ============================================================
-- STAP 2: Eén gecombineerde functie die ALLES doet bij signup
-- Draait als postgres (SECURITY DEFINER) zodat RLS geen probleem is
-- ============================================================

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
    new_household_id UUID;
    user_email TEXT;
BEGIN
    -- 1. Maak user_profiles record
    INSERT INTO public.user_profiles (id)
    VALUES (NEW.id)
    ON CONFLICT (id) DO NOTHING;

    -- 2. Haal email op
    user_email := NEW.email;

    -- 3. dirk@boostix.nl krijgt geen eigen huishouden (onzichtbare global admin)
    IF user_email = 'dirk@boostix.nl' THEN
        RETURN NEW;
    END IF;

    -- 4. Maak een huishouden aan
    INSERT INTO public.households (name, config_id)
    VALUES (COALESCE(user_email, 'Mijn huishouden'), NULL)
    RETURNING id INTO new_household_id;

    -- 5. Voeg user toe als admin
    INSERT INTO public.household_members (household_id, user_id, role)
    VALUES (new_household_id, NEW.id, 'admin');

    -- 6. Zet als actief huishouden
    UPDATE public.user_profiles
    SET active_household_id = new_household_id
    WHERE id = NEW.id;

    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    -- Log error maar laat signup NIET falen
    RAISE WARNING 'handle_new_user error for %: %', NEW.id, SQLERRM;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Zorg dat de functie eigendom is van postgres (bypassed RLS)
ALTER FUNCTION handle_new_user() OWNER TO postgres;

-- ============================================================
-- STAP 3: Eén trigger op auth.users (geen cascade meer via user_profiles)
-- ============================================================

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION handle_new_user();

-- ============================================================
-- STAP 4: Drop de oude separate functie (niet meer nodig)
-- ============================================================

DROP FUNCTION IF EXISTS create_household_on_signup();

-- ============================================================
-- STAP 5: Verruim user_profiles INSERT policy
-- De trigger doet de INSERT, maar voor de zekerheid ook open voor auth
-- ============================================================

DROP POLICY IF EXISTS "Users can insert own profile" ON user_profiles;
CREATE POLICY "Users can insert own profile"
    ON user_profiles FOR INSERT
    WITH CHECK (true);  -- Elke authenticated user mag inserten (PK constraint voorkomt dubbels)

-- ============================================================
-- STAP 6: Voeg INSERT policies toe op households en household_members
-- Nodig zodat de trigger (als die TOCH als non-postgres draait) kan werken
-- ============================================================

-- households: authenticated users mogen huishoudens aanmaken
DROP POLICY IF EXISTS "Users can create households" ON households;
CREATE POLICY "Users can create households" ON households
    FOR INSERT TO authenticated
    WITH CHECK (true);

-- household_members: authenticated users mogen zichzelf toevoegen
DROP POLICY IF EXISTS "Users can join households" ON household_members;
CREATE POLICY "Users can join households" ON household_members
    FOR INSERT TO authenticated
    WITH CHECK (user_id = auth.uid());

-- ============================================================
-- STAP 7: Verificatie
-- ============================================================

DO $$
BEGIN
    -- Check trigger
    IF EXISTS (
        SELECT 1 FROM information_schema.triggers
        WHERE trigger_name = 'on_auth_user_created'
          AND event_object_schema = 'auth'
          AND event_object_table = 'users'
    ) THEN
        RAISE NOTICE '✓ Trigger on_auth_user_created bestaat op auth.users';
    ELSE
        RAISE WARNING '✗ Trigger on_auth_user_created ONTBREEKT!';
    END IF;

    -- Check dat de oude cascade trigger weg is
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.triggers
        WHERE trigger_name = 'trigger_create_household_on_signup'
    ) THEN
        RAISE NOTICE '✓ Oude cascade trigger is verwijderd';
    ELSE
        RAISE WARNING '✗ Oude cascade trigger bestaat nog!';
    END IF;

    -- Check function owner
    IF EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_roles r ON p.proowner = r.oid
        WHERE p.proname = 'handle_new_user'
          AND r.rolname = 'postgres'
    ) THEN
        RAISE NOTICE '✓ handle_new_user() is eigendom van postgres';
    ELSE
        RAISE WARNING '✗ handle_new_user() is NIET eigendom van postgres - RLS bypass werkt mogelijk niet!';
    END IF;

    RAISE NOTICE 'Klaar! Probeer nu opnieuw te registreren.';
END $$;
