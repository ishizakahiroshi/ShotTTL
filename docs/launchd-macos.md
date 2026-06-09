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

Recent macOS releases gate access to folders like `~/Pictures` behind privacy controls (TCC). If the job logs no candidates even though old screenshots exist, grant the agent that runs ShotTTL — usually `/bin/bash` or your terminal — **Full Disk Access** under System Settings → Privacy & Security, then reload the LaunchAgent.

## Verify the Schedule

After the first run, check ShotTTL's own log plus the launchd output paths:

```bash
tail -n 20 ~/.shotttl/logs/shotttl_$(date +%Y%m%d).log
cat /tmp/shotttl.err.log
```

If your screenshots save to Desktop, consider changing the macOS screenshot location to a dedicated screenshot folder before scheduling cleanup.
