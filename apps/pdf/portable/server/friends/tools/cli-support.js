// Support for the signing CLI: argument parsing, passphrases, and the rule that a private key never lands inside a
// repository or this package (ADR 0005 § The signing key never reaches a server).

import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

export const PACKAGE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export class UsageError extends Error {}

// --flag value pairs and bare positionals; a flag given twice collects every value in order.
export function parseArgs(argv, { booleans = [] } = {}) {
    const flags = new Map();
    const positionals = [];
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        if (!arg.startsWith('--')) {
            positionals.push(arg);
            continue;
        }
        const name = arg.slice(2);
        if (booleans.includes(name)) {
            flags.set(name, [true]);
            continue;
        }
        const value = argv[i + 1];
        if (value === undefined || value.startsWith('--')) throw new UsageError(`--${name} needs a value`);
        flags.set(name, [...(flags.get(name) ?? []), value]);
        i += 1;
    }
    return {
        positionals,
        get: (name) => flags.get(name)?.at(-1),
        all: (name) => flags.get(name) ?? [],
        has: (name) => flags.has(name),
    };
}

function isWithin(child, parent) {
    const relative = path.relative(parent, child);
    return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

// The real path of `target`'s deepest existing ancestor plus the rest, so a symlink cannot smuggle a key into a
// repository the check would otherwise not see.
function realTarget(target) {
    let existing = path.resolve(target);
    const rest = [];
    while (!fs.existsSync(existing)) {
        rest.unshift(path.basename(existing));
        const parent = path.dirname(existing);
        if (parent === existing) break;
        existing = parent;
    }
    return path.join(fs.realpathSync(existing), ...rest);
}

// Returns why `target` may not hold a private key, or null when it may.
export function forbiddenKeyLocation(target) {
    const resolved = realTarget(target);
    if (isWithin(resolved, fs.realpathSync(PACKAGE_ROOT))) {
        return 'it is inside the Friends host package, which is copied to servers (deploy/ included)';
    }
    for (let dir = path.dirname(resolved); ; dir = path.dirname(dir)) {
        if (fs.existsSync(path.join(dir, '.git'))) return `it is inside a git repository (${dir})`;
        if (path.dirname(dir) === dir) break;
    }
    return null;
}

// A hidden prompt on a terminal; otherwise the passphrase must come from a file or the environment, so scripts
// and tests never hang waiting for input.
export async function readPassphrase(args, { confirm = false, env = process.env } = {}) {
    const file = args.get('passphrase-file');
    if (file) return fs.readFileSync(file, 'utf8').replace(/\r?\n$/, '');
    if (env.FRIENDS_SIGNING_PASSPHRASE) return env.FRIENDS_SIGNING_PASSPHRASE;
    if (!process.stdin.isTTY) {
        throw new UsageError('give the passphrase with --passphrase-file or FRIENDS_SIGNING_PASSPHRASE');
    }
    const first = await prompt('Passphrase: ');
    if (confirm && first !== await prompt('Repeat passphrase: ')) throw new UsageError('the passphrases differ');
    return first;
}

function prompt(question) {
    return new Promise((resolve) => {
        const rl = readline.createInterface({ input: process.stdin, output: process.stderr, terminal: true });
        rl._writeToOutput = (text) => {
            if (text.includes(question)) process.stderr.write(question);
        };
        rl.question(question, (answer) => {
            rl.close();
            process.stderr.write('\n');
            resolve(answer);
        });
    });
}

// The pinned-keys file the helper bundles (portable/friends/service/host/resources/pinned-keys.json).
export function readPinnedFile(file) {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!parsed || !Array.isArray(parsed.keys) || parsed.keys.length === 0) {
        throw new UsageError(`${file} has no "keys" array`);
    }
    return parsed.keys;
}
