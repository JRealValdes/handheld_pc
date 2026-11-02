# Issue: game pad dead after resume, Steam OS still responds

## Symptom

Suspend while a game is running, then resume. Sometimes the game no longer sees the controls. The left Legion button still opens Steam OS, and Steam OS itself can still be driven. A “controller disconnected” toast is unconfirmed.

This is not the [suspend-wake](../suspend-wake/) stuck-sleep bug. Here the machine does wake.

## Status

Open. H1/H2 (dead pad after resume) and stuck RB/R1 after resume are documented in **[KNOWLEDGE.md](KNOWLEDGE.md)**. The watcher is already installed on this machine.

## When it fails (you)

Do **not** run scripts in Gaming mode. Do **not** need `nudge` yourself.

1. Note the **clock time** (24h) when it went bad.
2. Note the symptom in one line, e.g. “mando muerto en el juego, UI Steam OK” / “UI Steam también muerta” / “RB fantasma; toqué RB y [sí/no] soltó”.
3. Switch to **Desktop** and say that here in chat.

The agent recovers `~/legion-go2-resume-gamepad/cycles/…` with `find "HH:MM"` and digs. Going to Desktop is fine: it does not delete those dumps (it is not a suspend). Leaving the game may clear a live stuck-RB state; the resume cycle + your note are still enough to investigate.

## Capture (install / agent)

Install once if needed (polkit). Last 20 cycles kept.

```bash
cd "devices/legion-go-2/fixes/resume-gamepad"
./trace-legion-go2-resume-gamepad.sh install
```

Agent lookup (not for you unless you want):

```bash
./trace-legion-go2-resume-gamepad.sh find "21:40"
```

On each resume the watcher auto-repairs two known breaks (see cycle `nudge.log`):

1. Sealed deck-uhid hidraw (`28de:12fb` mode `000`) → chmod/ACL + bounce `deck-uhid`.
2. One `touch` on `Microsoft X-Box 360 pad 0` so Proton retries open.

## Remove

`install` adds one systemd unit, `/etc/systemd/system/legion-go2-resume-gamepad-trace.service`. It is not a `/usr/lib/systemd/system-sleep/` hook. To stop and delete it (polkit prompt):

```bash
./trace-legion-go2-resume-gamepad.sh uninstall
```

Dumps under `~/legion-go2-resume-gamepad/` are kept.
