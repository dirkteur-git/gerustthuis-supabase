-- Migration 029: Fix waitlist confirmation + missing RLS policies
-- De RLS policies uit migratie 023 waren niet aangemaakt op productie.
-- Voegt een SECURITY DEFINER functie toe voor bevestiging (robuuster dan RLS).

-- ============================================================
-- 1. SECURITY DEFINER functie voor email bevestiging
--    Wordt aangeroepen vanuit de website met de anon key.
-- ============================================================

CREATE OR REPLACE FUNCTION public.confirm_waitlist_email(p_token UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  UPDATE public.waitlist
  SET confirmed = true
  WHERE confirm_token = p_token
    AND confirmed = false;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count > 0;
END;
$$;

-- Anon mag deze functie aanroepen
GRANT EXECUTE ON FUNCTION public.confirm_waitlist_email(UUID) TO anon;

-- ============================================================
-- 2. Ontbrekende RLS policies aanmaken (idempotent)
-- ============================================================

-- Anon INSERT (voor directe DB inserts, al afgehandeld door edge function)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'waitlist' AND policyname = 'waitlist_anon_insert'
  ) THEN
    CREATE POLICY "waitlist_anon_insert"
      ON public.waitlist FOR INSERT TO anon
      WITH CHECK (true);
  END IF;
END $$;

-- Anon UPDATE (voor email bevestiging via confirm_token)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'waitlist' AND policyname = 'waitlist_anon_confirm'
  ) THEN
    CREATE POLICY "waitlist_anon_confirm"
      ON public.waitlist FOR UPDATE TO anon
      USING (true)
      WITH CHECK (confirmed = true);
  END IF;
END $$;

-- Service role SELECT
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'waitlist' AND policyname = 'waitlist_service_select'
  ) THEN
    CREATE POLICY "waitlist_service_select"
      ON public.waitlist FOR SELECT TO service_role
      USING (true);
  END IF;
END $$;

-- Service role UPDATE
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'waitlist' AND policyname = 'waitlist_service_update'
  ) THEN
    CREATE POLICY "waitlist_service_update"
      ON public.waitlist FOR UPDATE TO service_role
      USING (true);
  END IF;
END $$;

-- Service role DELETE
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'waitlist' AND policyname = 'waitlist_service_delete'
  ) THEN
    CREATE POLICY "waitlist_service_delete"
      ON public.waitlist FOR DELETE TO service_role
      USING (true);
  END IF;
END $$;

-- ============================================================
-- 3. RLS policies voor waitlist_rate_limits (ontbreken mogelijk ook)
-- ============================================================

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'waitlist_rate_limits' AND policyname = 'rate_limits_service_only'
  ) THEN
    CREATE POLICY "rate_limits_service_only"
      ON public.waitlist_rate_limits FOR ALL TO service_role
      USING (true);
  END IF;
END $$;
