-- ============================================================
-- GerustThuis - User Profiles Table
-- Stores user profile settings including name, phone, preferences
-- ============================================================

-- ============================================================
-- Table: user_profiles
-- User profile information linked to auth.users
-- ============================================================
CREATE TABLE IF NOT EXISTS user_profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,

    -- Basic info
    display_name VARCHAR(255),

    -- Phone with country code
    phone_country_code VARCHAR(5) DEFAULT '+31',  -- e.g., +31, +32, +49
    phone_number VARCHAR(20),                      -- Without country code

    -- Communication preferences
    -- 'email', 'sms', 'whatsapp'
    communication_preference VARCHAR(20) DEFAULT 'email',

    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- Trigger: Auto-update updated_at
-- ============================================================
CREATE TRIGGER update_user_profiles_updated_at
    BEFORE UPDATE ON user_profiles
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- Function: Auto-create profile on user signup
-- ============================================================
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.user_profiles (id)
    VALUES (NEW.id)
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger on auth.users insert
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION handle_new_user();

-- ============================================================
-- RLS Policies
-- ============================================================
ALTER TABLE user_profiles ENABLE ROW LEVEL SECURITY;

-- Users can only read and update their own profile
CREATE POLICY "Users can view own profile"
    ON user_profiles FOR SELECT
    USING (auth.uid() = id);

CREATE POLICY "Users can update own profile"
    ON user_profiles FOR UPDATE
    USING (auth.uid() = id);

CREATE POLICY "Users can insert own profile"
    ON user_profiles FOR INSERT
    WITH CHECK (auth.uid() = id);

-- ============================================================
-- Index
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_user_profiles_id ON user_profiles(id);
