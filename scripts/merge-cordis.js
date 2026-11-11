// Detect what cordis.patch.yml is missing and append only whole entries that
// do not exist yet. Never rewrites an existing entry: if an id is already
// present but configured differently, it prints the exact lines to edit by hand.
const fs = require('node:fs')
const path = require('node:path')

const argv = process.argv.slice(2)
const arg = (name, fallback) => {
  const i = argv.indexOf('--' + name)
  return i === -1 || i + 1 >= argv.length ? fallback : argv[i + 1]
}
const has = (name) => argv.includes('--' + name)

const profileDir = path.resolve(arg('profile-dir', ''))
if (!profileDir) {
  console.error('usage: node merge-cordis.js --profile-dir <dir> [--port 2210] [--dry-run]')
  process.exit(2)
}

let yaml
try {
  yaml = require(path.join(profileDir, 'node_modules', 'js-yaml'))
} catch (error) {
  console.error('FAIL cannot load js-yaml from this profile: ' + error.message)
  console.error('     hint: install any plugin into the profile first (it brings js-yaml)')
  process.exit(4)
}

const port = arg('port', '2210')
const providerId = 'localqwen'
const modelId = 'qwen3.5-9b'
// Must match ctx-size in models.ini.template. llama.cpp does not disclose the
// window through /v1/models, so dsh has to be told here or it assumes 1M and
// its compaction threshold never fires.
const ctxTokens = 65536
// Output budget per request. 4096 is far too small for agent work: measured on
// this card, the model writes about 1000 lines (6600-7200 tokens) in a single
// write call whether or not it was told to split. Anything that overflows gets
// cut mid-JSON, and a truncated tool call is neither executed nor replayed - so
// "continue" restarts the same giant write and loops forever. 12288 leaves ~70%
// headroom over that natural write size. Cost: worst case ~3.7 min per call at
// the measured ~55 tok/s. Thinking is left unrestricted (reasoning-budget -1),
// so reasoning tokens also come out of this budget.
const outTokens = 12288
// Vision twin on the same provider: without its own card dsh assumes 1M for it too.
const visionId = 'qwen3-vl-4b'
const visionCtx = 32768
const visionOut = 1024
const families = ['deepseek', 'glm', 'mimo', 'ling', 'qwen']

const file = path.join(profileDir, 'cordis.patch.yml')
let entries = []
if (fs.existsSync(file)) {
  const loaded = yaml.load(fs.readFileSync(file, 'utf8'))
  if (loaded === null || loaded === undefined) {
    entries = []
  } else if (!Array.isArray(loaded) || loaded.some((e) => e === null || typeof e !== 'object' || Array.isArray(e))) {
    console.error('FAIL cordis.patch.yml is not a top-level list of entries; refusing to touch it.')
    console.error('     open it by hand and add the entries shown in the README.')
    process.exit(5)
  } else {
    entries = loaded
  }
} else {
  console.log('note: cordis.patch.yml does not exist yet, it will be created')
}

const find = (id) => entries.filter((e) => e && e.id === id)
const wanted = []
const conflicts = []
const ok = []

// 1. provider registration
const llm = find('llm-pi-ai')
if (llm.length === 0) {
  wanted.push(
    [
      `- id: llm-pi-ai`,
      `  name: "@deepseek-ai/dsh-llm-pi-ai"`,
      `  config:`,
      `    providers:`,
      `      ${providerId}:`,
      `        displayName: Qwen3.5-9B local (llama.cpp)`,
      `        apiKeyEnv: LOCALQWEN_API_KEY`,
      `        api: openai-completions`,
      `        baseURL: http://127.0.0.1:${port}/v1`,
      `        models:`,
      `          - id: ${modelId}`,
      `            contextWindow: ${ctxTokens}`,
      `            maxTokens: ${outTokens}`,
      `          - id: ${visionId}`,
      `            contextWindow: ${visionCtx}`,
      `            maxTokens: ${visionOut}`,
    ].join('\n'),
  )
} else {
  const providers = (llm[0].config && llm[0].config.providers) || {}
  const mine = providers && providers[providerId]
  const want = `http://127.0.0.1:${port}/v1`
  if (!mine) {
    conflicts.push(
      [
        `an "llm-pi-ai" entry already exists but has no "${providerId}" provider.`,
        `add under its config.providers:`,
        `      ${providerId}:`,
        `        displayName: Qwen3.5-9B local (llama.cpp)`,
        `        apiKeyEnv: LOCALQWEN_API_KEY`,
        `        api: openai-completions`,
        `        baseURL: ${want}`,
        `        models:`,
        `          - id: ${modelId}`,
        `            contextWindow: ${ctxTokens}`,
        `            maxTokens: ${outTokens}`,
        `          - id: ${visionId}`,
        `            contextWindow: ${visionCtx}`,
        `            maxTokens: ${visionOut}`,
      ].join('\n'),
    )
  } else if (String(mine.baseURL) !== want) {
    conflicts.push(
      `"${providerId}" exists with baseURL ${mine.baseURL}, expected ${want}. Edit that line.`,
    )
  } else {
    ok.push(`provider ${providerId} -> ${want}`)
    const cards = Array.isArray(mine.models) ? mine.models : []
    for (const want2 of [
      { id: modelId, ctx: ctxTokens },
      { id: visionId, ctx: visionCtx },
    ]) {
      const card = cards.find((m) => m && m.id === want2.id)
      if (!card) {
        conflicts.push(
          `"${providerId}" has no "${want2.id}" model card; add it with contextWindow ${want2.ctx}.`,
        )
      } else if (card.contextWindow !== want2.ctx) {
        conflicts.push(
          `model ${want2.id} declares contextWindow ${JSON.stringify(card.contextWindow)}, expected ` +
            `${want2.ctx}. Without it dsh assumes a 1M window and never compacts. Edit that line.`,
        )
      } else {
        ok.push(`model ${want2.id} contextWindow = ${want2.ctx}`)
      }
    }
  }
}

