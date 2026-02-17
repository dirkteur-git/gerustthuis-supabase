-- Migration 027: Postcode-veld toevoegen aan waitlist (TM-64)
-- Postcodes worden opgeslagen voor regionale planning bij lancering.

ALTER TABLE waitlist
  ADD COLUMN IF NOT EXISTS postcode TEXT DEFAULT NULL;

-- Optioneel: index voor regionale queries
CREATE INDEX IF NOT EXISTS idx_waitlist_postcode ON waitlist (postcode) WHERE postcode IS NOT NULL;
