-- ============================================================
-- GerustThuis Supabase - Cron Jobs Setup
-- Requires pg_cron and pg_net extensions
-- ============================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- ============================================================
-- Job 1: State Polling - Every 5 minutes
-- Poll all lights and sensors, store only state changes
-- ============================================================

SELECT cron.unschedule('hue-poll-state')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'hue-poll-state');

SELECT cron.schedule(
    'hue-poll-state',
    '*/5 * * * *',
    $$
    SELECT net.http_post(
        url := 'https://mtivqrqylzudduvgejjm.supabase.co/functions/v1/hue-poll-state',
        headers := '{"Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im10aXZxcnF5bHp1ZGR1dmdlamptIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2OTYwNzg1MywiZXhwIjoyMDg1MTgzODUzfQ.pzZyWQ31iELmvqbLLhAsAgTcyXG0RkN27gGAlxhM1Ew", "Content-Type": "application/json"}'::jsonb,
        body := '{}'::jsonb
    ) AS request_id;
    $$
);

-- ============================================================
-- Job 2: Battery Polling - Every hour at minute 0
-- Poll battery levels for all sensors
-- ============================================================

SELECT cron.unschedule('hue-poll-battery')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'hue-poll-battery');

SELECT cron.schedule(
    'hue-poll-battery',
    '0 * * * *',
    $$
    SELECT net.http_post(
        url := 'https://mtivqrqylzudduvgejjm.supabase.co/functions/v1/hue-poll-battery',
        headers := '{"Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im10aXZxcnF5bHp1ZGR1dmdlamptIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2OTYwNzg1MywiZXhwIjoyMDg1MTgzODUzfQ.pzZyWQ31iELmvqbLLhAsAgTcyXG0RkN27gGAlxhM1Ew", "Content-Type": "application/json"}'::jsonb,
        body := '{}'::jsonb
    ) AS request_id;
    $$
);

-- ============================================================
-- Job 3: Aggregate hourly activity - Every hour at minute 5
-- Aggregates raw_events into room_activity_hourly for dashboard
-- ============================================================

SELECT cron.unschedule('aggregate-hourly-activity')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'aggregate-hourly-activity');

SELECT cron.schedule(
    'aggregate-hourly-activity',
    '5 * * * *',
    $$
    SELECT aggregate_hourly_activity(3);
    $$
);

-- ============================================================
-- Job 4: Cleanup old events - Weekly on Sunday at 03:00
-- Keep last 90 days of data
-- ============================================================

SELECT cron.unschedule('cleanup-old-events')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'cleanup-old-events');

SELECT cron.schedule(
    'cleanup-old-events',
    '0 3 * * 0',
    $$
    DELETE FROM raw_events WHERE recorded_at < NOW() - INTERVAL '90 days';
    $$
);

-- ============================================================
-- Verify scheduled jobs
-- ============================================================
SELECT jobid, jobname, schedule, command FROM cron.job ORDER BY jobname;
