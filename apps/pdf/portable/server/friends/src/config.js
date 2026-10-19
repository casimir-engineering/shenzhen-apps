// Configuration from the environment (the stack's .env file in production, explicit values in tests). Anything
// malformed stops the service at start with a message naming the variable, rather than running half-configured.

import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';

import { parseTrustedProxies } from './address.js';
import { checkTimeZone } from './clock.js';
import { linksConfig } from './config-links.js';
import { onlineConfig } from './config-online.js';
import { decodeBase64url } from './keys.js';
import { validHostId } from './protocol.js';

function integer(env, name, fallback, { min = 0, max = 2 ** 31 - 1 } = {}) {
    const raw = env[name];
    if (raw === undefined || raw === '') return fallback;
    const value = Number(raw);
    if (!Number.isSafeInteger(value) || value < min || value > max) {
        throw new Error(`${name} must be an integer from ${min} to ${max}`);
    }
    return value;
}

function pinnedKeys(env) {
    const raw = (env.FRIENDS_PINNED_KEYS ?? '').split(',').map((s) => s.trim()).filter(Boolean);
    if (raw.length === 0) throw new Error('FRIENDS_PINNED_KEYS must list the host-list public keys (base64url)');
    return raw.map((value) => {
        const key = decodeBase64url(value, 32);
        if (!key) throw new Error('FRIENDS_PINNED_KEYS holds a value that is not a 32-byte base64url key');
        return key;
    });
}

// The host's own Ed25519 key: it signs every reservation answer helpers receive (they check it against the public
// key the signed list gives this host) and proves this host on links between hosts. Unencrypted PKCS#8 because
// the service starts unattended; it is not the list-signing key, which never reaches a server.
function hostKey(env) {
    const file = env.FRIENDS_HOST_KEY_FILE;
    if (!file) {
        throw new Error('FRIENDS_HOST_KEY_FILE must name this host\'s Ed25519 key '
            + '(friends-hostlist keygen --host-key)');
    }
    const key = crypto.createPrivateKey(fs.readFileSync(file));
    if (key.asymmetricKeyType !== 'ed25519') throw new Error('FRIENDS_HOST_KEY_FILE is not an Ed25519 private key');
    return key;
}

// Names identities in the database (keys.js identityHash). The same on every host, kept offline beside the list
// keys: losing it orphans every reserved ID, exactly like losing the database.
function identitySecret(env) {
    const secret = env.FRIENDS_IDENTITY_SECRET || '';
    if (secret.length < 32) {
        throw new Error('FRIENDS_IDENTITY_SECRET must be at least 32 characters (openssl rand -base64 32), the same on '
            + 'every host');
    }
    return secret;
}

// Behind the ingress every connection comes from the proxy, which passes the client address in X-Real-IP. The
// header is believed only from the configured proxy addresses, so a container beside the ingress cannot choose
// which budget it spends.
function trustedProxies(env) {
    if (env.FRIENDS_TRUST_PROXY !== undefined && env.FRIENDS_TRUST_PROXY !== '') {
        throw new Error('FRIENDS_TRUST_PROXY is replaced by FRIENDS_TRUSTED_PROXY: the ingress\'s address or CIDR '
            + 'block');
    }
    return parseTrustedProxies(env.FRIENDS_TRUSTED_PROXY);
}

export function loadConfig(env = process.env) {
    const hostId = env.FRIENDS_HOST_ID;
    if (!validHostId(hostId)) throw new Error('FRIENDS_HOST_ID must be a host id such as main-hk');
    const dataDir = path.resolve(env.FRIENDS_DATA_DIR || '/data');
    const statsTimeZone = env.FRIENDS_STATS_TZ || 'Asia/Hong_Kong';
    try {
        checkTimeZone(statsTimeZone);
    } catch {
        throw new Error('FRIENDS_STATS_TZ is not a time zone name such as Asia/Hong_Kong');
    }
    const replicaSecret = env.FRIENDS_REPLICA_SECRET || null;
    if (replicaSecret && replicaSecret.length < 32) {
        throw new Error('FRIENDS_REPLICA_SECRET must be at least 32 characters (openssl rand -base64 32)');
    }
    const dashboardPassword = env.FRIENDS_DASHBOARD_PASSWORD || null;
    if (dashboardPassword && dashboardPassword.length < 12) {
        throw new Error('FRIENDS_DASHBOARD_PASSWORD must be at least 12 characters');
    }
    return {
        hostId,
        listenHost: env.FRIENDS_LISTEN_HOST || '0.0.0.0',
        listenPort: integer(env, 'FRIENDS_LISTEN_PORT', 8080, { max: 65535 }),
        dataDir,
        pinnedKeys: pinnedKeys(env),
        hostListFile: env.FRIENDS_HOST_LIST_FILE || null,
        hostKey: hostKey(env),
        identitySecret: identitySecret(env),
        replicaSecret,
        dashboardSocket: env.FRIENDS_DASHBOARD_SOCKET || path.join(dataDir, 'dashboard.sock'),
        dashboardUser: env.FRIENDS_DASHBOARD_USER || 'admin',
        dashboardPassword,
        trustedProxies: trustedProxies(env),
        statsTimeZone,
        minProtocol: integer(env, 'FRIENDS_MIN_PROTOCOL', 1, { min: 1 }),
        // Only for a main host whose ID table never finished copying from the previous main host (DEPLOY.md):
        // allocating from it lets anyone claim an ID whose owner has not checked in since.
        allowUnsyncedMain: env.FRIENDS_ALLOW_UNSYNCED_MAIN === '1',
        // Online Friends and the relay, both off unless switched on (config-online.js).
        online: onlineConfig(env, dataDir),
        // Where the link pages send someone who has none of the apps yet (config-links.js).
        links: linksConfig(env),
        limits: {
            connectionsPerAddress: integer(env, 'FRIENDS_RATE_CONNECTIONS_PER_MINUTE', 30, { min: 1 }),
            connectionsPerAddressOpen: integer(env, 'FRIENDS_MAX_CONNECTIONS_PER_ADDRESS', 6, { min: 1 }),
            newIdsPerAddressPerDay: integer(env, 'FRIENDS_NEW_IDS_PER_ADDRESS_PER_DAY', 3, { min: 0 }),
            // On the main host: new IDs granted through each replica per statistics day. A replica can sign
            // check-ins for keys it makes up, so this bounds how fast a compromised one could squat free IDs.
            newIdsPerReplicaPerDay: integer(env, 'FRIENDS_NEW_IDS_PER_REPLICA_PER_DAY', 200, { min: 0 }),
            messagesPerWindow: integer(env, 'FRIENDS_RATE_MESSAGES_PER_10S', 20, { min: 1 }),
            maxConnections: integer(env, 'FRIENDS_MAX_CONNECTIONS', 5000, { min: 1 }),
            maxUnauthenticated: integer(env, 'FRIENDS_MAX_UNAUTHENTICATED', 200, { min: 1 }),
            checkinTimeoutMs: integer(env, 'FRIENDS_CHECKIN_TIMEOUT_MS', 10_000, { min: 100 }),
            forwardTimeoutMs: integer(env, 'FRIENDS_FORWARD_TIMEOUT_MS', 5_000, { min: 100 }),
            pingIntervalMs: integer(env, 'FRIENDS_PING_INTERVAL_MS', 25_000, { min: 100 }),
        },
    };
}
