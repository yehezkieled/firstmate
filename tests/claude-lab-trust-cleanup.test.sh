#!/usr/bin/env bash
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/claude-trust-cleanup.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
node - "$ROOT/tests/claude-lab-trust-cleanup.cjs" "$LAB" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const [helper, lab] = process.argv.slice(2);
const store = path.join(lab, 'store.json');
const link = path.join(lab, '.claude.json');
const wt = path.join(lab, 'wt');
const proj = path.join(lab, 'proj');
const other = { hasTrustDialogAccepted: true, history: ['keep'] };
const seed = () => fs.writeFileSync(store, JSON.stringify({
  oauthAccount: { sentinel: 'unchanged' },
  projects: { [wt]: { hasTrustDialogAccepted: true }, [proj]: {}, other },
}));
fs.symlinkSync(store, link);
for (const code of [0, 7]) {
  seed();
  const run = spawnSync('bash', ['-c',
    'trap \'result=$?; node "$1" "$2" "$3" "$4" || result=1; exit "$result"\' EXIT; exit "$5"',
    'cleanup', helper, link, wt, proj, String(code)], { encoding: 'utf8' });
  assert.equal(run.status, code, run.stderr);
  assert.equal(fs.lstatSync(link).isSymbolicLink(), true);
  const back = JSON.parse(fs.readFileSync(store, 'utf8'));
  assert.equal(Object.hasOwn(back.projects, wt), false);
  assert.equal(Object.hasOwn(back.projects, proj), false);
  assert.deepEqual(back, { oauthAccount: { sentinel: 'unchanged' }, projects: { other } });
}
const repeat = spawnSync('node', [helper, link, wt, proj]);
assert.equal(repeat.status, 0);
fs.writeFileSync(store, 'broken json');
const invalid = spawnSync('node', [helper, link, wt, proj]);
assert.equal(invalid.status, 1);
assert.equal(fs.readFileSync(store, 'utf8'), 'broken json');
assert.deepEqual(fs.readdirSync(lab).sort(), ['.claude.json', 'store.json']);
console.log('ok - cleanup removes both lab entries on success and failure, preserves unrelated state and symlinks, and refuses malformed stores');
NODE
