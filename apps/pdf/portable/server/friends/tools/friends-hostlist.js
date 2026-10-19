#!/usr/bin/env node
// The host-list signing tool, run on the admin's Mac (never on a server). ADR 0005 § Signed host list.
//
//   keygen --out <path> [--host-key]        a key pair: <path> (private, PKCS#8 PEM) and <path>.pub (base64url)
//   sign --primary <pem> [--backup <pem>] --payload <payload.json> --out <list.json>
//   verify (--pinned <b64url>[,<b64url>] | --pinned-file <pinned-keys.json>) <list.json>
//   public-key --key <pem>                  prints the base64url public key
//   pinned-file --primary-pub <b64url> --backup-pub <b64url> --out <pinned-keys.json>
//   release-check --pinned-file <pinned-keys.json> --bootstrap <list.json>
//
// Admin signing keys are passphrase-encrypted (aes-256-cbc PKCS#8); --host-key writes an unencrypted key for a
// host's links to other hosts, which the service must read unattended. Either way the private key is refused
// inside any git repository and inside this package, because both get copied to places keys must not go.
// Passphrases come from a hidden prompt, --passphrase-file, or FRIENDS_SIGNING_PASSPHRASE.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

import { signPayload, verifyEnvelope } from '../src/hostlist.js';
import { decodeBase64url, encodeBase64url, rawPublicKey } from '../src/keys.js';
import { PACKAGE_ROOT, UsageError, forbiddenKeyLocation, parseArgs, readPassphrase, readPinnedFile }
    from './cli-support.js';

const out = (line) => process.stdout.write(`${line}\n`);

async function keygen(args) {
    const target = args.get('out');
    if (!target) throw new UsageError('keygen needs --out <path>');
    const reason = forbiddenKeyLocation(target);
    if (reason) throw new UsageError(`refusing to write a private key to ${target}: ${reason}`);
    const hostKey = args.has('host-key');
    const passphrase = hostKey ? null : await readPassphrase(args, { confirm: true });
    if (!hostKey && passphrase.length < 12) throw new UsageError('use a passphrase of at least 12 characters');
    const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
    const pem = privateKey.export(hostKey ? { type: 'pkcs8', format: 'pem' }
        : { type: 'pkcs8', format: 'pem', cipher: 'aes-256-cbc', passphrase });
    fs.mkdirSync(path.dirname(path.resolve(target)), { recursive: true, mode: 0o700 });
    // 'wx': never overwrite an existing key, which may be the only copy.
    fs.writeFileSync(target, pem, { mode: 0o600, flag: 'wx' });
    const pub = encodeBase64url(rawPublicKey(publicKey));
    fs.writeFileSync(`${target}.pub`, `${pub}\n`, { mode: 0o644, flag: 'wx' });
    out(pub);
}

async function loadPrivateKey(file, args) {
    const pem = fs.readFileSync(file, 'utf8');
    const encrypted = pem.includes('ENCRYPTED');
    const key = crypto.createPrivateKey(encrypted ? { key: pem, passphrase: await readPassphrase(args) } : pem);
    if (key.asymmetricKeyType !== 'ed25519') throw new UsageError(`${file} is not an Ed25519 key`);
    return key;
}

async function sign(args) {
    const primary = args.get('primary');
    const payloadFile = args.get('payload');
    const target = args.get('out');
    if (!primary || !payloadFile || !target) throw new UsageError('sign needs --primary, --payload and --out');
    const payload = JSON.parse(fs.readFileSync(payloadFile, 'utf8'));
    if (!payload.issued_at) payload.issued_at = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
    const signers = [{ name: 'primary', privateKey: await loadPrivateKey(primary, args) }];
    if (args.get('backup')) {
        signers.push({ name: 'backup', privateKey: await loadPrivateKey(args.get('backup'), args) });
    }
    let envelope;
    try {
        envelope = signPayload(payload, signers);
    } catch (error) {
        throw new UsageError(`the payload is not a host list the helper would accept: ${error.message}`);
    }
    fs.writeFileSync(target, `${JSON.stringify(envelope, null, 2)}\n`, { mode: 0o644 });
    out(`Signed host list v${payload.version} with ${signers.map((s) => s.name).join(' and ')}: ${target}`);
}

function pinnedKeysFrom(args) {
    if (args.get('pinned-file')) {
        return readPinnedFile(args.get('pinned-file')).map((entry) => decodeBase64url(entry.public_key, 32));
    }
    const listed = (args.get('pinned') ?? '').split(',').filter(Boolean).map((v) => decodeBase64url(v, 32));
    if (listed.length === 0) throw new UsageError('verify needs --pinned or --pinned-file');
    return listed;
}

