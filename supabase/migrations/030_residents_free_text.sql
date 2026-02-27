-- ============================================================
-- GerustThuis - Migratie 030: residents.relationship vrije tekst
--
-- De CHECK constraint op relationship beperkte de waarden tot een
-- vaste lijst (mama, papa, opa, oma, ...). Dit is te beperkend:
-- "Pappa" (dubbel-p), "Vader", "Tante Riet" zijn geldig maar vielen
-- buiten de lijst.
--
-- Oplossing: verwijder de constraint zodat relationship vrije tekst
-- wordt (VARCHAR(50)). De UI biedt een keuzelijst met veelgebruikte
-- opties + een vrij invulveld voor "Anders".
--
-- Datum: 2026-02-25
-- ============================================================

ALTER TABLE residents
    DROP CONSTRAINT IF EXISTS residents_relationship_check;

-- Normaliseer bestaande waarden naar Title Case zodat ze goed
-- weergegeven worden in de app (bijv. "oma" → "Oma")
UPDATE residents
SET relationship = initcap(relationship)
WHERE relationship IS NOT NULL;

-- Verificatie:
-- SELECT id, first_name, relationship FROM residents;
-- SELECT conname FROM pg_constraint WHERE conrelid = 'residents'::regclass;
