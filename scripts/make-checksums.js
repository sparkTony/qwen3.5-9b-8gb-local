// Writes scripts/checksums.json: sha256 of every .gguf under models/, keyed by
// pack-relative path. Run this before zipping the pack.
const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')

const root = path.resolve(__dirname, '..')
const modelsDir = path.join(root, 'models')
const out = path.join(__dirname, 'checksums.json')

function walk(dir, base) {
  const found = []
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name)
    const rel = base ? base + '/' + name : name
    const st = fs.statSync(full)
    if (st.isDirectory()) found.push(...walk(full, rel))
    else if (/\.gguf$/i.test(name)) found.push({ rel, full, size: st.size })
  }
  return found
}

function sha256(file) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256')
    const stream = fs.createReadStream(file, { highWaterMark: 8 * 1024 * 1024 })
    stream.on('data', (chunk) => hash.update(chunk))
    stream.on('error', reject)
    stream.on('end', () => resolve(hash.digest('hex')))
  })
}

async function main() {
  const map = {}
  for (const file of walk(modelsDir, '')) {
    map['models/' + file.rel] = await sha256(file.full)
    console.log(`models/${file.rel}  ${(file.size / 1073741824).toFixed(2)} GiB  ${map['models/' + file.rel]}`)
  }
  fs.writeFileSync(out, JSON.stringify(map, null, 2) + '\n')
  console.log('wrote ' + out)
}

main().catch((error) => {
  console.error('FAIL ' + error.message)
  process.exit(1)
})
