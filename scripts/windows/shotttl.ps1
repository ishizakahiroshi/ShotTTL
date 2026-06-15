[CmdletBinding()]
param(
    [string]$TargetDir = "",

    [ValidateRange(1, 525600)]
    [int]$RetentionMinutes = 1440,

    [ValidateSet("Trash", "Delete")]
    [string]$DeleteMode = "Trash",

    [switch]$DryRun,

    [switch]$IncludeSubfolders,

    [switch]$Quiet,

    [switch]$CreateTargetIfMissing,

    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$Script:LogFile = $null

function Show-Help {
    @'
ShotTTL - Give your screenshots a TTL.

Usage:
  .\shotttl.ps1 [-TargetDir PATH] [-RetentionMinutes MINUTES] [-DeleteMode Trash|Delete] [-DryRun]

Options:
  -TargetDir PATH           Screenshot folder to clean. Auto-detected when omitted.
  -RetentionMinutes MIN     Keep files modified within this many minutes. Default: 1440.
  -DeleteMode MODE          Trash or Delete. Default: Trash.
  -DryRun                   Show what would be removed without changing files.
  -IncludeSubfolders        Include files in child folders. Default: off.
  -Quiet                    Reduce console output. Logs are still written.
  -CreateTargetIfMissing    Create the target folder when it does not exist.
  -Help                     Show this help.

Examples:
  .\shotttl.ps1 -RetentionMinutes 60 -DryRun
  .\shotttl.ps1 -TargetDir "$env:USERPROFILE\Pictures\Screenshots" -RetentionMinutes 1440
  .\shotttl.ps1 -TargetDir "$env:TEMP\shotttl-test" -RetentionMinutes 1440 -DeleteMode Delete
'@
}

function Get-LogFile {
    if ($Script:LogFile) {
        return $Script:LogFile
    }

    $baseDir = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($baseDir)) {
        $baseDir = Join-Path $HOME ".shotttl"
    }

    $logDir = Join-Path $baseDir "ShotTTL\logs"
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $Script:LogFile = Join-Path $logDir ("shotttl_{0}.log" -f (Get-Date -Format "yyyyMMdd"))
    return $Script:LogFile
}

$Script:LogEncoding = New-Object System.Text.UTF8Encoding($false)

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$Level = "INFO"
    )

    try {
        # 改行・タブ・C0/DEL 制御文字を空白へ正規化してログ 1 行性を保つ。
        $sanitized = ($Message -replace '[\x00-\x1F\x7F]+', ' ')
        $line = "{0} [{1}] {2}{3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $sanitized, [Environment]::NewLine
        [System.IO.File]::AppendAllText((Get-LogFile), $line, $Script:LogEncoding)
    }
    catch {
        if (-not $Quiet) {
            Write-Warning ("Failed to write log: {0}" -f $_.Exception.Message)
        }
    }
}

function Write-OutputLine {
    param([string]$Message)

    if (-not $Quiet) {
        Write-Host $Message
    }
}

function Write-StderrLine {
    param([string]$Message)

    [Console]::Error.WriteLine($Message)
}

function Convert-ToFullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    }
    catch {
        return [System.IO.Path]::GetFullPath($Path)
    }
}

function ConvertTo-NormalizedPath {
    # 比較用にパスを正規化する。存在するパスは Get-Item.FullName で 8.3 短縮名を
    # 長名へ展開し、denylist/allowlist の文字列一致回避を塞ぐ。
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $full = Convert-ToFullPath -Path $Path

    try {
        if (Test-Path -LiteralPath $full) {
            $full = (Get-Item -LiteralPath $full -Force -ErrorAction Stop).FullName
        }
        else {
            $parent = [System.IO.Path]::GetDirectoryName($full)
            if (-not [string]::IsNullOrWhiteSpace($parent) -and (Test-Path -LiteralPath $parent)) {
                $parentFull = (Get-Item -LiteralPath $parent -Force -ErrorAction Stop).FullName
                $leaf = [System.IO.Path]::GetFileName($full)
                if (-not [string]::IsNullOrWhiteSpace($leaf)) {
                    $full = Join-Path -Path $parentFull -ChildPath $leaf
                }
                else {
                    $full = $parentFull
                }
            }
        }
    }
    catch {
        # 解決失敗時は元の絶対パスのまま比較に進める（安全側で素通しは増えない）
    }

    [char[]]$trimChars = @([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $trimmed = $full.TrimEnd($trimChars)
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $full.ToLowerInvariant()
    }

    return $trimmed.ToLowerInvariant()
}

function Get-AllowedScreenshotDirs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserProfile
    )

    return @(
        (Join-Path $UserProfile "OneDrive\Pictures\Screenshots"),
        (Join-Path $UserProfile "Pictures\Screenshots"),
        (Join-Path $UserProfile "Desktop\Screenshots"),
        (Join-Path $UserProfile ".claude\screenshots")
    )
}

