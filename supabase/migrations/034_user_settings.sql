-- ============================================================
-- GerustThuis - Migratie 034: Gebruikersinstellingen
--
-- Notificatievoorkeuren per gebruiker (Instellingen tab).
-- Één rij per gebruiker, aangemaakt bij eerste opslag.
-- updated_at wordt automatisch bijgewerkt via trigger.
--
-- Let op: update_updated_at_column() is aangemaakt in migratie 012.
-- ============================================================

CREATE TABLE IF NOT EXISTS user_settings (
  user_id                   UUID        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,

  -- Meldingen
  dagelijks_samenvatting    BOOLEAN     NOT NULL DEFAULT true,
  samenvatting_tijd         TIME        NOT NULL DEFAULT '19:00',
  samenvatting_medium       TEXT        NOT NULL DEFAULT 'app' CHECK (samenvatting_medium IN ('app', 'email')),
  kritieke_alerts           BOOLEAN     NOT NULL DEFAULT true,
  nachtelijke_activiteit    BOOLEAN     NOT NULL DEFAULT false,

  updated_at                TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- updated_at trigger
DROP TRIGGER IF EXISTS trigger_user_settings_updated_at ON user_settings;
CREATE TRIGGER trigger_user_settings_updated_at
  BEFORE UPDATE ON user_settings
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

ALTER TABLE user_settings ENABLE ROW LEVEL SECURITY;

-- Gebruiker mag alleen eigen rij lezen
DROP POLICY IF EXISTS "Users view own settings" ON user_settings;
CREATE POLICY "Users view own settings" ON user_settings
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- Gebruiker mag eigen instellingen aanmaken en bijwerken
DROP POLICY IF EXISTS "Users manage own settings" ON user_settings;
CREATE POLICY "Users manage own settings" ON user_settings
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Verificatie
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'user_settings'
  ) THEN
    RAISE NOTICE '✓ Tabel user_settings aangemaakt';
  ELSE
    RAISE WARNING '✗ user_settings ONTBREEKT';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'update_updated_at_column') THEN
    RAISE NOTICE '✓ Functie update_updated_at_column() bestaat (migratie 012)';
  ELSE
    RAISE WARNING '✗ Functie update_updated_at_column() ONTBREEKT — draai eerst migratie 012';
  END IF;
END $$;
