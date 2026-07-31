# Conventions

## Fix folder contract

Each fix under `devices/<device>/fixes/<name>/` should be self-contained:

| File | Required | Role |
|------|----------|------|
| `README.md` | Yes | What / when / how to run (short) |
| `KNOWLEDGE.md` | Yes | Root cause, architecture, verification, anti-patterns |
| `fix-*.sh` | Optional | Idempotent automation; on failure dump debug |

## Naming

- Device folders: `legion-go-2`, `steam-deck` (kebab-case).
- Fix folders: short symptom or mechanism (`gyroscope-imu-udev`).
- Scripts: `fix-<device>-<topic>.sh`.

## Safety

- Scripts may use `pkexec` for root.
- Prefer writing only to `/etc/udev/rules.d/` or other documented overlay paths.
- Do not modify `/usr` when an `/etc` overlay works (SteamOS updates overwrite `/usr`).

## AI-friendly extras used here

- **`AGENTS.md`** — portable agent brief (Cursor, Codex, Claude Code, …).
- **`.cursor/rules/*.mdc`** — Cursor rules with globs so context loads when editing a fix.
- Keep `KNOWLEDGE.md` schematic: checklists > essays.
