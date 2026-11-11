param([Parameter(Mandatory = $true)][string]$Root)
$ErrorActionPreference = 'Stop'

$Root = $Root.TrimEnd('\', '/')
$tpl = Join-Path $Root 'models.ini.template'
$out = Join-Path $Root 'models.ini'
if (-not (Test-Path -LiteralPath $tpl)) {
  Write-Host "[ini] MISSING template: $tpl"
  exit 3
}

$fwd = $Root.Replace('\', '/')
$text = [IO.File]::ReadAllText($tpl).Replace('{{ROOT}}', $fwd)
$text = $text.Replace("`r`n", "`n").Replace("`n", "`r`n")
$noBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($out, $text, $noBom)
Write-Host "[ini] models.ini rendered for: $fwd"
