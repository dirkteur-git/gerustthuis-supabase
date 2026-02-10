-- ============================================================
-- GerustThuis - Cron Jobs voor Data Aggregatie
--
-- Probleem: room_activity_hourly en daily_activity_stats worden
-- alleen gevuld bij handmatige migratie-aanroepen. Er is geen
-- automatische aggregatie van activity_events data.
--
-- Oplossing: pg_cron jobs die regelmatig aggregeren:
--   - aggregate_hourly_activity(3): elk uur, aggregeert laatste 3 uur
--   - refresh_daily_activity_stats(NULL, 2): elk uur, herberekent 2 dagen
--
-- VEILIG OM MEERDERE KEREN UIT TE VOEREN (idempotent)
-- Datum: 2026-02-10
-- ============================================================

-- ============================================================
-- STAP 0: Eerst handmatig aggregeren om gat te vullen
-- Alles van afgelopen 48 uur aggregeren (eventueel gemiste data)
-- ============================================================

SELECT aggregate_hourly_activity(48);
SELECT refresh_daily_activity_stats(NULL, 2);

-- ============================================================
-- STAP 1: Verwijder bestaande cron jobs (indien aanwezig)
-- ============================================================

-- pg_cron is beschikbaar op Supabase Pro plan
DO $$
BEGIN
    -- Verwijder oude jobs als ze bestaan
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'aggregate-hourly-activity') THEN
        PERFORM cron.unschedule('aggregate-hourly-activity');
        RAISE NOTICE 'Oude cron job aggregate-hourly-activity verwijderd';
    END IF;

    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'refresh-daily-stats') THEN
        PERFORM cron.unschedule('refresh-daily-stats');
        RAISE NOTICE 'Oude cron job refresh-daily-stats verwijderd';
    END IF;
END $$;

-- ============================================================
-- STAP 2: Maak cron jobs aan
-- ============================================================

-- Elk uur: aggregeer activity_events naar room_activity_hourly (laatste 3 uur)
SELECT cron.schedule(
    'aggregate-hourly-activity',
    '5 * * * *',
    $$SELECT aggregate_hourly_activity(3)$$
);

-- Elk uur: herbereken daily_activity_stats voor alle configs (laatste 2 dagen)
SELECT cron.schedule(
    'refresh-daily-stats',
    '10 * * * *',
    $$SELECT refresh_daily_activity_stats(NULL, 2)$$
);

-- ============================================================
-- STAP 3: Verificatie
-- ============================================================

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'aggregate-hourly-activity') THEN
        RAISE NOTICE '✓ Cron job aggregate-hourly-activity aangemaakt (elk uur, xx:05)';
    ELSE
        RAISE WARNING '✗ Cron job aggregate-hourly-activity NIET aangemaakt!';
    END IF;

    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'refresh-daily-stats') THEN
        RAISE NOTICE '✓ Cron job refresh-daily-stats aangemaakt (elk uur, xx:10)';
    ELSE
        RAISE WARNING '✗ Cron job refresh-daily-stats NIET aangemaakt!';
    END IF;

    RAISE NOTICE 'Migratie 019_aggregation_cron_jobs voltooid';
END $$;
