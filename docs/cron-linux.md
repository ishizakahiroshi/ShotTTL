# Run ShotTTL with cron on Linux

## Before Scheduling

Run a dry-run first:

```bash
./scripts/unix/shotttl.sh --target "$HOME/Pictures/Screenshots" --keep 24h --dry-run
```

Check the output and the log:

```text
~/.shotttl/logs
```

## Example cron Entry

Open your crontab:

```bash
crontab -e
```

Run ShotTTL every hour:

```cron
0 * * * * /path/to/ShotTTL/scripts/unix/shotttl.sh --target "$HOME/Pictures/Screenshots" --keep 24h --quiet
```

## Trash Mode on Linux

Trash mode requires one of these commands:

- `gio trash`
- `trash-put`
- `kioclient5 move`
- `kioclient move`

If none are available, ShotTTL refuses to fall back to `rm`. Use `--delete` only when you intentionally want permanent deletion.

## cron Environment Notes

cron runs with a minimal environment, which can break trash mode:

- **PATH is short.** cron usually exposes only `/usr/bin:/bin`. If your trash command lives elsewhere, give cron a fuller PATH at the top of the crontab:

  ```cron
  PATH=/usr/local/bin:/usr/bin:/bin
  ```

- **Trash tools need a session.** `gio trash` and `kioclient` talk to your desktop session over D-Bus. Under a plain cron job there is no session, so trash mode can fail. For headless or login-less schedules, either install `trash-put` (works without a session) or use `--delete`.

- **Silence mail.** cron emails any output to the local mailbox. ShotTTL already supports `--quiet`; to drop stray output entirely, redirect it:

  ```cron
  0 * * * * /path/to/ShotTTL/scripts/unix/shotttl.sh --target "$HOME/Pictures/Screenshots" --keep 24h --quiet >/dev/null 2>&1
  ```

## Verify the Schedule

After the first scheduled run, confirm it executed:

```bash
tail -n 20 ~/.shotttl/logs/shotttl_$(date +%Y%m%d).log
```

Each run logs its target, retention, delete mode, candidate count, and any failures.

## Remove the Job

Edit the crontab and delete (or comment out with `#`) the ShotTTL line:

```bash
crontab -e
```
