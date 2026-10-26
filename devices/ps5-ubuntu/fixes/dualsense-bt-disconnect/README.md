# Fix: DualSense Bluetooth disconnect on game launch

## Symptom

DualSense pairs and works over Bluetooth. Steam detects it as DualSense. Shortly after opening a game (observed: **Marvel Rivals**), the controller disconnects by itself.

## What this folder is

Confirmed workaround plus the debug trail. Full context: **[KNOWLEDGE.md](KNOWLEDGE.md)**.

## Capture a debug dump (do this first)

```bash
chmod +x ./debug-dualsense-bt-disconnect.sh
./debug-dualsense-bt-disconnect.sh
```

1. Connect the DualSense over Bluetooth **before** starting the script (or right after it starts).
2. Leave Steam open with the controller already recognized.
3. When the script says so, launch the game that triggers the drop.
4. Wait until it disconnects (or ~60s), then press Enter in the terminal.
5. Open the dump path printed at the end and share it (or the `SUMMARY` section).

Optional: install `bluez-tools` / ensure `btmon` exists for HCI-level reasons (`sudo apt install bluez`).

Writes `~/Downloads/dualsense-bt-disconnect-<UTC>.txt` (and a raw `*.d/` next to it when collectors ran).

## Apply the workaround

Steam → **Settings → Controller → PlayStation Controller Support → Disabled**.

Quit Steam completely, open it again, reconnect the DualSense, launch the game.

That stops the Steam client from holding `/dev/hidraw*` and writing DualSense output reports. Bluetooth stays up either way; with the support enabled, the HID session dies a few seconds into the game.

Also still in place when this was confirmed (not bisected away; leave them unless you want to test):

- `/etc/bluetooth/input.conf`: `UserspaceHID=false` (kernel HIDP)
- Marvel Rivals launch option: `SDL_JOYSTICK_HIDAPI_PS5=0 %command%`

### Button icons

Marvel Rivals has no in-game PlayStation/Xbox glyph toggle. With PlayStation Controller Support off, prompts stay PC/Xbox style. Turning that support back on is what brought the disconnect back — do not re-enable it for icons.

Optional glyph try that does **not** re-enable the Steam driver: remove only the `SDL_JOYSTICK_HIDAPI_PS5=0` launch option, keep PlayStation Controller Support disabled, relaunch. If the pad dies again, put the launch option back.
