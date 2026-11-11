param([Parameter(Mandatory = $true)][string]$Root)
$ErrorActionPreference = 'Stop'

$Root = $Root.TrimEnd('\', '/')
$cfg = Join-Path $Root 'config.bat'
$noBom = New-Object Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $cfg)) {
  $key = [guid]::NewGuid().ToString('N')
  $lines = @(
    '@echo off',
    'REM  config.bat -- generated on first run. Edit, then restart start-llama.bat.',
    'set PORT=2210',
    ('set API_KEY=' + $key))
  [IO.File]::WriteAllText($cfg, ($lines -join "`r`n") + "`r`n", $noBom)
  Write-Host '[config] config.bat created (fresh random key).'
  Write-Host "[config] port    : 2210"
  Write-Host "[config] API key : $key"
  exit 0
}

$text = [IO.File]::ReadAllText($cfg)
$port = '2210'
$key = ''
if ($text -match '(?m)^set\s+PORT\s*=\s*(\d+)') { $port = $Matches[1] }
if ($text -match '(?m)^set\s+API_KEY\s*=\s*(\S*)') { $key = $Matches[1] }
Write-Host "[config] port    : $port"
if ($key -eq '') {
  Write-Host '[config] API key : (empty - no auth, anyone on this PC can call the API)'
} else {
  Write-Host "[config] API key : $key"
}
