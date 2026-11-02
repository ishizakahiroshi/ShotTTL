[CmdletBinding()]
param(
    [string]$SourcePath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/windows/shotttl.ps1'),
    [switch]$RunEntryProbe,
    [string]$TargetDir,
    [string]$CandidateMarker
)
$ErrorActionPreference='Stop'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($SourcePath,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Product PowerShell syntax error'}
foreach($fn in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){Invoke-Expression $fn.Extent.Text}

if($RunEntryProbe){
    # Exercise the real entry-point guard with dry-run enabled, but replace all
    # logging and candidate enumeration. No user home/log/trash/task is touched.
    $DryRun=$true;$Quiet=$true;$RetentionMinutes=1440;$DeleteMode='Trash'
    $IncludeSubfolders=$false;$CreateTargetIfMissing=$false
    function Write-Log { param($Message,$Level) }
    function Write-StderrLine { param($Message) }
    function Get-CleanupCandidates {
        param($Path,$Minutes,[switch]$Recurse)
        [IO.File]::WriteAllText($CandidateMarker,'candidate enumeration reached')
        return @()
    }
    $main=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[-1]
    Invoke-Expression $main.Extent.Text
    throw 'Product entry point unexpectedly returned without exit'
}

$fixture=Join-Path ([IO.Path]::GetTempPath()) ('shotttl-target-boundaries-'+[guid]::NewGuid().ToString('N'))
$plain=Join-Path $fixture 'plain';$outside=Join-Path $fixture 'outside'
$screenshots=Join-Path $outside 'screenshots'
$null=New-Item -ItemType Directory -Path $plain,$screenshots -Force
$sentinel=Join-Path $screenshots 'old.png';[IO.File]::WriteAllText($sentinel,'synthetic outside image')
[IO.File]::SetLastWriteTime($sentinel,[datetime]::Now.AddDays(-7))
$hash=(Get-FileHash -LiteralPath $sentinel).Hash
$parentLink=Join-Path $fixture 'parent-link';$leafLink=Join-Path $fixture 'leaf-link'
$null=New-Item -ItemType Junction -Path $parentLink -Target $outside
$null=New-Item -ItemType Junction -Path $leafLink -Target $screenshots
$checks=0;$failures=0
$savedProfile=$env:USERPROFILE
$env:USERPROFILE=Join-Path $fixture 'synthetic-profile'
function Check([string]$Name,[bool]$Condition){
    if($Condition){$script:checks++;Write-Host "PASS $Name"}
    else{$script:failures++;Write-Host "FAIL $Name"}
}
try{
    $aliased=Join-Path $parentLink 'screenshots'
    Check 'plain target allowed' (-not(Test-UnsafeTargetDir $plain))
    Check 'drive root refused' (Test-UnsafeTargetDir ([IO.Path]::GetPathRoot($fixture)))
    Check 'leaf junction refused' (Test-UnsafeTargetDir $leafLink)
    Check 'ancestor junction refused' (Test-UnsafeTargetDir $aliased)
    Check 'missing child under ancestor junction refused' (Test-UnsafeTargetDir (Join-Path $aliased 'missing'))
    $marker=Join-Path $fixture 'candidate-marker.txt'
    $null=& pwsh -NoProfile -File $PSCommandPath -SourcePath $SourcePath -RunEntryProbe -TargetDir $aliased -CandidateMarker $marker
    $code=$LASTEXITCODE
    Check 'dry-run refuses before candidate enumeration' ($code -eq 1 -and -not(Test-Path -LiteralPath $marker))
    Check 'outside sentinel unchanged' ((Get-FileHash -LiteralPath $sentinel).Hash -eq $hash)
}finally{
    # Unlink only fixture junction entries; keep synthetic payload for review.
    [IO.Directory]::Delete($leafLink,$false);[IO.Directory]::Delete($parentLink,$false)
    $env:USERPROFILE=$savedProfile
}
Write-Host "RESULT: $checks passed, $failures failed"
if($failures){exit 1}
