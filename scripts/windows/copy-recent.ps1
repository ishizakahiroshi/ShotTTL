# Internal copy-mode entry point, called after shotttl.ps1 validates the source.
param([string]$Source, [string]$Destination, [int]$Minutes, [datetime]$Since,
      [switch]$Watch, [switch]$Preview)

$ErrorActionPreference = 'Stop'
$Destination = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
if ($Destination -eq $Source.TrimEnd('\') -or $Destination -eq [IO.Path]::GetPathRoot($Destination).TrimEnd('\')) {
    throw 'Choose a dedicated destination folder, distinct from the source and drive root.'
}

function Publish-Image($File, $Final, $CutoffMinutes) {
    # Deny concurrent writers; release a complete copy under its final name only.
    $temp = Join-Path $Destination ('.shotttl-' + [guid]::NewGuid().ToString('N') + '.part')
    $inputFile = [IO.File]::Open($File.FullName, 'Open', 'Read', 'Read')
    try {
        if ($inputFile.Length -ne $File.Length -or [IO.File]::GetLastWriteTimeUtc($File.FullName) -ne $File.LastWriteTimeUtc) { return $false }
        $outputFile = [IO.File]::Open($temp, 'CreateNew', 'Write', 'None')
        try { $inputFile.CopyTo($outputFile) } finally { $outputFile.Dispose() }
        if ($File.LastWriteTimeUtc -le [datetime]::UtcNow.AddMinutes(-$CutoffMinutes)) { return $false }
        [IO.File]::SetLastWriteTimeUtc($temp, $File.LastWriteTimeUtc)
        try { [IO.File]::Move($temp, $Final) } catch [IO.IOException] {
            if (-not [IO.File]::Exists($Final)) { throw }
        }
        return $true
    } finally {
        $inputFile.Dispose()
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

$published = @{}
$lastError = ''
$hash = [Security.Cryptography.SHA256]::Create()
try {
    do {
        $now = [datetime]::UtcNow
        $cutoff = $now.AddMinutes(-$Minutes)
        foreach ($key in @($published.Keys)) {
            if ($published[$key] -le $cutoff) { $published.Remove($key) }
        }
        try {
            if (-not [IO.Directory]::Exists($Destination)) { throw 'Copy destination unavailable.' }
            foreach ($file in Get-ChildItem -LiteralPath $Source -File) {
                if ($file.LastWriteTimeUtc -lt $Since -or $file.LastWriteTimeUtc -le $cutoff -or ($Watch -and -not $Preview -and $file.LastWriteTimeUtc -gt $now.AddSeconds(-1))) { continue }
                if ($file.Extension -notin '.png','.jpg','.jpeg','.webp','.bmp','.gif' -or $file.Name.StartsWith('shotttl-') -or
                    ($file.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::ReparsePoint))) { continue }
                $stamp = $file.LastWriteTimeUtc.ToString("yyyyMMdd'T'HHmmssfffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
                $identity = [Text.Encoding]::UTF8.GetBytes("$($file.FullName)|$($file.Length)")
                $digest = [BitConverter]::ToString($hash.ComputeHash($identity)).Replace('-','').Substring(0,24)
                $name = 'shotttl-' + $stamp + '-' + $digest + $file.Extension.ToLowerInvariant()
                if ($published.ContainsKey($name)) { continue }
                $final = Join-Path $Destination $name
                if (-not [IO.File]::Exists($final)) {
                    if ($Preview) { Write-Output "Would copy: $($file.Name) -> $final"; continue }
                    try {
                        if (-not (Publish-Image $file $final $Minutes)) { continue }
                    } catch [IO.IOException] {
                        if (-not $Watch) { throw }
                        continue
                    }
                }
                $published[$name] = $file.LastWriteTimeUtc
            }
            $lastError = ''
        } catch {
            if (-not $Watch -or $Preview) { throw }
            if ($_.Exception.Message -ne $lastError) {
                $lastError = $_.Exception.Message
                Write-Log "Copy watch will retry: $lastError" 'WARN'
            }
        }
        if ($Watch -and -not $Preview) { Start-Sleep -Seconds 2 }
    } while ($Watch -and -not $Preview)
} finally { $hash.Dispose() }
