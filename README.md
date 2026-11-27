# PitchMarket data backup

Taken 2026-11-27T12:49:45Z by the nightly backup job (`.github/workflows/backup-data.yml` on `main`).
Every earlier night is in this branch's history.

| Table | Rows |
|---|---|
| `teams` | 236 |
| `site_settings` | 10 |
| `price_history` | 2651 |

No player data is included: no emails, balances, holdings or trades.

## Restoring

1. If the database is empty (a new Supabase project), first run `supabase-schema.sql` from the `main` branch in the Supabase SQL Editor.
2. Open `restore.sql` in this branch, copy all of it, paste it into a new query in the SQL Editor and click **Run**.

`restore.sql` adds missing rows and overwrites changed ones. It never deletes anything.
It never changes the `payments` or `season` rows of `site_settings` already in the database (it only adds them if missing): payments mode is switched to live, or back, on purpose in admin, and the season start decides which portfolio snapshots count.

To restore an older night, open this branch's commit history, pick the date, and use that commit's `restore.sql`.
