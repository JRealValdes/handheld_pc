# Issue: game pad dead after resume, Steam OS still responds

## Symptom

Suspend while a game is running, then resume. Sometimes the game no longer sees the controls. The left Legion button still opens Steam OS, and Steam OS itself can still be driven. A “controller disconnected” toast is unconfirmed.

This is not the [suspend-wake](../suspend-wake/) stuck-sleep bug. Here the machine does wake.

## Status

Open. One desktop resume on 2026-10-30 already showed Steam failing to reopen the virtual pad while the keyboard target stayed usable. Not yet captured mid-game. Full notes in **[KNOWLEDGE.md](KNOWLEDGE.md)**.

## Capture

Install once (polkit prompt). Every suspend then writes its own directory. The last 20 are kept. Switching to Desktop is not a suspend and does not delete them.

```bash
cd "devices/legion-go-2/fixes/resume-gamepad"
chmod +x trace-legion-go2-resume-gamepad.sh
./trace-legion-go2-resume-gamepad.sh install
```

After a bad in-game resume, switch to Desktop and report the **resume clock time** (24h). Look that cycle up; do not assume the newest directory is the one:

```bash
./trace-legion-go2-resume-gamepad.sh find "21:40"
```

Steam may rotate its own logs when Desktop starts. Copies taken at resume are already in the cycle (`steam-post-0s-*`, `steam-post-15s-*`). Index: `~/legion-go2-resume-gamepad/index.txt`.

## Remove

`install` adds one systemd unit, `/etc/systemd/system/legion-go2-resume-gamepad-trace.service`. It is not a `/usr/lib/systemd/system-sleep/` hook. To stop and delete it (polkit prompt):

```bash
./trace-legion-go2-resume-gamepad.sh uninstall
```

Dumps under `~/legion-go2-resume-gamepad/` are kept.
