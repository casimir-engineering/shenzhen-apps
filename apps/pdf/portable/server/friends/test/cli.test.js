// The signing CLI (ADR 0005 § The signing key never reaches a server): key generation, signing, verification,
// and the release check that refuses test keys. Keys are generated in temporary directories and thrown away.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { verifyEnvelope } from '../src/hostlist.js';
import { decodeBase64url } from '../src/keys.js';
import { keyPair, listPayload, tempDir } from './helpers.js';

const CLI = fileURLToPath(new URL('../tools/friends-hostlist.js', import.meta.url));
const RESOURCES = fileURLToPath(new URL('../../../friends/service/host/resources/', import.meta.url));

function run(args, { env = {} } = {}) {
    const result = spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8', timeout: 9000,
        env: { PATH: process.env.PATH, HOME: process.env.HOME, ...env }, stdio: ['ignore', 'pipe', 'pipe'] });
    return { code: result.status, out: result.stdout, err: result.stderr };
}

function passphraseFile(dir) {
    const file = path.join(dir, 'pass');
    fs.writeFileSync(file, 'correct horse battery staple\n');
    return file;
}

test('keygen writes a 0600 passphrase-encrypted key and its public half', (t) => {
    const dir = tempDir(t);
    const key = path.join(dir, 'keys', 'primary.pem');
    const result = run(['keygen', '--out', key, '--passphrase-file', passphraseFile(dir)]);
    assert.equal(result.code, 0, result.err);
    const pem = fs.readFileSync(key, 'utf8');
    assert.match(pem, /BEGIN ENCRYPTED PRIVATE KEY/);
    assert.equal(fs.statSync(key).mode & 0o777, 0o600);
    const pub = fs.readFileSync(`${key}.pub`, 'utf8').trim();
    assert.equal(result.out.trim(), pub);
    assert.ok(decodeBase64url(pub, 32));
    assert.equal(run(['keygen', '--out', key, '--passphrase-file', passphraseFile(dir)]).code, 2, 'never overwrites');
});

test('keygen refuses a private key inside a repository or this package', (t) => {
    const dir = tempDir(t);
    fs.mkdirSync(path.join(dir, 'repo', '.git'), { recursive: true });
    const pass = passphraseFile(dir);
    const inRepo = run(['keygen', '--out', path.join(dir, 'repo', 'sub', 'k.pem'), '--passphrase-file', pass]);
    assert.equal(inRepo.code, 2);
    assert.match(inRepo.err, /git repository/);
    const inDeploy = run(['keygen', '--out', fileURLToPath(new URL('../deploy/k.pem', import.meta.url)),
        '--host-key']);
    assert.equal(inDeploy.code, 2);
    assert.match(inDeploy.err, /Friends host package/);
    fs.symlinkSync(path.join(dir, 'repo'), path.join(dir, 'link'));
    const viaLink = run(['keygen', '--out', path.join(dir, 'link', 'k.pem'), '--passphrase-file', pass]);
    assert.equal(viaLink.code, 2, 'a symlink into a repository is still a repository');
    assert.equal(fs.existsSync(path.join(dir, 'repo', 'k.pem')), false);
});

test('sign and verify round-trip with primary and backup keys; a wrong passphrase is refused', (t) => {
    const dir = tempDir(t);
    const pass = passphraseFile(dir);
    const primary = path.join(dir, 'primary.pem');
    const backup = path.join(dir, 'backup.pem');
    assert.equal(run(['keygen', '--out', primary, '--passphrase-file', pass]).code, 0);
    assert.equal(run(['keygen', '--out', backup, '--passphrase-file', pass]).code, 0);
    const payloadFile = path.join(dir, 'payload.json');
    const payload = listPayload({ version: 4, entries: [{ id: 'main-hk', key: keyPair(), priority: 1 }] });
    delete payload.issued_at;
    fs.writeFileSync(payloadFile, JSON.stringify(payload));
    const list = path.join(dir, 'list.json');
    const signed = run(['sign', '--primary', primary, '--backup', backup, '--payload', payloadFile, '--out', list,
        '--passphrase-file', pass]);
    assert.equal(signed.code, 0, signed.err);
    const pubs = [primary, backup].map((k) => fs.readFileSync(`${k}.pub`, 'utf8').trim());
    const verified = verifyEnvelope(fs.readFileSync(list, 'utf8'), pubs.map((p) => decodeBase64url(p, 32)));
    assert.equal(verified.ok, true);
    assert.equal(verified.signedBy.length, 2);
    assert.match(verified.list.issuedAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, 'issued_at filled in');
    assert.equal(run(['verify', '--pinned', pubs[1], list]).code, 0, 'the backup alone verifies');
    const stranger = keyPair().b64;
    const refused = run(['verify', '--pinned', stranger, list]);
    assert.equal(refused.code, 1);
    assert.match(refused.err, /pinned/);
    const wrong = path.join(dir, 'wrong');
    fs.writeFileSync(wrong, 'not the passphrase');
    const bad = run(['sign', '--primary', primary, '--payload', payloadFile, '--out', list,
        '--passphrase-file', wrong]);
    assert.equal(bad.code, 2);
    assert.match(bad.err, /wrong passphrase/);
});

