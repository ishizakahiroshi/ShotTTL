# Changelog

All notable changes to ShotTTL are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-06-09

Initial release. Give your screenshots a TTL.

### Added
- Windows cleanup script `scripts/windows/shotttl.ps1` (PowerShell 5.1+).
- macOS / Linux cleanup script `scripts/unix/shotttl.sh` (bash, compatible with macOS bash 3.2).
- `run-hidden.vbs` to run the cleanup on Windows without a visible terminal window.
- Retention by minutes, plus `--keep 30m|1h|24h|7d` on Unix. Default retention: 24 hours.
- Delete modes: `Trash` (default) and `Delete` (permanent, explicit only).
- `--dry-run` / `-DryRun` to preview candidates without removing anything.
- Image-only targeting: `.png .jpg .jpeg .webp .bmp .gif`.
- Safety guards: refuses broad folders (home, Desktop, Downloads, Documents, Pictures);
  skips hidden/system files (Windows) and dotfiles (Unix); subfolders excluded by default;
  on Linux, Trash mode never falls back to `rm`.
- Per-day logs under `%APPDATA%\ShotTTL\logs` (Windows) and `~/.shotttl/logs` (Unix).
- Automation guides for Windows Task Scheduler, Linux cron, and macOS launchd.
- README in English and Japanese, including an AI-agent auto-setup prompt.

[0.1.0]: https://github.com/ishizakahiroshi/ShotTTL/releases/tag/v0.1.0
