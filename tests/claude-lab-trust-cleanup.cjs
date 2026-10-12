const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');

const [inputStore, ...keys] = process.argv.slice(2);
try {
  if (!fs.existsSync(inputStore)) process.exit(0);
  const store = fs.realpathSync(inputStore);
  const stat = fs.statSync(store);
  if (!stat.isFile() || stat.uid !== process.getuid()) {
    throw new Error(`${store} is not a regular file owned by this user`);
  }
  const fingerprint = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const original = fs.readFileSync(store);
    const root = JSON.parse(original);
    if (root === null || typeof root !== 'object' || Array.isArray(root)) {
      throw new Error(`${store} is not a JSON object`);
    }
    if (root.projects !== undefined) {
      if (root.projects === null || typeof root.projects !== 'object' || Array.isArray(root.projects)) {
        throw new Error(`${store} has a non-object projects value`);
      }
      for (const key of keys) delete root.projects[key];
    }
    const tmp = path.join(path.dirname(store), `.claude.json.fm-trust.${process.pid}.${crypto.randomBytes(8).toString('hex')}`);
    fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
    let renamed = false;
    try {
      if (fingerprint(fs.readFileSync(store)) !== fingerprint(original)) {
        if (attempt >= 1) throw new Error(`${store} changed during cleanup; refusing to overwrite it`);
        continue;
      }
      fs.renameSync(tmp, store);
      renamed = true;
    } finally {
      if (!renamed) fs.rmSync(tmp, { force: true });
    }
    const back = JSON.parse(fs.readFileSync(store, 'utf8'));
    if (keys.every((key) => !Object.hasOwn(back.projects ?? {}, key))) {
      for (const key of keys) assert.equal(Object.hasOwn(back.projects ?? {}, key), false);
      process.exit(0);
    }
  }
  throw new Error(`${store} retained lab trust entries after cleanup`);
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
