-- ============================================================
-- GerustThuis - Migratie 032: Familiebord berichten
--
-- Tabel voor berichten op het familiebord (Familie tab).
-- Huishoudleden kunnen berichten plaatsen en lezen.
-- Realtime ingeschakeld zodat nieuwe berichten direct verschijnen.
--
-- RLS: gebruikt get_my_household_ids() om recursie te voorkomen.
-- ============================================================

CREATE TABLE IF NOT EXISTS family_board_messages (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id UUID        NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  user_id      UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  message      TEXT        NOT NULL CHECK (char_length(message) BETWEEN 1 AND 500),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_family_board_household
  ON family_board_messages(household_id, created_at DESC);

ALTER TABLE family_board_messages ENABLE ROW LEVEL SECURITY;

-- Huishoudleden mogen berichten lezen
DROP POLICY IF EXISTS "Members view family messages" ON family_board_messages;
CREATE POLICY "Members view family messages" ON family_board_messages
  FOR SELECT TO authenticated
  USING (
    household_id IN (SELECT get_my_household_ids())
  );

-- Huishoudleden mogen eigen berichten plaatsen
DROP POLICY IF EXISTS "Members post family messages" ON family_board_messages;
CREATE POLICY "Members post family messages" ON family_board_messages
  FOR INSERT TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND household_id IN (SELECT get_my_household_ids())
  );

-- Alleen eigen berichten verwijderen
DROP POLICY IF EXISTS "Members delete own messages" ON family_board_messages;
CREATE POLICY "Members delete own messages" ON family_board_messages
  FOR DELETE TO authenticated
  USING (user_id = auth.uid());

-- Realtime inschakelen
ALTER PUBLICATION supabase_realtime ADD TABLE family_board_messages;

-- Verificatie
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'family_board_messages'
  ) THEN
    RAISE NOTICE '✓ Tabel family_board_messages aangemaakt';
  ELSE
    RAISE WARNING '✗ family_board_messages ONTBREEKT';
  END IF;
END $$;
