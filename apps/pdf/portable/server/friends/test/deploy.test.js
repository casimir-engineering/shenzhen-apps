// The deployment files hold what ADR 0005 and DEPLOY.md promise: no client address in ingress logs, a process
// limit and a read-only root filesystem, the client address believed only from the ingress, and a build that stops
// unless the Node image is pinned by digest. Static checks, because the suites never run Docker or nginx.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import { test } from 'node:test';

const read = (name) => fs.readFileSync(new URL(`../deploy/${name}`, import.meta.url), 'utf8');
const code = (text) => text.split('\n').filter((line) => !line.trim().startsWith('#')).join('\n');

test('the ingress block writes no access or error lines and passes the client address only as X-Real-IP', () => {
    const nginx = code(read('nginx-friends.conf'));
    assert.match(nginx, /^\s*access_log off;$/m);
    assert.match(nginx, /^\s*error_log \/dev\/null;$/m);
    assert.doesNotMatch(nginx, /error_log (?!\/dev\/null;)/, 'every error_log in the block goes nowhere');
    assert.match(nginx, /proxy_set_header X-Real-IP \$remote_addr;/);
    assert.match(nginx, /proxy_set_header X-Forwarded-For "";/);
});

test('the container runs read-only with a process limit and trusts no forwarded address by default', () => {
    const compose = code(read('docker-compose.yml'));
    assert.match(compose, /^\s*read_only: true$/m);
    assert.match(compose, /^\s*pids_limit: 128$/m);
    assert.match(compose, /^\s*- \/tmp:size=\d+m/m, 'a small tmpfs where Node needs one');
    assert.match(compose, /^\s*cap_drop:\s*\n\s*- ALL$/m);
    assert.doesNotMatch(compose, /FRIENDS_TRUST_PROXY\b/, 'the proxy is named in .env by address');
    assert.match(compose, /NODE_IMAGE: \$\{FRIENDS_NODE_IMAGE:\?/, 'compose stops without a pinned image');
    // 41 KiB per checked-in connection was measured with an unfinished message parked on each; 96 KiB more each for
    // the connections that have not checked in yet, whose check-in may carry a device chain, and 64 MiB for the
    // process.
    const connections = Number(/FRIENDS_MAX_CONNECTIONS: "(\d+)"/.exec(compose)?.[1]);
    const limitMiB = Number(/^\s*mem_limit: (\d+)m$/m.exec(compose)?.[1]);
    assert.ok(connections > 0 && limitMiB > 0, 'compose sets both');
    assert.ok(64 + (connections * 41 + 200 * 137) / 1024 <= limitMiB, `${connections} connections fit ${limitMiB} MiB`);
});

test('the image build stops unless NODE_IMAGE is pinned by digest', () => {
    const dockerfile = code(read('Dockerfile'));
    assert.doesNotMatch(dockerfile, /ARG NODE_IMAGE=/, 'no unpinned default');
    const deps = dockerfile.slice(dockerfile.indexOf('AS deps'), dockerfile.indexOf('npm ci'));
    assert.match(deps, /RUN sh \/tmp\/check-node-image\.sh "\$NODE_IMAGE"/, 'checked before anything installs');
    const script = new URL('../deploy/check-node-image.sh', import.meta.url).pathname;
    const run = (value) => spawnSync('sh', [script, value], { encoding: 'utf8' }).status;
    assert.equal(run('node:22-alpine'), 1);
    assert.equal(run('node:22-alpine@sha256:abc'), 1);
    assert.equal(run(`node:22-alpine@sha256:${'A'.repeat(64)}`), 1);
    assert.equal(run(''), 1);
    assert.equal(run(`node:22-alpine@sha256:${'0123456789abcdef'.repeat(4)}`), 0);
});

test('the relay runs from the configuration the service writes, on the host network, printing nothing', () => {
    const compose = code(read('docker-compose.yml'));
    const relay = compose.slice(compose.indexOf('\n  relay:'));
    const friends = compose.slice(0, compose.indexOf('\n  relay:'));
    assert.match(relay, /image: \$\{FRIENDS_COTURN_IMAGE:\?/, 'compose stops without a pinned coturn image');
    assert.match(relay, /^\s*profiles:\s*\n\s*- relay$/m, 'started only with the relay profile');
    assert.match(relay, /^\s*network_mode: host$/m);
    assert.match(relay, /^\s*user: "10001:10001"$/m, 'the uid that owns the generated file');
    assert.match(relay, /^\s*read_only: true$/m);
    assert.match(relay, /^\s*cap_drop:\s*\n\s*- ALL$/m);
    assert.match(relay, /^\s*logging:\s*\n\s*driver: none$/m);
    // The service writes /data/relay/turnserver.conf; coturn reads the same directory, mounted read-only.
    assert.match(friends, /FRIENDS_TURN_CONF: \/data\/relay\/turnserver\.conf/);
    assert.match(relay, /- \.\/data\/relay:\/etc\/friends-relay:ro/);
    assert.match(relay, /command: \["-c", "\/etc\/friends-relay\/turnserver\.conf"\]/);
});

test('the friends service publishes the second STUN port and keeps the statistics port on loopback', () => {
    const compose = code(read('docker-compose.yml'));
    const friends = compose.slice(0, compose.indexOf('\n  relay:'));
    const ports = [...friends.matchAll(/^\s*- "([^"]+)"$/gm)].map((m) => m[1]);
    assert.deepEqual(ports, ['3479:3479/udp', '127.0.0.1:6390:6390/tcp']);
    assert.match(friends, /FRIENDS_STUN_PORTS: "3479"/);
    assert.match(friends, /FRIENDS_TURN_EVENTS_PORT: "6390"/);
    assert.match(friends, /FRIENDS_TURN_EVENTS_FROM: gateway$/m, 'not from other containers on the network');
});

test('coturn\'s command port is on the edge gateway, where the service reaches it, and never published', () => {
    const compose = code(read('docker-compose.yml'));
    const friends = compose.slice(0, compose.indexOf('\n  relay:'));
    // The default, 127.0.0.1, is the server's loopback for coturn but the container's own for the service, so
    // sessions would never be ended at their limit.
    assert.match(friends, /FRIENDS_TURN_CLI_IP: gateway$/m);
    assert.doesNotMatch(compose, /5766/, 'no port mapping for it, in either service');
    assert.doesNotMatch(friends, /FRIENDS_TURN_MAX_SESSION_S/,
        'the limit stays on (3600 s) unless .env says otherwise');
});

// The ingress's location blocks, as { match, body }: `= /path` exact, `~ regex`, or a prefix.
function locations(conf) {
    const found = [];
    const pattern = /^\s*location\s+(=\s*|~\*?\s*)?(\S+)\s*\{([^}]*)\}/gm;
    for (const m of conf.matchAll(pattern)) {
        found.push({ kind: (m[1] ?? '').trim() || 'prefix', path: m[2], body: m[3] });
    }
    return found;
}

// Which block nginx picks for a path: an exact match first, then the longest prefix (no regex blocks here).
function route(blocks, path) {
    const exact = blocks.find((b) => b.kind === '=' && b.path === path);
    if (exact) return exact;
    assert.ok(!blocks.some((b) => b.kind.startsWith('~')), 'no regex locations to reason about');
    return blocks.filter((b) => b.kind === 'prefix' && path.startsWith(b.path))
        .sort((a, b) => b.path.length - a.path.length)[0];
}

test('the ingress routes every link page to the service by its exact path, and nothing else', async () => {
    const { LINK_PAGE_PATHS } = await import('../src/link-pages.js');
    const blocks = locations(code(read('nginx-friends.conf')));
    const toService = (block) => /^\s*proxy_pass \$friends_upstream;$/m.test(block?.body ?? '');
    for (const path of ['/v1', ...LINK_PAGE_PATHS]) {
        const block = route(blocks, path);
        assert.equal(block?.kind, '=', `${path} has an exact location`);
        assert.ok(toService(block), `${path} goes to the service`);
        assert.match(block.body, /proxy_set_header Host \$host;/, `${path} keeps the Host header (the CSP names it)`);
        assert.match(block.body, /proxy_set_header X-Real-IP \$remote_addr;/);
        assert.match(block.body, /proxy_set_header X-Forwarded-For "";/);
        assert.doesNotMatch(block.body, /add_header|proxy_hide_header/, `${path} passes the service's headers as is`);
    }
    for (const path of ['/', '/f/', '/fx', '/d/', '/d/sw.js.map', '/links/', '/links/other.js', '/healthz',
        '/dashboard', '/v1/x']) {
        assert.ok(!toService(route(blocks, path)), `${path} stays at the ingress`);
        assert.match(route(blocks, path).body, /return 404;/, `${path} answers 404`);
    }
});

test('the service refuses to start if the ingress list and its pages drift apart', async () => {
    const { linkPages, LINK_PAGE_PATHS } = await import('../src/link-pages.js');
    const config = { online: { guestIceServers: [] },
        links: { pdfUrl: 'https://a.example', filesUrl: 'https://b.example' } };
    assert.doesNotThrow(() => linkPages(config));
    assert.deepEqual([...LINK_PAGE_PATHS].sort(), ['/d', '/d/sw.js', '/f', '/links/links.css', '/links/links.js']);
});
