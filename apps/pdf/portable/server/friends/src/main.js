#!/usr/bin/env node
// Entry point: configuration from the environment, then the host until SIGTERM (docker stop) or SIGINT.

import { loadConfig } from './config.js';
import { FriendsHost } from './host.js';
import { createLogger, errorCode } from './log.js';

// ADR 0005 § Runtime: 22.16 is the first 22.x with node:sqlite unflagged and its busy-timeout option.
const [major, minor] = process.versions.node.split('.').map(Number);
if (major < 22 || (major === 22 && minor < 16)) {
    process.stderr.write(`The Friends host needs Node.js 22.16 or later; this is ${process.versions.node}.\n`);
    process.exit(1);
}

const log = createLogger();
let host;
try {
    host = new FriendsHost(loadConfig(process.env), { log });
    await host.start();
} catch (error) {
    // Configuration errors are written by us and name only the variable; print them. Anything else may carry
    // an address in its message, so only its code is logged.
    const ours = /^(FRIENDS_|no verified host list|database schema)/;
    const configError = error instanceof Error && ours.test(error.message);
    process.stderr.write(`Friends host did not start: ${configError ? error.message : errorCode(error)}\n`);
    process.exit(1);
}

let stopping = false;
async function shutdown(signal) {
    if (stopping) return;
    stopping = true;
    log('stopping', { reason: signal });
    await host.stop();
    process.exit(0);
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
