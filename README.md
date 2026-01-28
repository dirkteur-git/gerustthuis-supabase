# GerustThuis Supabase

Database layer en backend logica voor GerustThuis.

## Structuur

```
gerustthuis-supabase/
├── migrations/          # Database migraties
├── functions/           # Supabase Edge Functions
├── seed/               # Test data
└── types/              # TypeScript types (gegenereerd)
```

## Setup

1. Installeer Supabase CLI: `npm install -g supabase`
2. Login: `supabase login`
3. Link project: `supabase link --project-ref <project-id>`

## Migraties

```bash
# Nieuwe migratie aanmaken
supabase migration new <naam>

# Migraties uitvoeren
supabase db push

# Types genereren
supabase gen types typescript --local > types/database.ts
```
