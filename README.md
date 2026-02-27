# GerustThuis Supabase

Database migraties en Edge Functions voor GerustThuis.

> Database schema en ontwerp: [gerustthuis-docs/DATABASE_DESIGN.md](https://github.com/dirkteur-git/gerustthuis-docs/blob/main/DATABASE_DESIGN.md)

---

## Structuur

```
gerustthuis-supabase/
├── supabase/
│   ├── migrations/      Database migraties (001 t/m huidig)
│   └── functions/       Supabase Edge Functions (Deno/TypeScript)
│       ├── hue-sync-state/      Polling Hue Bridge, events schrijven
│       ├── hue-token-exchange/  OAuth token exchange
│       └── _shared/             Gedeelde code (cors, hue-client)
```

---

## Setup

```bash
npm install -g supabase
supabase login
supabase link --project-ref <project-id>
```

---

## Migraties

```bash
# Nieuwe migratie aanmaken
supabase migration new <naam>

# Migraties uitvoeren
supabase db push

# TypeScript types genereren
supabase gen types typescript --local > types/database.ts
```

---

## Edge Functions

| Function | Schedule | Beschrijving |
|----------|----------|--------------|
| `hue-sync-state` | `*/5 * * * *` | Synchroniseer Hue Bridge, detecteer state changes, schrijf naar activity_events |
| `hue-token-exchange` | On-demand | OAuth token exchange bij Hue koppeling |

---

## Data Flow

```
Hue Bridge → hue-sync-state (5 min)
    │
    ├── activity_events (INSERT bij change)
    ├── hue_devices (UPDATE state)
    └── room_activity (UPSERT 5-min window)
              │
              ▼ (pg_cron, elk uur)
    room_activity_hourly
    daily_activity_stats
```

---

## Documentatie

| Document | Inhoud |
|----------|--------|
| [DATABASE_DESIGN.md](https://github.com/dirkteur-git/gerustthuis-docs/blob/main/DATABASE_DESIGN.md) | Volledig schema, RLS policies, migratie-overzicht |
| [HUE_INTEGRATION.md](https://github.com/dirkteur-git/gerustthuis-docs/blob/main/HUE_INTEGRATION.md) | Hue API, OAuth flow, device types |
| [ARCHITECTURE.md](https://github.com/dirkteur-git/gerustthuis-docs/blob/main/ARCHITECTURE.md) | Systeemarchitectuur en data flow |