function Get-DefaultTargetDir {
    $userProfile = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($userProfile)) {
        $userProfile = $HOME
    }

    $candidates = Get-AllowedScreenshotDirs -UserProfile $userProfile

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            try {
                $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    continue
                }
            }
            catch {
                continue
            }
            return $candidate
        }
    }

    return (Join-Path $userProfile "Pictures\Screenshots")
}

function Test-UnsafeTargetDir {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $true
    }

    # UNC は現行用途（ローカルスクショ専用）の対象外なので一律拒否する。
    if ($Path -match '^(\\\\|//)') {
        return $true
    }

    # TargetDir 自身が ReparsePoint (junction / symbolic link) の場合は許可リストの
    # 文字列一致を経由した実体ディレクトリのバイパスが起きるので無条件で拒否する。
    try {
        if (Test-Path -LiteralPath $Path) {
            $targetItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if (($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $true
            }
        }
    }
    catch {
        # 解決失敗時は後段で再評価する（破壊的に倒さない）。
    }

    $normalized = ConvertTo-NormalizedPath -Path $Path
    $root = [System.IO.Path]::GetPathRoot((Convert-ToFullPath -Path $Path))
    if (-not [string]::IsNullOrWhiteSpace($root)) {
        $normalizedRoot = ConvertTo-NormalizedPath -Path $root
        if ($normalized -eq $normalizedRoot) {
            return $true
        }
    }

    $userProfile = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($userProfile)) {
        $userProfile = $HOME
    }

    $allowed = Get-AllowedScreenshotDirs -UserProfile $userProfile |
        ForEach-Object { ConvertTo-NormalizedPath -Path $_ }

    if ($allowed -contains $normalized) {
        return $false
    }

    # USERPROFILE itself is refused only as an exact match. AppData / Temp /
    # other tooling under %USERPROFILE% must remain reachable as user-supplied
    # targets (the Help example uses %TEMP%\shotttl-test).
    $normalizedUserProfile = ConvertTo-NormalizedPath -Path $userProfile
    if (-not [string]::IsNullOrWhiteSpace($normalizedUserProfile) -and $normalized -eq $normalizedUserProfile) {
        return $true
    }

    # The well-known shell folders Desktop / Downloads / Documents / Pictures
    # are refused both exactly and for any subfolder (path-prefix), so a
    # mistyped or coerced target like "%USERPROFILE%\Documents\Reports" is
    # rejected before any deletion happens.
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $unsafeSubtrees = @(
        (Join-Path $userProfile "Desktop"),
        (Join-Path $userProfile "Downloads"),
        (Join-Path $userProfile "Documents"),
        (Join-Path $userProfile "Pictures")
    ) | ForEach-Object { ConvertTo-NormalizedPath -Path $_ }

    foreach ($u in $unsafeSubtrees) {
        if ([string]::IsNullOrWhiteSpace($u)) {
            continue
        }
        if ($normalized -eq $u -or $normalized.StartsWith($u + $separator)) {
            return $true
        }
    }

    return $false
}

function Format-Bytes {
    param([Int64]$Bytes)

    if ($Bytes -ge 1GB) {
        return ("{0:N1} GB" -f ($Bytes / 1GB))
    }
    if ($Bytes -ge 1MB) {
        return ("{0:N1} MB" -f ($Bytes / 1MB))
    }
    if ($Bytes -ge 1KB) {
        return ("{0:N1} KB" -f ($Bytes / 1KB))
    }

    return ("{0} B" -f $Bytes)
}

function Get-CleanupCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$Minutes,

        [switch]$Recurse
    )

    $limit = (Get-Date).AddMinutes(-1 * $Minutes)
    $extensions = @(".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif")

    $params = @{
        LiteralPath = $Path
        File = $true
        ErrorAction = "Stop"
    }

    if ($Recurse) {
        $params["Recurse"] = $true
    }

    Get-ChildItem @params | Where-Object {
        $attributes = $_.Attributes
        $isHidden = (($attributes -band [System.IO.FileAttributes]::Hidden) -ne 0)
        $isSystem = (($attributes -band [System.IO.FileAttributes]::System) -ne 0)
        $isReparsePoint = (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        $extension = $_.Extension.ToLowerInvariant()

        (-not $isHidden) -and
            (-not $isSystem) -and
            (-not $isReparsePoint) -and
            ($extensions -contains $extension) -and
            ($_.LastWriteTime -lt $limit)
    }
}

