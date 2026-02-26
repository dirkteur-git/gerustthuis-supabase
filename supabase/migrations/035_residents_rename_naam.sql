-- ============================================================
-- GerustThuis - Migratie 035: residents.first_name → naam
--
-- OPTIONEEL — alleen uitvoeren na overleg.
--
-- 'first_name' is misleidend: het is een vrije aanduiding
-- (kan "Jenny", "Janssen", "de Boer" zijn — geen echte voornaam).
-- 'naam' is duidelijker en neutraler.
--
-- ⚠️  NA UITVOEREN ook app-code updaten:
--   - src/types/index.ts          Resident.first_name → Resident.naam
--   - src/utils/formatting.ts     resident.first_name → resident.naam
--   - src/stores/authStore.ts     select query aanpassen
--   - src/pages/setup/VoorWie.tsx formulier veld naam
-- ============================================================

ALTER TABLE residents
  RENAME COLUMN first_name TO naam;

-- Verificatie
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'residents'
      AND column_name = 'naam'
  ) THEN
    RAISE NOTICE '✓ Kolom residents.naam aanwezig (hernoemd van first_name)';
  ELSE
    RAISE WARNING '✗ Kolom residents.naam ONTBREEKT — rename mislukt?';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'residents'
      AND column_name = 'first_name'
  ) THEN
    RAISE NOTICE '✓ Kolom residents.first_name verwijderd';
  ELSE
    RAISE WARNING '✗ Kolom residents.first_name bestaat nog!';
  END IF;
END $$;
