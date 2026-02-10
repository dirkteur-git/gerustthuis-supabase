-- ============================================================
-- GerustThuis - Koppel hue_config aan huishouden
--
-- Probleem: Bij signup wordt een household aangemaakt met config_id = NULL.
-- Wanneer de user later een Hue Bridge koppelt, wordt hue_config aangemaakt
-- maar households.config_id wordt NOOIT bijgewerkt.
-- Hierdoor retourneert get_accessible_config_ids() een lege set
-- en ziet de user geen data (RLS blokkeert alles).
--
-- Oplossing:
--   1. Eenmalige data-fix: koppel bestaande hue_configs aan households
--   2. Trigger op hue_config: automatisch koppelen bij nieuwe config
--
-- Datum: 2026-02-09
-- ============================================================

-- ============================================================
-- STAP 1: Eenmalige fix - koppel bestaande hue_configs aan households
-- Via: hue_config.user_email → auth.users.email → household_members → households
-- ============================================================

UPDATE households h
SET config_id = sub.config_id
FROM (
    SELECT
        hm.household_id,
        hc.id AS config_id
    FROM hue_config hc
    JOIN auth.users au ON au.email = hc.user_email
    JOIN household_members hm ON hm.user_id = au.id
    JOIN households h2 ON h2.id = hm.household_id
    WHERE h2.config_id IS NULL
) sub
WHERE h.id = sub.household_id
  AND h.config_id IS NULL;

-- ============================================================
-- STAP 2: Trigger functie - automatisch koppelen bij nieuwe hue_config
-- ============================================================

CREATE OR REPLACE FUNCTION link_config_to_household()
RETURNS TRIGGER AS $$
DECLARE
    v_user_id UUID;
    v_household_id UUID;
BEGIN
    -- Zoek de auth user bij dit email
    SELECT au.id INTO v_user_id
    FROM auth.users au
    WHERE au.email = NEW.user_email
    LIMIT 1;

    IF v_user_id IS NOT NULL THEN
        -- Zoek een household van deze user die nog geen config_id heeft
        SELECT hm.household_id INTO v_household_id
        FROM household_members hm
        JOIN households h ON hm.household_id = h.id
        WHERE hm.user_id = v_user_id
          AND h.config_id IS NULL
        LIMIT 1;

        IF v_household_id IS NOT NULL THEN
            UPDATE households
            SET config_id = NEW.id
            WHERE id = v_household_id;

            RAISE NOTICE 'Linked config % to household % for user %',
                NEW.id, v_household_id, NEW.user_email;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

ALTER FUNCTION link_config_to_household() OWNER TO postgres;

-- ============================================================
-- STAP 3: Trigger aanmaken
-- ============================================================

DROP TRIGGER IF EXISTS trigger_link_config_to_household ON hue_config;
CREATE TRIGGER trigger_link_config_to_household
    AFTER INSERT ON hue_config
    FOR EACH ROW
    EXECUTE FUNCTION link_config_to_household();

-- ============================================================
-- STAP 4: Verificatie
-- ============================================================

DO $$
DECLARE
    v_linked INTEGER;
    v_unlinked INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_linked
    FROM households WHERE config_id IS NOT NULL;

    SELECT COUNT(*) INTO v_unlinked
    FROM households WHERE config_id IS NULL;

    RAISE NOTICE '✓ Households met config_id: %', v_linked;
    RAISE NOTICE '  Households zonder config_id: % (normaal voor users zonder Hue Bridge)', v_unlinked;

    -- Check trigger
    IF EXISTS (
        SELECT 1 FROM information_schema.triggers
        WHERE trigger_name = 'trigger_link_config_to_household'
    ) THEN
        RAISE NOTICE '✓ Trigger link_config_to_household aangemaakt';
    ELSE
        RAISE WARNING '✗ Trigger link_config_to_household ONTBREEKT!';
    END IF;
END $$;
