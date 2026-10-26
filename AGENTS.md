# Agent instructions — handheld_pc

This repository stores **tools and fixes** for handheld PCs (Steam Deck, Lenovo Legion Go 2, …).

## How to work here

1. Identify the **device** (`devices/legion-go-2`, `devices/ps5-ubuntu`, `devices/steam-deck`, …).
2. Prefer extending an existing fix folder over creating ad-hoc scripts in `$HOME/Downloads`.
3. Every fix folder should contain at least:
   - a runnable script or clear manual steps
   - `KNOWLEDGE.md` — durable context (root cause, verification, anti-patterns)
4. Keep system changes minimal. SteamOS already manages InputPlumber targets via `steamos-manager` for Legion Go (`deck-uhid`).

## When the user reports a regression

1. Read the device fix `KNOWLEDGE.md` before inventing a new theory.
2. Run the fix script if one exists; if it fails, use its debug dump.
3. Do **not** reinstall custom InputPlumber binaries or set `GYRO_GAIN` multipliers unless stock paths are proven broken *and* documented.

## Anti-patterns (learned the hard way)

- Treating AMD SFH IIO `buffer/enable` failures as the Legion Go 2 gyro blocker (InputPlumber polls `*_raw`, not the IIO buffer).
- Multiplying controller gyro (already i16-scale) by large gains (e.g. 50) → saturation / jitter.
- Fighting `steamos-manager` target selection with extra systemd oneshots when `deck-uhid` already exposes gyro.

## Adding a new fix

```text
devices/<device>/fixes/<short-name>/
  README.md          # one-screen summary + how to run
  KNOWLEDGE.md       # full durable context
  fix-....sh         # optional automation
```

Update the device `README.md` index and the root `README.md` table if needed.