function Move-ToTrash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Add-Type -AssemblyName Microsoft.VisualBasic

    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
        $Path,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
    )
}

function Remove-OldImages {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Candidates,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [switch]$PreviewOnly
    )

    $result = [PSCustomObject]@{
        Deleted = 0
        Failed = 0
        FreedBytes = [Int64]0
        WouldFreeBytes = [Int64]0
    }

    foreach ($file in $Candidates) {
        $path = $file.FullName
        $size = [Int64]$file.Length

        if ($PreviewOnly) {
            $result.WouldFreeBytes += $size
            Write-Log ("DRY-RUN candidate: {0} ({1})" -f $path, (Format-Bytes $size))
            Write-OutputLine ("Would remove: {0}" -f $path)
            continue
        }

        try {
            if ($Mode -eq "Trash") {
                Move-ToTrash -Path $path
            }
            else {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            }

            $result.Deleted += 1
            $result.FreedBytes += $size
            Write-Log ("Removed via {0}: {1} ({2})" -f $Mode, $path, (Format-Bytes $size))
        }
        catch {
            $result.Failed += 1
            Write-Log ("Failed to remove {0}: {1}" -f $path, $_.Exception.Message) "ERROR"
            Write-OutputLine ("Failed: {0} ({1})" -f $path, $_.Exception.Message)
        }
    }

    return $result
}

if ($Help) {
    Show-Help
    exit 0
}

try {
    if ([string]::IsNullOrWhiteSpace($TargetDir)) {
        $TargetDir = Get-DefaultTargetDir
    }

    $TargetDir = Convert-ToFullPath -Path $TargetDir

    if (Test-UnsafeTargetDir -Path $TargetDir) {
        Write-Log ("Refusing unsafe target directory: {0}" -f $TargetDir) "ERROR"
        Write-StderrLine ("ShotTTL refuses to clean this broad or unsafe target: {0}" -f $TargetDir)
        exit 1
    }

    if (-not (Test-Path -LiteralPath $TargetDir -PathType Container)) {
        if ($CreateTargetIfMissing) {
            New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
            Write-Log ("Created missing target directory: {0}" -f $TargetDir)
        }
        else {
            Write-Log ("Target directory does not exist: {0}" -f $TargetDir) "ERROR"
            Write-StderrLine ("Target directory does not exist: {0}. Use -CreateTargetIfMissing to create it." -f $TargetDir)
            exit 1
        }
    }

    Write-Log ("Run started. Target={0}; RetentionMinutes={1}; DeleteMode={2}; DryRun={3}; IncludeSubfolders={4}" -f $TargetDir, $RetentionMinutes, $DeleteMode, [bool]$DryRun, [bool]$IncludeSubfolders)

    $candidates = @(Get-CleanupCandidates -Path $TargetDir -Minutes $RetentionMinutes -Recurse:$IncludeSubfolders)
    $result = Remove-OldImages -Candidates $candidates -Mode $DeleteMode -PreviewOnly:$DryRun

    if ($DryRun) {
        Write-Log ("Dry-run completed. Candidates={0}; WouldFree={1}" -f $candidates.Count, (Format-Bytes $result.WouldFreeBytes))
        Write-OutputLine "ShotTTL dry-run completed."
        Write-OutputLine ("Target: {0}" -f $TargetDir)
        Write-OutputLine ("Candidates: {0}" -f $candidates.Count)
        Write-OutputLine ("Would free: {0}" -f (Format-Bytes $result.WouldFreeBytes))
        Write-OutputLine "No files were deleted."
        Write-OutputLine ("Mode: {0}" -f $DeleteMode)
    }
    else {
        Write-Log ("Cleanup completed. Candidates={0}; Deleted={1}; Failed={2}; Freed={3}; Mode={4}" -f $candidates.Count, $result.Deleted, $result.Failed, (Format-Bytes $result.FreedBytes), $DeleteMode)
        Write-OutputLine "ShotTTL cleanup completed."
        Write-OutputLine ("Target: {0}" -f $TargetDir)
        Write-OutputLine ("Candidates: {0}" -f $candidates.Count)
        Write-OutputLine ("Deleted: {0}" -f $result.Deleted)
        Write-OutputLine ("Failed: {0}" -f $result.Failed)
        Write-OutputLine ("Freed: {0}" -f (Format-Bytes $result.FreedBytes))
        Write-OutputLine ("Mode: {0}" -f $DeleteMode)
    }

    if ($result.Failed -gt 0) {
        exit 1
    }

    exit 0
}
catch {
    Write-Log ("Fatal error: {0}" -f $_.Exception.Message) "ERROR"
    Write-StderrLine $_.Exception.Message
    exit 1
}
