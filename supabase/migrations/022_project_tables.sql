-- ============================================================
-- GerustThuis - Migratie 022: Projectplan Tabellen
--
-- Genormaliseerde tabellen voor projectplan/taken beheer:
--   1. projects         - project per gebruiker
--   2. project_phases   - fasen met status en budget
--   3. phase_criteria   - go/no-go criteria per fase
--   4. phase_purchases  - uitgaven per fase
--   5. phase_decisions  - go/no-go besluiten
--   6. project_tickets  - taken/tickets
--   7. ticket_dependencies - relaties tussen tickets
--
-- RLS: alle tabellen via projects.user_id = auth.uid()
--
-- Datum: 2026-02-15
-- ============================================================


-- ============================================================
-- STAP 1: projects
-- ============================================================

CREATE TABLE IF NOT EXISTS projects (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE,
    name            TEXT NOT NULL DEFAULT 'GerustThuis',
    description     TEXT,
    total_budget    NUMERIC DEFAULT 0,
    currency        TEXT DEFAULT 'EUR',
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

DROP TRIGGER IF EXISTS trigger_projects_updated_at ON projects;
CREATE TRIGGER trigger_projects_updated_at
    BEFORE UPDATE ON projects
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();


-- ============================================================
-- STAP 2: project_phases
-- ============================================================

CREATE TABLE IF NOT EXISTS project_phases (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id      UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    phase_number    INTEGER NOT NULL,
    name            TEXT NOT NULL,
    description     TEXT,
    goal            TEXT,
    target_date     DATE,
    measurement     TEXT,
    status          TEXT NOT NULL DEFAULT 'niet gestart'
        CHECK (status IN ('niet gestart', 'actief', 'go-no-go', 'afgerond')),
    budget          NUMERIC,
    no_go_action    TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(project_id, phase_number)
);

CREATE INDEX IF NOT EXISTS idx_project_phases_project ON project_phases(project_id);

DROP TRIGGER IF EXISTS trigger_project_phases_updated_at ON project_phases;
CREATE TRIGGER trigger_project_phases_updated_at
    BEFORE UPDATE ON project_phases
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();


-- ============================================================
-- STAP 3: phase_criteria
-- ============================================================

CREATE TABLE IF NOT EXISTS phase_criteria (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phase_id        UUID NOT NULL REFERENCES project_phases(id) ON DELETE CASCADE,
    criterion_key   TEXT NOT NULL,
    description     TEXT NOT NULL,
    completed       BOOLEAN DEFAULT false,
    completed_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(phase_id, criterion_key)
);

CREATE INDEX IF NOT EXISTS idx_phase_criteria_phase ON phase_criteria(phase_id);


-- ============================================================
-- STAP 4: phase_purchases
-- ============================================================

CREATE TABLE IF NOT EXISTS phase_purchases (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phase_id        UUID NOT NULL REFERENCES project_phases(id) ON DELETE CASCADE,
    description     TEXT NOT NULL,
    amount          NUMERIC NOT NULL,
    purchase_date   DATE DEFAULT CURRENT_DATE,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_phase_purchases_phase ON phase_purchases(phase_id);


-- ============================================================
-- STAP 5: phase_decisions
-- ============================================================

CREATE TABLE IF NOT EXISTS phase_decisions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phase_id        UUID NOT NULL REFERENCES project_phases(id) ON DELETE CASCADE,
    decision        TEXT NOT NULL
        CHECK (decision IN ('go', 'no-go')),
    notes           TEXT,
    decided_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_phase_decisions_phase ON phase_decisions(phase_id);


-- ============================================================
-- STAP 6: project_tickets
-- ============================================================

CREATE TABLE IF NOT EXISTS project_tickets (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id      UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    phase_id        UUID REFERENCES project_phases(id) ON DELETE SET NULL,
    ticket_number   TEXT NOT NULL,
    title           TEXT NOT NULL,
    description     TEXT,
    epic            TEXT,
    status          TEXT NOT NULL DEFAULT 'todo'
        CHECK (status IN ('todo', 'in-progress', 'done')),
    priority        TEXT NOT NULL DEFAULT 'should'
        CHECK (priority IN ('must', 'should', 'nice')),
    estimated_hours NUMERIC,
    planned_week    INTEGER,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(project_id, ticket_number)
);

CREATE INDEX IF NOT EXISTS idx_project_tickets_project ON project_tickets(project_id);
CREATE INDEX IF NOT EXISTS idx_project_tickets_phase ON project_tickets(phase_id);
CREATE INDEX IF NOT EXISTS idx_project_tickets_status ON project_tickets(status);

DROP TRIGGER IF EXISTS trigger_project_tickets_updated_at ON project_tickets;
CREATE TRIGGER trigger_project_tickets_updated_at
    BEFORE UPDATE ON project_tickets
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();


-- ============================================================
-- STAP 7: ticket_dependencies
-- ============================================================

CREATE TABLE IF NOT EXISTS ticket_dependencies (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ticket_id       UUID NOT NULL REFERENCES project_tickets(id) ON DELETE CASCADE,
    depends_on_id   UUID NOT NULL REFERENCES project_tickets(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(ticket_id, depends_on_id),
    CHECK(ticket_id != depends_on_id)
);

CREATE INDEX IF NOT EXISTS idx_ticket_dependencies_ticket ON ticket_dependencies(ticket_id);
CREATE INDEX IF NOT EXISTS idx_ticket_dependencies_depends ON ticket_dependencies(depends_on_id);


-- ============================================================
-- STAP 8: RLS policies
-- ============================================================

ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_phases ENABLE ROW LEVEL SECURITY;
ALTER TABLE phase_criteria ENABLE ROW LEVEL SECURITY;
ALTER TABLE phase_purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE phase_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE ticket_dependencies ENABLE ROW LEVEL SECURITY;

-- projects: user ziet en beheert eigen project
DROP POLICY IF EXISTS "Users manage own projects" ON projects;
CREATE POLICY "Users manage own projects" ON projects
    FOR ALL TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "Service role full access projects" ON projects;
CREATE POLICY "Service role full access projects" ON projects
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- project_phases: via project ownership
DROP POLICY IF EXISTS "Users manage own phases" ON project_phases;
CREATE POLICY "Users manage own phases" ON project_phases
    FOR ALL TO authenticated
    USING (project_id IN (SELECT id FROM projects WHERE user_id = auth.uid()))
    WITH CHECK (project_id IN (SELECT id FROM projects WHERE user_id = auth.uid()));

DROP POLICY IF EXISTS "Service role full access phases" ON project_phases;
CREATE POLICY "Service role full access phases" ON project_phases
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- phase_criteria: via phase → project ownership
DROP POLICY IF EXISTS "Users manage own criteria" ON phase_criteria;
CREATE POLICY "Users manage own criteria" ON phase_criteria
    FOR ALL TO authenticated
    USING (phase_id IN (
        SELECT pp.id FROM project_phases pp
        JOIN projects p ON pp.project_id = p.id
        WHERE p.user_id = auth.uid()
    ))
    WITH CHECK (phase_id IN (
        SELECT pp.id FROM project_phases pp
        JOIN projects p ON pp.project_id = p.id
        WHERE p.user_id = auth.uid()
    ));

DROP POLICY IF EXISTS "Service role full access criteria" ON phase_criteria;
CREATE POLICY "Service role full access criteria" ON phase_criteria
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- phase_purchases: via phase → project ownership
DROP POLICY IF EXISTS "Users manage own purchases" ON phase_purchases;
CREATE POLICY "Users manage own purchases" ON phase_purchases
    FOR ALL TO authenticated
    USING (phase_id IN (
        SELECT pp.id FROM project_phases pp
        JOIN projects p ON pp.project_id = p.id
        WHERE p.user_id = auth.uid()
    ))
    WITH CHECK (phase_id IN (
        SELECT pp.id FROM project_phases pp
        JOIN projects p ON pp.project_id = p.id
        WHERE p.user_id = auth.uid()
    ));

DROP POLICY IF EXISTS "Service role full access purchases" ON phase_purchases;
CREATE POLICY "Service role full access purchases" ON phase_purchases
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- phase_decisions: via phase → project ownership
DROP POLICY IF EXISTS "Users manage own decisions" ON phase_decisions;
CREATE POLICY "Users manage own decisions" ON phase_decisions
    FOR ALL TO authenticated
    USING (phase_id IN (
        SELECT pp.id FROM project_phases pp
        JOIN projects p ON pp.project_id = p.id
        WHERE p.user_id = auth.uid()
    ))
    WITH CHECK (phase_id IN (
        SELECT pp.id FROM project_phases pp
        JOIN projects p ON pp.project_id = p.id
        WHERE p.user_id = auth.uid()
    ));

DROP POLICY IF EXISTS "Service role full access decisions" ON phase_decisions;
CREATE POLICY "Service role full access decisions" ON phase_decisions
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- project_tickets: via project ownership
DROP POLICY IF EXISTS "Users manage own tickets" ON project_tickets;
CREATE POLICY "Users manage own tickets" ON project_tickets
    FOR ALL TO authenticated
    USING (project_id IN (SELECT id FROM projects WHERE user_id = auth.uid()))
    WITH CHECK (project_id IN (SELECT id FROM projects WHERE user_id = auth.uid()));

DROP POLICY IF EXISTS "Service role full access tickets" ON project_tickets;
CREATE POLICY "Service role full access tickets" ON project_tickets
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- ticket_dependencies: via ticket → project ownership
DROP POLICY IF EXISTS "Users manage own dependencies" ON ticket_dependencies;
CREATE POLICY "Users manage own dependencies" ON ticket_dependencies
    FOR ALL TO authenticated
    USING (ticket_id IN (
        SELECT pt.id FROM project_tickets pt
        JOIN projects p ON pt.project_id = p.id
        WHERE p.user_id = auth.uid()
    ))
    WITH CHECK (ticket_id IN (
        SELECT pt.id FROM project_tickets pt
        JOIN projects p ON pt.project_id = p.id
        WHERE p.user_id = auth.uid()
    ));

DROP POLICY IF EXISTS "Service role full access dependencies" ON ticket_dependencies;
CREATE POLICY "Service role full access dependencies" ON ticket_dependencies
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);


-- ============================================================
-- Klaar! Verificatie queries:
-- ============================================================
-- 1. SELECT table_name FROM information_schema.tables
--    WHERE table_schema = 'public' AND table_name LIKE 'project%'
--    OR table_name LIKE 'phase%' OR table_name LIKE 'ticket%';
-- 2. SELECT policyname, tablename FROM pg_policies
--    WHERE schemaname = 'public' AND tablename IN
--    ('projects','project_phases','phase_criteria','phase_purchases',
--     'phase_decisions','project_tickets','ticket_dependencies');
