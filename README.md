# PitchMarket data backup

Taken 2026-11-26T12:54:25Z by the nightly backup job (`.github/workflows/backup-data.yml` on `main`).
Every earlier night is in this branch's history.

| Table | Rows |
|---|---|
| `teams` | 236 |
| `site_settings` | 9 |
| `price_history` | 2633 |

No player data is included: no emails, balances, holdings or trades.

## Restoring

1. If the database is empty (a new Supabase project), first run `supabase-schema.sql` from the `main` branch in the Supabase SQL Editor.
2. Open `restore.sql` in this branch, copy all of it, paste it into a new query in the SQL Editor and click **Run**.

`restore.sql` adds missing rows and overwrites changed ones. It never deletes anything.

To restore an older night, open this branch's commit history, pick the date, and use that commit's `restore.sql`.
