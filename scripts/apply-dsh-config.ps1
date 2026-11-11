param(
  [string]$Root = (Split-Path -Parent $PSScriptRoot),
  [string]$Profile = 'desktop',
  [string]$DshHome = (Join-Path $env:USERPROFILE '.dsh'),
  [switch]$DryRun,
  [switch]$ForceDirect
)
$ErrorActionPreference = 'Stop'
$Root = $Root.TrimEnd('\', '/')

Write-Host ''
Write-Host '=== dsh-local-pack: configure DeepSeek Harness + modlens ==='

# ---- 1. read the pack's own settings ---------------------------------------
$cfg = Join-Path $Root 'config.bat'
if (-not (Test-Path -LiteralPath $cfg)) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\ensure-config.ps1') -Root $Root
}
$text = [IO.File]::ReadAllText($cfg)
$port = '2210'
$key = ''
if ($text -match '(?m)^set\s+PORT\s*=\s*(\d+)') { $port = $Matches[1] }
if ($text -match '(?m)^set\s+API_KEY\s*=\s*(\S*)') { $key = $Matches[1] }
Write-Host "[pack] port $port, api key $(if ($key) { $key } else { '(none - auth off)' })"

# ---- 2. locate the dsh profile --------------------------------------------
$profileDir = Join-Path $DshHome ("profiles\" + $Profile)
if (-not (Test-Path -LiteralPath $profileDir)) {
  Write-Host "[FAIL] profile dir not found: $profileDir"
  Write-Host '       list what exists:'
  Get-ChildItem (Join-Path $DshHome 'profiles') -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host ('       ' + $_.Name) }
  exit 3
}
Write-Host "[dsh]  profile $profileDir"

# ---- 3. patch cordis.patch.yml --------------------------------------------
$node = (Get-Command node.exe -ErrorAction SilentlyContinue)
if (-not $node) {
  Write-Host '[FAIL] node.exe not on PATH. Install Node 22.19+ first (modlens needs it anyway).'
  exit 4
}
$mergeArgs = @((Join-Path $Root 'scripts\merge-cordis.js'), '--profile-dir', $profileDir, '--port', $port)
if ($DryRun) { $mergeArgs += '--dry-run' }
Write-Host ''
& node.exe @mergeArgs
$mergeExit = $LASTEXITCODE

# ---- 4. point modlens at the local vision model ---------------------------
Write-Host ''

# Writing a key the running server does not know is the easiest way to break a
# working setup, so check the live endpoint before touching modlens.
$probe = $null
try {
  $headers = @{}
  if ($key) { $headers['Authorization'] = "Bearer $key" }
  Invoke-RestMethod -Uri "http://127.0.0.1:$port/v1/models" -Headers $headers -TimeoutSec 10 | Out-Null
  Write-Host "[check] http://127.0.0.1:$port accepts this pack's key"
} catch {
  $resp = $null
  try { $resp = [int]$_.Exception.Response.StatusCode } catch { }
  if ($resp -eq 401) {
    Write-Host "[WARN] a server answers on port $port but rejects this key."
    Write-Host '       It is almost certainly another launcher (a different LLAMA_HOME), not this pack.'
    Write-Host '       Close that window and double-click this pack''s start-llama.bat, then rerun me.'
    exit 7
  }
  Write-Host "[WARN] nothing reachable on port $port. Start start-llama.bat first -"
  Write-Host '       writing modlens config now would point it at a dead endpoint.'
  exit 7
}

$baseUrl = "http://127.0.0.1:$port/v1"
$modlensBin = Join-Path $profileDir 'node_modules\.bin\modlens.CMD'
if (Test-Path -LiteralPath $modlensBin) {
  Write-Host '[modlens] using the plugin CLI to write config'
  if (-not $DryRun) {
    & $modlensBin config set provider openai | Out-Null
    & $modlensBin config set openai.baseUrl $baseUrl | Out-Null
    & $modlensBin config set openai.model qwen3-vl-4b | Out-Null
    if ($key) { $key | & $modlensBin config set openai.apiKey | Out-Null }
  }
} else {
  Write-Host '[modlens] CLI not found in this profile; patching ~/.modlens/config.json directly'
  Write-Host '          (install the plugin first: npx -y @deepseek-ai/dsh plugin --profile ' +
    "$Profile add @liustack/modlens)"
  if (-not $DryRun) {
    $js = @'
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const [baseUrl, model, key] = process.argv.slice(2);
const dir = path.join(os.homedir(), '.modlens');
const file = path.join(dir, 'config.json');
let cfg = {};
if (fs.existsSync(file)) { try { cfg = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { cfg = {}; } }
cfg.provider = 'openai';
cfg.providers = Object.assign({}, cfg.providers);
const openai = Object.assign({}, cfg.providers.openai);
openai.baseUrl = baseUrl;
openai.model = model;
if (key) openai.apiKey = key;
cfg.providers.openai = openai;
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + '\n');
console.log('[modlens] wrote ' + file);
'@
    $jsFile = Join-Path $env:TEMP 'modlens-patch.js'
    [IO.File]::WriteAllText($jsFile, $js)
    & node.exe $jsFile $baseUrl 'qwen3-vl-4b' $key
  }
}

# ---- 5. proxy mode for the local endpoint ---------------------------------
# An empty openai.proxy means "never use a proxy"; a missing field means
# "inherit HTTPS_PROXY / HTTP_PROXY", and that route honours NO_PROXY.
$proxyJs = @'
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const [mode] = process.argv.slice(2);
const file = path.join(os.homedir(), '.modlens', 'config.json');
if (!fs.existsSync(file)) {
  console.log('[modlens] no config file yet, nothing to do');
  process.exit(0);
}
const cfg = JSON.parse(fs.readFileSync(file, 'utf8'));
const openai = Object.assign({}, (cfg.providers && cfg.providers.openai) || {});
if (mode === 'direct') openai.proxy = '';
else delete openai.proxy;
cfg.providers = Object.assign({}, cfg.providers, { openai });
fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + '\n');
console.log(
  mode === 'direct'
    ? "[modlens] openai.proxy = '' (forced direct)"
    : '[modlens] openai.proxy removed (follows system proxy; NO_PROXY still applies)',
);
'@
$proxyJsFile = Join-Path $env:TEMP 'modlens-proxy-mode.js'
[IO.File]::WriteAllText($proxyJsFile, $proxyJs)
if ($DryRun) {
  Write-Host "[modlens] dry run: proxy mode would be $(if ($ForceDirect) { 'direct' } else { 'inherit' })"
} else {
  & node.exe $proxyJsFile $(if ($ForceDirect) { 'direct' } else { 'inherit' })
}

# ---- 6. next steps --------------------------------------------------------
Write-Host ''
Write-Host '=== next steps ==='
Write-Host '  1) double-click start-llama.bat and wait for "listening on"'
if ($key) { Write-Host "  2) dsh Settings -> model -> fill API key: $key" }
Write-Host '  3) fully quit dsh and reopen it (config is read at startup only)'
Write-Host '  4) in the model picker choose the entry ending in "(modlens vision)"'
Write-Host '  5) run scripts\verify.ps1 to check the whole chain'
if (-not $ForceDirect) {
  Write-Host '     vision fails with a proxy error? your proxy must list 127.0.0.1 in NO_PROXY,'
  Write-Host '     or rerun me with -ForceDirect.'
}
if ($mergeExit -ne 0) {
  Write-Host ''
  Write-Host "  NOTE: cordis.patch.yml still has entries to fix by hand (exit $mergeExit)."
}
exit $mergeExit
