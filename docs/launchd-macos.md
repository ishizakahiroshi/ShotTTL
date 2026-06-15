# Run ShotTTL with launchd on macOS

## Before Scheduling

Run a dry-run first:

```bash
./scripts/unix/shotttl.sh --target "$HOME/Pictures/Screenshots" --keep 24h --dry-run
```

Check the output and the log:

```text
~/.shotttl/logs
```

## Make the Script Executable

launchd runs the script directly, so set the executable bit once:

```bash
chmod +x /path/to/ShotTTL/scripts/unix/shotttl.sh
```

## Example LaunchAgent

Create `~/Library/LaunchAgents/com.shotttl.cleanup.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.shotttl.cleanup</string>

  <key>ProgramArguments</key>
  <array>
    <string>/path/to/ShotTTL/scripts/unix/shotttl.sh</string>
    <string>--target</string>
    <string>/Users/YOUR_USER/Pictures/Screenshots</string>
    <string>--keep</string>
    <string>24h</string>
    <string>--quiet</string>
  </array>

  <key>StartInterval</key>
  <integer>3600</integer>

  <key>RunAtLoad</key>
  <true/>

  <key>StandardOutPath</key>
  <string>/tmp/shotttl.out.log</string>

  <key>StandardErrorPath</key>
  <string>/tmp/shotttl.err.log</string>
</dict>
</plist>
```

`StartInterval` runs the job every N seconds (3600 = hourly). To run at a fixed time of day instead, replace it with `StartCalendarInterval`:

```xml
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>9</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
```

Load it:

```bash
launchctl load ~/Library/LaunchAgents/com.shotttl.cleanup.plist
```

Unload it:

```bash
launchctl unload ~/Library/LaunchAgents/com.shotttl.cleanup.plist
```

## Full Disk Access

Recent macOS releases gate access to folders like `~/Pictures` behind privacy controls (TCC). If the LaunchAgent logs no candidates even though old screenshots exist, try the following in order:

1. Run `shotttl.sh` once interactively from Terminal first (`./scripts/unix/shotttl.sh --target ... --dry-run`) so any TCC consent prompt can be accepted while you are present to answer it.
2. In **System Settings → Privacy & Security → Full Disk Access**, click `+` and add the ShotTTL script itself (`/path/to/ShotTTL/scripts/unix/shotttl.sh`), then `launchctl unload` and `launchctl load` the plist. On macOS 12+ TCC commonly attributes access to the responsible parent (the LaunchAgent / the script being executed), not to the shared interpreter binary, so allowlisting `/bin/bash` is rarely effective.
3. If TCC keeps blocking, point `--target` at a folder outside `~/Pictures`, `~/Desktop`, `~/Documents`, and `~/Downloads` (all TCC-gated). For example, change the macOS screenshot save location in Screenshot.app (`Cmd+Shift+5` → Options → Save to) to a dedicated folder like `~/ShotsInbox`, and set `--target` to match.

## Verify the Schedule

After the first run, check ShotTTL's own log plus the launchd output paths:

```bash
tail -n 20 ~/.shotttl/logs/shotttl_$(date +%Y%m%d).log
cat /tmp/shotttl.err.log
```

If your screenshots save to Desktop, consider changing the macOS screenshot location to a dedicated screenshot folder before scheduling cleanup.
