# handheld_pc

Tools and fixes for personal handheld PCs running SteamOS / Linux gaming stacks.

## Devices

| Device | Folder | Status |
|--------|--------|--------|
| Lenovo Legion Go 2 | [`devices/legion-go-2/`](devices/legion-go-2/) | Active |
| Valve Steam Deck | [`devices/steam-deck/`](devices/steam-deck/) | Placeholder |

## Layout

```text
handheld_pc/
├── AGENTS.md                 # Context for AI agents (Cursor / Codex / …)
├── .cursor/rules/            # Cursor project rules (auto-injected context)
├── devices/
│   ├── legion-go-2/
│   │   └── fixes/
│   │       └── gyroscope-imu-udev/
│   └── steam-deck/
│       └── fixes/            # (future)
└── docs/
    └── conventions.md
```

## Quick start (Legion Go 2 gyro)

```bash
cd "devices/legion-go-2/fixes/gyroscope-imu-udev"
chmod +x fix-legion-go2-gyro.sh
./fix-legion-go2-gyro.sh
```

Read the knowledge base first if something regresses after a SteamOS update:

→ [`devices/legion-go-2/fixes/gyroscope-imu-udev/KNOWLEDGE.md`](devices/legion-go-2/fixes/gyroscope-imu-udev/KNOWLEDGE.md)

## Working in Cursor

1. **File → Open Folder** →  
   `/home/deck/Documents/Stark Industries/GitHub/handheld_pc`
2. Open a chat in that workspace so `AGENTS.md` and `.cursor/rules` apply.
3. Prefer editing under `devices/<device>/fixes/<fix-name>/` rather than scattering scripts in `~/Downloads`.

## Principles

- Prefer **stock SteamOS** + the smallest possible overlay.
- One fix = one folder: script + knowledge doc (+ optional rules).
- No custom InputPlumber binaries unless a knowledge doc explicitly justifies why stock cannot work.