test('sign refuses a payload the helper would reject', (t) => {
    const dir = tempDir(t);
    const pass = passphraseFile(dir);
    const primary = path.join(dir, 'primary.pem');
    run(['keygen', '--out', primary, '--passphrase-file', pass]);
    const payloadFile = path.join(dir, 'payload.json');
    const key = keyPair();
    fs.writeFileSync(payloadFile, JSON.stringify(listPayload({ entries: [{ id: 'a-host', key, priority: 1 },
        { id: 'b-host', key, priority: 1 }] })));
    const result = run(['sign', '--primary', primary, '--payload', payloadFile, '--out', path.join(dir, 'l.json'),
        '--passphrase-file', pass]);
    assert.notEqual(result.code, 0);
    assert.equal(fs.existsSync(path.join(dir, 'l.json')), false);
});

test('host keys are unencrypted so the service can start unattended, and public-key prints them', (t) => {
    const dir = tempDir(t);
    const key = path.join(dir, 'host.pem');
    const made = run(['keygen', '--out', key, '--host-key']);
    assert.equal(made.code, 0, made.err);
    assert.match(fs.readFileSync(key, 'utf8'), /BEGIN PRIVATE KEY/);
    assert.equal(run(['public-key', '--key', key]).out.trim(), made.out.trim());
});

// The deploy image's test stage copies only this package; everywhere else the helper's files must be present.
const STANDALONE = process.env.FRIENDS_TEST_STANDALONE === '1' && 'the helper resources are outside this copy';

test('release-check passes on the production keys the helper pins and refuses test keys', { skip: STANDALONE },
    (t) => {
    // The production keys were pinned and the bundled list re-signed on 2026-10-12 (resources/README.md).
    const committed = run(['release-check', '--pinned-file', path.join(RESOURCES, 'pinned-keys.json'),
        '--bootstrap', path.join(RESOURCES, 'bootstrap-hosts.json')]);
    assert.equal(committed.code, 0, committed.err);

    const dir = tempDir(t);
    const pass = passphraseFile(dir);
    const [primary, backup] = ['primary.pem', 'backup.pem'].map((n) => path.join(dir, n));
    run(['keygen', '--out', primary, '--passphrase-file', pass]);
    run(['keygen', '--out', backup, '--passphrase-file', pass]);
    const pubs = [primary, backup].map((k) => fs.readFileSync(`${k}.pub`, 'utf8').trim());
    const pinned = path.join(dir, 'pinned-keys.json');
    assert.equal(run(['pinned-file', '--primary-pub', pubs[0], '--backup-pub', pubs[1], '--out', pinned]).code, 0);
    const payloadFile = path.join(dir, 'payload.json');
    const payload = listPayload({ entries: [{ id: 'main-hk', key: keyPair(), priority: 1 }] });
    payload.hosts[0].urls = ['wss://friends.example.test/v1'];
    fs.writeFileSync(payloadFile, JSON.stringify(payload));
    const bootstrap = path.join(dir, 'bootstrap.json');
    run(['sign', '--primary', primary, '--payload', payloadFile, '--out', bootstrap, '--passphrase-file', pass]);
    const ok = run(['release-check', '--pinned-file', pinned, '--bootstrap', bootstrap]);
    assert.equal(ok.code, 0, ok.err);

    const vectors = JSON.parse(fs.readFileSync(new URL('vectors/host-list-v1.json', import.meta.url), 'utf8'));
    const sneaky = { keys: [{ name: 'primary', public_key: vectors.pinned[0], test: false },
        { name: 'backup', public_key: pubs[1], test: false }] };
    fs.writeFileSync(pinned, JSON.stringify(sneaky));
    const caught = run(['release-check', '--pinned-file', pinned, '--bootstrap', bootstrap]);
    assert.equal(caught.code, 1);
    assert.match(caught.err, /test vectors/);

    const flagged = { keys: [{ name: 'primary', public_key: pubs[0], test: true },
        { name: 'backup', public_key: pubs[1], test: false }] };
    fs.writeFileSync(pinned, JSON.stringify(flagged));
    const marked = run(['release-check', '--pinned-file', pinned, '--bootstrap', bootstrap]);
    assert.equal(marked.code, 1);
    assert.match(marked.err, /test key/);
});