function verify(args) {
    const file = args.positionals[0];
    if (!file) throw new UsageError('verify needs the signed list file');
    const keys = pinnedKeysFrom(args);
    if (keys.some((key) => !key)) throw new UsageError('a pinned key is not a 32-byte base64url value');
    const result = verifyEnvelope(fs.readFileSync(file, 'utf8'), keys);
    if (!result.ok) {
        process.stderr.write(`Not valid: ${result.error}\n`);
        return 1;
    }
    out(`Valid host list v${result.list.version}, issued ${result.list.issuedAt}, new IDs with `
        + `${result.list.newIdWords} words`);
    for (const host of result.list.hosts) {
        out(`  ${host.priority}  ${host.id}  ${host.role}  ${host.region}  ${host.urls.join(' ')}`);
    }
    return 0;
}

async function publicKey(args) {
    const file = args.get('key');
    if (!file) throw new UsageError('public-key needs --key <pem>');
    out(encodeBase64url(rawPublicKey(await loadPrivateKey(file, args))));
}

function pinnedFile(args) {
    const primary = args.get('primary-pub');
    const backup = args.get('backup-pub');
    const target = args.get('out');
    if (!primary || !backup || !target) throw new UsageError('pinned-file needs --primary-pub, --backup-pub, --out');
    if (!decodeBase64url(primary, 32) || !decodeBase64url(backup, 32) || primary === backup) {
        throw new UsageError('give two different 32-byte base64url public keys');
    }
    const file = {
        comment: 'Host-list signing keys the helper pins (ADR 0005). Public keys only. One valid signature from '
            + 'either verifies a list; replacing a lost key takes an app release.',
        keys: [{ name: 'primary', public_key: primary, test: false },
            { name: 'backup', public_key: backup, test: false }],
    };
    fs.writeFileSync(target, `${JSON.stringify(file, null, 2)}\n`);
    out(`Wrote ${target}`);
}

// Fails while the helper would ship a test key or a bootstrap list that does not verify with the pinned keys.
// Test keys are recognised by their flag and by value: every key in this package's test vectors.
function releaseCheck(args) {
    const pinnedPath = args.get('pinned-file');
    const bootstrapPath = args.get('bootstrap');
    if (!pinnedPath || !bootstrapPath) throw new UsageError('release-check needs --pinned-file and --bootstrap');
    const entries = readPinnedFile(pinnedPath);
    const vectors = JSON.parse(fs.readFileSync(path.join(PACKAGE_ROOT, 'test/vectors/host-list-v1.json'), 'utf8'));
    const knownTest = new Set(vectors.test_public_keys);
    const problems = [];
    for (const entry of entries) {
        if (entry.test !== false) problems.push(`${entry.name} is marked as a test key`);
        if (knownTest.has(entry.public_key)) problems.push(`${entry.name} is a key from the test vectors`);
        if (!decodeBase64url(entry.public_key, 32)) problems.push(`${entry.name} is not a 32-byte key`);
    }
    if (entries.length < 2) problems.push('pin two keys, primary and backup, so a lost key can be replaced');
    const keys = entries.map((entry) => decodeBase64url(entry.public_key, 32)).filter(Boolean);
    const bootstrap = verifyEnvelope(fs.readFileSync(bootstrapPath, 'utf8'), keys);
    if (!bootstrap.ok) problems.push(`the bootstrap list does not verify: ${bootstrap.error}`);
    else if (bootstrap.list.hosts.some((host) => host.urls.some((url) => !url.startsWith('wss://')))) {
        problems.push('the bootstrap list names a cleartext URL');
    }
    for (const problem of problems) process.stderr.write(`release-check: ${problem}\n`);
    if (problems.length === 0) out('release-check: production keys pinned; bootstrap list verifies');
    return problems.length === 0 ? 0 : 1;
}

const COMMANDS = { keygen, sign, verify, 'public-key': publicKey, 'pinned-file': pinnedFile,
    'release-check': releaseCheck };

async function main(argv) {
    const [command, ...rest] = argv;
    const run = COMMANDS[command];
    if (!run) {
        process.stderr.write(`usage: friends-hostlist <${Object.keys(COMMANDS).join('|')}> [options]\n`);
        return 2;
    }
    try {
        return (await run(parseArgs(rest, { booleans: ['host-key'] }))) ?? 0;
    } catch (error) {
        if (error instanceof UsageError || error.code === 'ENOENT' || error.code === 'EEXIST'
            || error instanceof SyntaxError) {
            process.stderr.write(`friends-hostlist ${command}: ${error.message}\n`);
            return 2;
        }
        if (/bad decrypt|unable to decrypt|Unsupported state/i.test(String(error.message))) {
            process.stderr.write(`friends-hostlist ${command}: wrong passphrase\n`);
            return 2;
        }
        throw error;
    }
}

process.exitCode = await main(process.argv.slice(2));
