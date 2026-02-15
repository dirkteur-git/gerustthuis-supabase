-- ============================================================
-- Migration 023: Waitlist table
-- GerustThuis wachtlijst met RLS en rate limiting
-- ============================================================

-- Waitlist tabel
CREATE TABLE IF NOT EXISTS public.waitlist (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  email TEXT NOT NULL,
  name TEXT,
  referral_source TEXT,
  gdpr_consent BOOLEAN NOT NULL DEFAULT false,
  confirmed BOOLEAN NOT NULL DEFAULT false,
  confirm_token UUID DEFAULT gen_random_uuid(),
  synced_to_zoho BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),

  CONSTRAINT waitlist_email_unique UNIQUE (email),
  CONSTRAINT waitlist_email_format CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  CONSTRAINT waitlist_gdpr_required CHECK (gdpr_consent = true)
);

-- Index voor Zoho sync queries
CREATE INDEX IF NOT EXISTS idx_waitlist_synced ON public.waitlist (synced_to_zoho) WHERE synced_to_zoho = false;

-- Index voor confirm token lookups
CREATE INDEX IF NOT EXISTS idx_waitlist_confirm_token ON public.waitlist (confirm_token) WHERE confirmed = false;

-- ============================================================
-- Row Level Security
-- ============================================================

ALTER TABLE public.waitlist ENABLE ROW LEVEL SECURITY;

-- Anonieme gebruikers mogen zich aanmelden (INSERT)
CREATE POLICY "waitlist_anon_insert"
  ON public.waitlist
  FOR INSERT
  TO anon
  WITH CHECK (true);

-- Alleen service_role mag lezen/updaten/verwijderen
CREATE POLICY "waitlist_service_select"
  ON public.waitlist
  FOR SELECT
  TO service_role
  USING (true);

CREATE POLICY "waitlist_service_update"
  ON public.waitlist
  FOR UPDATE
  TO service_role
  USING (true);

CREATE POLICY "waitlist_service_delete"
  ON public.waitlist
  FOR DELETE
  TO service_role
  USING (true);

-- Anonieme gebruikers mogen hun eigen email bevestigen via confirm_token
CREATE POLICY "waitlist_anon_confirm"
  ON public.waitlist
  FOR UPDATE
  TO anon
  USING (true)
  WITH CHECK (confirmed = true);

-- ============================================================
-- Rate limiting functie
-- Max 3 aanmeldingen per IP per uur (aangeroepen vanuit Edge Function)
-- ============================================================

-- Teller tabel voor rate limiting
CREATE TABLE IF NOT EXISTS public.waitlist_rate_limits (
  ip_address TEXT NOT NULL,
  window_start TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now()),
  request_count INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (ip_address, window_start)
);

-- Oude rate limit records opruimen (ouder dan 2 uur)
CREATE OR REPLACE FUNCTION public.cleanup_waitlist_rate_limits()
RETURNS void
LANGUAGE sql
AS $$
  DELETE FROM public.waitlist_rate_limits
  WHERE window_start < now() - interval '2 hours';
$$;

-- RLS op rate limits: alleen service_role
ALTER TABLE public.waitlist_rate_limits ENABLE ROW LEVEL SECURITY;

CREATE POLICY "rate_limits_service_only"
  ON public.waitlist_rate_limits
  FOR ALL
  TO service_role
  USING (true);

-- ============================================================
-- Functie: tel wachtlijst aanmeldingen (voor social proof counter)
-- Beschikbaar voor anonieme gebruikers
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_waitlist_count()
RETURNS INTEGER
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT COUNT(*)::INTEGER FROM public.waitlist WHERE confirmed = true;
$$;

-- Grant execute aan anon
GRANT EXECUTE ON FUNCTION public.get_waitlist_count() TO anon;