// 2. default model
const def = find('agent-default-model')
if (def.length === 0) {
  wanted.push(
    [
      `- id: agent-default-model`,
      `  name: "@deepseek-ai/dsh-agent-default-model"`,
      `  config:`,
      `    provider: ${providerId}`,
      `    model: ${modelId}`,
    ].join('\n'),
  )
} else if (def[0].config?.model !== modelId) {
  conflicts.push(
    `agent-default-model is ${JSON.stringify(def[0].config)}, expected provider ${providerId} / model ${modelId}.`,
  )
} else {
  ok.push(`agent-default-model -> ${providerId}/${modelId}`)
}

// 3. modlens families (without this the "(modlens vision)" twin is never created)
const mod = find('modlens')
if (mod.length === 0) {
  wanted.push(
    [
      `- id: modlens`,
      `  name: "@liustack/modlens"`,
      `  config:`,
      `    families: [${families.map((f) => `'${f}'`).join(', ')}]`,
    ].join('\n'),
  )
} else {
  const list = Array.isArray(mod[0].config?.families) ? mod[0].config.families : []
  if (!list.includes('qwen')) {
    conflicts.push(
      `modlens entry exists but families ${JSON.stringify(list)} has no 'qwen' prefix, ` +
        `so no vision twin is registered for ${modelId}. Add 'qwen' to that list.`,
    )
  } else {
    ok.push(`modlens families include qwen`)
  }
}

// 4. compaction thresholds, sized for this window
const comp = find('compaction-basic')
if (comp.length === 0) {
  wanted.push(
    [
      `- id: compaction-basic`,
      `  name: "@deepseek-ai/dsh-compaction-basic"`,
      `  config:`,
      `    thresholdRatio: 0.75`,
      `    retainRatio: 0.16`,
      `    headroomTokens: ${outTokens}`,
      `    compactionRetries: 1`,
      `    maxOverflowRetries: 1`,
    ].join('\n'),
  )
} else {
  const c = comp[0].config || {}
  const room = ctxTokens - outTokens - (c.headroomTokens === undefined ? 65536 : c.headroomTokens)
  if (room <= 0) {
    conflicts.push(
      `compaction-basic headroomTokens ${c.headroomTokens} leaves no room in a ${ctxTokens} window ` +
        `(ctx - maxTokens - headroom must stay positive). Set headroomTokens to ${outTokens}.`,
    )
  } else {
    ok.push(`compaction-basic trigger=${Math.floor(ctxTokens * (c.thresholdRatio || 0.75))} room=${room}`)
  }
}

console.log(`profile : ${profileDir}`)
for (const line of ok) console.log('OK      ' + line)
for (const line of conflicts) console.log('CONFLICT ' + line.split('\n').join('\n         '))
if (wanted.length === 0 && conflicts.length === 0) {
  console.log('RESULT  nothing to change')
  process.exit(0)
}
for (const block of wanted) console.log('APPEND  ' + block.split('\n').join('\n         '))

if (has('dry-run')) {
  console.log('RESULT  dry run, nothing written')
  process.exit(0)
}

if (wanted.length) {
  if (fs.existsSync(file)) {
    fs.copyFileSync(file, file + '.bak')
    console.log(`backup  ${file}.bak`)
  }
  const body =
    (fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '') +
    '\n# --- added by dsh-local-pack ---\n' +
    wanted.join('\n') +
    '\n'
  fs.writeFileSync(file, body.replace(/\r?\n/g, '\r\n'))
  console.log(`RESULT  appended ${wanted.length} entr(y|ies); ${conflicts.length} need manual edit`)
} else {
  console.log(`RESULT  nothing appended; ${conflicts.length} need manual edit`)
}
process.exit(conflicts.length ? 1 : 0)
