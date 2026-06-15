# Run ShotTTL with Windows Task Scheduler

This guide runs ShotTTL without showing a PowerShell console window by using `run-hidden.vbs`.

## Before Scheduling

Run a dry-run first:

```powershell
.\scripts\windows\shotttl.ps1 -RetentionMinutes 60 -DryRun
```

Check the output and the log:

```text
%APPDATA%\ShotTTL\logs
```

## Create the Task

1. Open Task Scheduler.
2. Select **Create Basic Task** or **Create Task**.
3. Choose a trigger, such as daily or at logon.
4. Choose **Start a program**.
5. Set **Program/script** to:

```text
wscript.exe
```

6. Set **Add arguments** to the full path of `run-hidden.vbs`:

```text
"C:\path\to\ShotTTL\scripts\windows\run-hidden.vbs"
```

You can add ShotTTL options after the VBS path:

```text
"C:\path\to\ShotTTL\scripts\windows\run-hidden.vbs" -RetentionMinutes 60
```

7. Save the task.

## Customize Arguments

Pass the same options you would pass to `shotttl.ps1`, after the VBS path:

```text
"C:\path\to\ShotTTL\scripts\windows\run-hidden.vbs" -TargetDir "C:\Users\you\Pictures\Screenshots" -RetentionMinutes 1440
```

Use `-DeleteMode Delete` only when you intentionally want permanent deletion.

Notes:

- `run-hidden.vbs` always runs ShotTTL with `-Quiet` and no visible window, so there is no on-screen output even for `-DryRun`. To preview candidates interactively, run `shotttl.ps1` directly with `-DryRun` (see **Before Scheduling** above) and inspect `%APPDATA%\ShotTTL\logs`.
- Inside quoted paths, do not include a trailing backslash (e.g. avoid `"...Screenshots\"`). Windows treats `\"` as an escaped quote, which can fold the next argument into the value. Use `"...Screenshots"` without a trailing slash.
