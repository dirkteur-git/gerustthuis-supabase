-- ============================================================
-- GerustThuis - Migratie 033: Meldingen tabel
--
-- Tabel voor systeemmeldingen per huishouden (Meldingen tab).
-- Typen: goed | info | goedemorgen | nacht | dagrapport | kritiek
-- Edge Functions schrijven meldingen via service_role.
-- Realtime ingeschakeld zodat nieuwe meldingen direct verschijnen.
--
-- RLS: gebruikt get_my_household_ids() om recursie te voorkomen.
-- ============================================================

CREATE TABLE IF NOT EXISTS notifications (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id UUID        NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  type         TEXT        NOT NULL CHECK (type IN ('goed', 'info', 'goedemorgen', 'nacht', 'dagrapport', 'kritiek')),
  title        TEXT        NOT NULL,
  description  TEXT,
  is_read      BOOLEAN     NOT NULL DEFAULT false,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notifications_household
  ON notifications(household_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_notifications_unread
  ON notifications(household_id, is_read)
  WHERE is_read = false;

ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

-- Huishoudleden mogen meldingen lezen
DROP POLICY IF EXISTS "Members view notifications" ON notifications;
CREATE POLICY "Members view notifications" ON notifications
  FOR SELECT TO authenticated
  USING (
    household_id IN (SELECT get_my_household_ids())
  );

-- Huishoudleden mogen is_read bijwerken (markeer als gelezen)
DROP POLICY IF EXISTS "Members mark notifications read" ON notifications;
CREATE POLICY "Members mark notifications read" ON notifications
  FOR UPDATE TO authenticated
  USING (
    household_id IN (SELECT get_my_household_ids())
  )
  WITH CHECK (true);

-- Service role volledige toegang (Edge Functions schrijven meldingen)
DROP POLICY IF EXISTS "Service role full access notifications" ON notifications;
CREATE POLICY "Service role full access notifications" ON notifications
  FOR ALL TO service_role
  USING (true)
  WITH CHECK (true);

-- Realtime inschakelen
ALTER PUBLICATION supabase_realtime ADD TABLE notifications;

-- Verificatie
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'notifications'
  ) THEN
    RAISE NOTICE '✓ Tabel notifications aangemaakt';
  ELSE
    RAISE WARNING '✗ notifications ONTBREEKT';
  END IF;
END $$;
