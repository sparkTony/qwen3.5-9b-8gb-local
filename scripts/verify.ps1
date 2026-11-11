param(
  [string]$Root = (Split-Path -Parent $PSScriptRoot),
  [string]$Image = '',
  [string]$Profile = 'desktop'
)
$ErrorActionPreference = 'Continue'
$Root = $Root.TrimEnd('\', '/')
$fail = 0
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# HTTP errors from Invoke-RestMethod arrive in the machine's locale and are
# unreadable in a shared script, so report the status code and a hint instead.
function Explain($errorRecord, $port) {
  $resp = $errorRecord.Exception.Response
  try { $code = [int]$resp.StatusCode } catch { $code = 0 }
  if ($code -eq 401) {
    return "401 unauthorized - the key in this pack's config.bat is not the key the running server uses. Restart start-llama.bat from this pack (close the old window first)."
  }
  if ($code -ge 400) { return "HTTP $code" }
  if ($errorRecord.Exception.Message -match 'Unable to connect|could not be resolved|connection refused') {
    return "cannot reach http://127.0.0.1:$port - is start-llama.bat running?"
  }
  return 'network error before any HTTP status'
}

function Step($name, $ok, $detail) {
  if ($ok) { Write-Host ("[PASS] " + $name + $(if ($detail) { '  ' + $detail } else { '' })) }
  else { Write-Host ("[FAIL] " + $name + $(if ($detail) { '  ' + $detail } else { '' })); $script:fail++ }
}

Write-Host ''
Write-Host '=== 1. files and checksums ==='
$manifestPath = Join-Path $Root 'scripts\checksums.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
  Step 'checksums.json present' $false 'run: node scripts\make-checksums.js'
} else {
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  foreach ($entry in $manifest.PSObject.Properties) {
    $rel = $entry.Name
    $want = $entry.Value
    $p = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $p)) { Step $rel $false 'missing'; continue }
    $got = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower()
    Step $rel ($got -eq $want) $(if ($got -ne $want) { "got $got want $want" } else { 'sha256 ok' })
  }
}

Write-Host ''
Write-Host '=== 2. read pack settings ==='
$cfg = Join-Path $Root 'config.bat'
$port = '2210'
$key = ''
if (Test-Path -LiteralPath $cfg) {
  $t = [IO.File]::ReadAllText($cfg)
  if ($t -match '(?m)^set\s+PORT\s*=\s*(\d+)') { $port = $Matches[1] }
  if ($t -match '(?m)^set\s+API_KEY\s*=\s*(\S*)') { $key = $Matches[1] }
  Step 'config.bat' $true "port $port"
} else {
  Step 'config.bat' $false 'not created yet - start start-llama.bat once, or run scripts\ensure-config.ps1'
}
$base = "http://127.0.0.1:$port"
$auth = @{}
if ($key) { $auth['Authorization'] = "Bearer $key" }

Write-Host ''
Write-Host '=== 3. server reachable ==='
try {
  $health = Invoke-RestMethod -Uri "$base/health" -Headers $auth -TimeoutSec 10
  Step 'GET /health' ($health.status -eq 'ok') ("status=" + $health.status)
} catch {
  Step 'GET /health' $false 'server not running? double-click start-llama.bat first'
}

try {
  $models = Invoke-RestMethod -Uri "$base/v1/models" -Headers $auth -TimeoutSec 15
  $text = $models.data | Where-Object { $_.id -eq 'qwen3.5-9b' }
  $vision = $models.data | Where-Object { $_.id -eq 'qwen3-vl-4b' }
  Step 'model qwen3.5-9b registered' ($null -ne $text) ("state=" + $text.status.value)
  Step 'model qwen3-vl-4b registered' ($null -ne $vision) ("state=" + $vision.status.value)
  $mods = $vision.architecture.input_modalities -join ','
  Step 'vision model declares image input' ($mods -match 'image') "modalities=$mods"
} catch {
  Step 'GET /v1/models' $false (Explain $_ $port)
}

Write-Host ''
Write-Host '=== 4. tool call (the part cheap quantizations fail at) ==='
$body = @{
  model    = 'qwen3.5-9b'
  messages = @(@{ role = 'user'; content = 'What is the file size of report.pdf? You must call a tool.' })
  tools    = @(@{
      type     = 'function'
      function = @{
        name        = 'get_file_size'
        description = 'Return the size in bytes of a file on disk'
        parameters  = @{
          type       = 'object'
          properties = @{ path = @{ type = 'string' } }
          required   = @('path')
        }
      }
    })
} | ConvertTo-Json -Depth 8
try {
  $r = Invoke-RestMethod -Uri "$base/v1/chat/completions" -Method Post -Headers $auth `
    -ContentType 'application/json' -Body $body -TimeoutSec 300
  $call = $r.choices[0].message.tool_calls
  $ok = ($r.choices[0].finish_reason -eq 'tool_calls') -and $call -and
    ($call[0].function.name -eq 'get_file_size')
  Step 'finish_reason=tool_calls with a real function name' $ok (
    'finish=' + $r.choices[0].finish_reason + ' name=' + $call[0].function.name +
    ' args=' + $call[0].function.arguments)
} catch {
  Step 'tool call request' $false (Explain $_ $port)
}

Write-Host ''
Write-Host '=== 5. vision through modlens ==='
$modlensBin = Join-Path $env:USERPROFILE (".dsh\profiles\" + $Profile + '\node_modules\.bin\modlens.CMD')
if (-not (Test-Path -LiteralPath $modlensBin)) {
  Step 'modlens CLI found' $false "expected $modlensBin (plugin not installed in profile '$Profile'?)"
} elseif ($Image -and (Test-Path -LiteralPath $Image)) {
  $out = Join-Path $env:TEMP 'pack-vision.json'
  & $modlensBin analyze -i $Image -o $out 2>&1 | Out-Null
  if (Test-Path -LiteralPath $out) {
    $j = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
    Step 'modlens analyze returned structured evidence' ($null -ne $j.result.summary) (
      'summary=' + $j.result.summary.Substring(0, [Math]::Min(60, $j.result.summary.Length)))
  } else {
    Step 'modlens analyze' $false 'no output file - is the server running? check: modlens doctor'
  }
} else {
  Write-Host '[skip] pass -Image <path.png> to test one real read'
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL CHECKS PASSED' } else { Write-Host "$fail check(s) FAILED" }
exit $fail
