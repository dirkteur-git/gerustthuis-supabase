-- Migration 031: Add setup_completed flag to user_profiles
-- This flag tracks whether a user has completed (or deliberately skipped) the onboarding setup.
-- DashboardGuard checks this to decide whether to redirect to /setup/welcome.

ALTER TABLE user_profiles
  ADD COLUMN IF NOT EXISTS setup_completed BOOLEAN NOT NULL DEFAULT false;

-- Mark existing users who already have residents configured as having completed setup.
-- This prevents them from being redirected back to setup after this migration runs.
UPDATE user_profiles
SET setup_completed = true
WHERE id IN (
  SELECT DISTINCT hm.user_id
  FROM household_members hm
  JOIN households h ON h.id = hm.household_id
  JOIN residents r ON r.household_id = h.id
);
