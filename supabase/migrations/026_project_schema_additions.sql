-- ============================================================
-- GerustThuis - Migratie 026: Project Schema Uitbreidingen
--
-- Voegt ontbrekende kolommen toe aan de project-tabellen
-- uit migratie 022, zodat het admin portaal Supabase
-- kan gebruiken i.p.v. localStorage.
--
-- Toevoegingen:
--   project_tickets: value, acceptance_criteria, labels, comments,
--                    depends_on, blocked_by (alle JSONB/TEXT)
--   projects: labels (JSONB), next_ticket_number (INTEGER)
--   project_phases: go_no_go_decision (JSONB)
--
-- VEILIG OM MEERDERE KEREN UIT TE VOEREN (idempotent)
-- Datum: 2026-02-17
-- ============================================================


-- ============================================================
-- STAP 1: project_tickets uitbreiden
-- ============================================================

ALTER TABLE project_tickets
    ADD COLUMN IF NOT EXISTS value TEXT DEFAULT '',
    ADD COLUMN IF NOT EXISTS acceptance_criteria TEXT DEFAULT '',
    ADD COLUMN IF NOT EXISTS labels JSONB DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS comments JSONB DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS depends_on JSONB DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS blocked_by JSONB DEFAULT '[]'::jsonb;


-- ============================================================
-- STAP 2: projects uitbreiden
-- ============================================================

ALTER TABLE projects
    ADD COLUMN IF NOT EXISTS labels JSONB DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS next_ticket_number INTEGER DEFAULT 1;


-- ============================================================
-- STAP 3: project_phases uitbreiden
-- ============================================================

ALTER TABLE project_phases
    ADD COLUMN IF NOT EXISTS go_no_go_decision JSONB;


-- ============================================================
-- STAP 4: Verificatie
-- ============================================================

DO $$
DECLARE
    v_missing TEXT := '';
BEGIN
    -- Check project_tickets kolommen
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'project_tickets' AND column_name = 'value') THEN
        v_missing := v_missing || 'project_tickets.value, ';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'project_tickets' AND column_name = 'acceptance_criteria') THEN
        v_missing := v_missing || 'project_tickets.acceptance_criteria, ';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'project_tickets' AND column_name = 'labels') THEN
        v_missing := v_missing || 'project_tickets.labels, ';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'project_tickets' AND column_name = 'comments') THEN
        v_missing := v_missing || 'project_tickets.comments, ';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'project_tickets' AND column_name = 'depends_on') THEN
        v_missing := v_missing || 'project_tickets.depends_on, ';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'project_tickets' AND column_name = 'blocked_by') THEN
        v_missing := v_missing || 'project_tickets.blocked_by, ';
    END IF;

    -- Check projects kolommen
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'projects' AND column_name = 'labels') THEN
        v_missing := v_missing || 'projects.labels, ';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'projects' AND column_name = 'next_ticket_number') THEN
        v_missing := v_missing || 'projects.next_ticket_number, ';
    END IF;

    -- Check project_phases kolommen
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'project_phases' AND column_name = 'go_no_go_decision') THEN
        v_missing := v_missing || 'project_phases.go_no_go_decision, ';
    END IF;

    IF v_missing = '' THEN
        RAISE NOTICE '✓ Alle kolommen succesvol aangemaakt';
    ELSE
        RAISE WARNING '✗ Ontbrekende kolommen: %', v_missing;
    END IF;

    RAISE NOTICE '';
    RAISE NOTICE 'Migratie 026 voltooid — project schema uitbreidingen';
END $$;
