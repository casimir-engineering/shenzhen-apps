// One WebSocket from a helper (or from a replica, which hands over to host-links.js after its hello).
// HOST-PROTOCOL.md § Check-in is the contract. Messages on a connection are handled strictly in order, because a
// reservation forwarded to the main host is asynchronous and a `reserve` must never overtake the `welcome`.
// Every reservation answer is signed with this host's key over the connection's challenge (§ Signatures), so a
// TLS-intercepting proxy cannot rewrite one, and an answer that says "reserved" carries an ID attestation the helper
// can show nearby (attestation.js).

import { signAttestation, utcDay } from './attestation.js';
import { parseDevices } from './devices.js';
import { checkinProof, releaseProof } from './forward-proof.js';
import { decodeBase64url, encodeBase64url, identityHash, randomBytes, signEd25519, verifyEd25519 } from './keys.js';
import { ONLINE_LIMITS, ONLINE_PROTOCOL, ONLINE_TYPES } from './online-protocol.js';
import {
    CHALLENGE_BYTES, CLOSE, HOST_PROTOCOL_VERSION, MAX_CLIENT_MESSAGE_BYTES, MAX_RESERVES_PER_CONNECTION,
    checkinSignedBytes, hostReplySignedBytes, message, releaseSignedBytes, releasedBody, reserveResultBody,
    validAppVersion, validCount, welcomeBody,
} from './protocol.js';
import { MessageBudget } from './ratelimit.js';

const MAX_ID_LENGTH = 64;

export class ClientSession {
    // `ticket` is this socket's admission (admission.js); `linkOnly` marks a ?link=1 connection, which may only
    // become a host link; `guest` a ?guest=1 connection from a browser opening a download link (online-links.js).
    constructor(host, ws, connId, { ticket, linkOnly = false, guest = false }) {
        this.host = host;
        this.ws = ws;
        this.connId = connId;
        this.ticket = ticket;
        this.linkOnly = linkOnly;
        this.guest = guest;
        this.declaredProtocol = 1;
        this.state = 'challenged';
        this.challenge = randomBytes(CHALLENGE_BYTES);
        // The device that checked in, and the person it speaks for (devices.js): the same key before protocol 3 and
        // for a person's first device. Reservations and statistics name the person; connections and budgets the device.
        this.identityKey = null;
        this.identityHash = null;
        this.rootKey = null;
        this.personHash = null;
        this.otherDevices = 0; // the person's other devices its chain authorizes (protocol 3)
        this.proof = null;
        this.listVersion = 0;
        this.reserves = 0;
        this.lastReservation = null;
        this.chain = Promise.resolve();
        this.budget = new MessageBudget({ limit: host.config.limits.messagesPerWindow, windowMs: 10_000,
            clock: host.clock });
        // Online Friends messages (ICE candidates come in bursts) have their own budget, so they never starve
        // check-in and reservations, which keep theirs.
        this.onlineBudget = new MessageBudget({ limit: ONLINE_LIMITS.messagesPer10s, windowMs: 10_000,
            clock: host.clock });
        this.hostLink = null;
    }

    // Only a check-in may be larger than 8 KiB (protocol.js MAX_CHECKIN_BYTES); once there can be none, ws parks no
    // more than 8 KiB of an unfinished message either. ws keeps that limit on the receiver, which this pins (8.22.0).
    limitMessages() {
        const receiver = this.ws._receiver;
        if (receiver && typeof receiver._maxPayload === 'number') receiver._maxPayload = MAX_CLIENT_MESSAGE_BYTES;
    }

    start() {
        if (this.guest) this.limitMessages();
        // `protocol` (from 3): a helper checks in with the devices fields only where the host reads them.
        this.send('challenge', { host_id: this.host.config.hostId, nonce: this.challenge.toString('base64url'),
            time: new Date(this.host.clock.now()).toISOString(), protocol: HOST_PROTOCOL_VERSION });
        // An unauthenticated connection costs memory and proves nothing; it gets one short window.
        this.deadline = setTimeout(() => {
            if (this.state === 'challenged') this.fail('checkin_timeout', 'No check-in arrived in time.', CLOSE.policy);
        }, this.host.config.limits.checkinTimeoutMs);
        this.ws.on('message', (data, isBinary) => this.receive(data, isBinary));
        this.ws.on('close', () => this.closed());
        this.ws.on('error', () => {});
    }

    send(type, fields) {
        if (this.ws.readyState === this.ws.OPEN) this.ws.send(message(type, fields));
    }

    // A reply the helper acts on: the fields plus host_sig over this connection's challenge and `body`.
    sendSigned(type, fields, body) {
        const sig = signEd25519(this.host.config.hostKey, hostReplySignedBytes(this.challenge, body));
        this.send(type, { ...fields, host_sig: encodeBase64url(sig) });
    }

    fail(code, text, closeCode = CLOSE.policy) {
        this.send('error', { code, message: text });
        this.close(closeCode, code);
    }

    close(code, reason) {
        if (this.state === 'closed') return;
        this.state = 'closing';
        try {
            this.ws.close(code, reason);
        } catch {
            this.ws.terminate();
        }
    }

    closed() {
        this.state = 'closed';
        clearTimeout(this.deadline);
        this.host.sessionClosed(this);
        this.hostLink?.closed();
    }

    // The budget a message spends: online Friends messages (and everything a guest sends) have their own.
    budgetFor(msg) {
        const online = this.host.online && (this.guest || ONLINE_TYPES.has(msg?.type));
        return online ? this.onlineBudget : this.budget;
    }

    receive(data, isBinary) {
        if (this.state === 'closed' || this.state === 'closing') return;
        let msg = null;
        try {
            msg = isBinary ? null : JSON.parse(data.toString('utf8'));
        } catch {
            msg = null;
        }
        // Host links carry every check-in a replica sees, so only helper connections have a message budget.
        if (!this.hostLink && !this.budgetFor(msg).allow()) {
            this.host.log('rate_limited', { conn: this.connId, scope: 'messages' });
            this.fail('rate_limited', 'Too many messages; reconnect later.', CLOSE.tryLater);
            return;
        }
        if (msg === null) {
            this.fail('bad_request', 'Messages are JSON text.');
            return;
        }
        const mayBeLarge = this.hostLink || this.linkOnly || (this.state === 'challenged' && msg.type === 'checkin');
        if (data.length > MAX_CLIENT_MESSAGE_BYTES && !mayBeLarge) {
            this.fail('bad_request', 'Only a check-in may be larger than 8 KiB.', 1009);
            return;
        }
        if (!msg || typeof msg !== 'object' || typeof msg.type !== 'string' || !Number.isSafeInteger(msg.v)
            || msg.v < 1) {
            this.fail('bad_request', 'Every message has a type and v.');
            return;
        }
        this.chain = this.chain.then(() => this.handle(msg)).catch((error) => {
            this.host.logError('session', error, this.connId);
            this.fail('internal', 'The host could not handle that message.', CLOSE.tryLater);
        });
    }

    async handle(msg) {
        if (this.state === 'closed' || this.state === 'closing') return;
        if (this.hostLink) {
            this.hostLink.handle(msg);
            return;
        }
        // A ?link=1 connection has the larger host-link message limit, so it may do nothing else.
        if (this.linkOnly !== (msg.type === 'host_hello')) {
            this.fail('bad_request', this.linkOnly ? 'Host links start with host_hello.' : 'Unknown message type.');
            return;
        }
        if (this.guest) {
            this.host.online.links.handleGuest(this, msg);
            return;
        }
        // Online Friends, for helpers that checked in with protocol 2 while FRIENDS_M2 is on; to anyone else these
        // are unknown types, as they always were.
        if (ONLINE_TYPES.has(msg.type) && msg.type !== 'link_open' && this.host.online && this.state === 'checked_in'
            && this.declaredProtocol >= ONLINE_PROTOCOL) {
            this.host.online.handle(this, msg);
            return;
        }
        switch (msg.type) {
        case 'checkin':
            return this.checkin(msg);
        case 'reserve':
            return this.reserve(msg);
        case 'release':
            return this.release(msg);
        case 'host_hello':
            return this.hostHello(msg);
        default:
            return this.fail('bad_request', 'Unknown message type.');
        }
    }

    hostHello(msg) {
        if (this.state !== 'challenged') return this.fail('bad_request', 'Host hello comes first.');
        this.hostLink = this.host.acceptHostLink(this, msg);
        if (!this.hostLink) return this.fail('bad_signature', 'This host is not in the signed host list.');
        clearTimeout(this.deadline);
        this.state = 'linked';
        this.ticket.authenticate();
        return undefined;
    }

    async checkin(msg) {
        if (this.state !== 'challenged') return this.fail('bad_request', 'Check in once per connection.');
        const identityKey = decodeBase64url(msg.identity_key, 32);
        const signature = decodeBase64url(msg.sig, 64);
        const friendsId = msg.friends_id;
        const devices = parseDevices(msg);
        if (!identityKey || !signature || typeof friendsId !== 'string' || friendsId.length > MAX_ID_LENGTH
            || typeof msg.reserved !== 'boolean' || !validAppVersion(msg.app_version)
            || !validCount(msg.protocol, 1000) || msg.protocol < 1 || !validCount(msg.list_version) || !devices) {
            return this.fail('bad_request', 'The check-in is missing a field or has a malformed one.');
        }
        const { hostId } = this.host.config;
        const signed = checkinSignedBytes({ hostId, challenge: this.challenge, identityKey, friendsId,
            reserved: msg.reserved, appVersion: msg.app_version, protocol: msg.protocol,
            listVersion: msg.list_version, ...devices });
        if (!verifyEd25519(identityKey, signed, signature)) {
            this.host.log('checkin_refused', { conn: this.connId, reason: 'signature' });
            return this.fail('bad_signature', 'The check-in signature does not verify.');
        }
        const member = this.host.admitDevice({ deviceKey: identityKey, ...devices });
        if (!member.ok) {
            this.host.log('checkin_refused', { conn: this.connId, reason: member.error });
            return member.error === 'device_revoked'
                ? this.fail('device_revoked', 'This device was removed from its profile.', CLOSE.revoked)
                : this.fail('bad_chain', 'The device chain does not show this device for this root.');
        }
        clearTimeout(this.deadline);
        this.state = 'checked_in';
        this.limitMessages();
        this.ticket.authenticate();
        this.identityKey = identityKey;
        this.identityHash = member.deviceHash;
        this.rootKey = member.personKey;
        this.personHash = member.personHash;
        this.otherDevices = member.others;
        this.proof = checkinProof({ hostId, challenge: this.challenge, msg });
        this.listVersion = msg.list_version;
        this.declaredProtocol = msg.protocol;
        this.host.registerLive(this);
        const result = await this.reserveFor(friendsId, false);
        // Recorded after the reservation: on a replica that sends the summary after the forwarded check-in proof,
        // which the main host must have seen before it counts a summary for this identity (host-links.js).
        this.host.recordCheckin({ identityHash: this.personHash, deviceHash: this.identityHash,
            appVersion: msg.app_version,
            listVersion: msg.list_version, protocol: msg.protocol });
        this.lastReservation = result.reservation;
        if (this.state !== 'checked_in') return undefined;
        const list = this.host.currentListFor(msg.list_version);
        const updateRequired = msg.protocol < this.host.config.minProtocol;
        const body = welcomeBody({ requested: friendsId, reservation: result.reservation, friendsId: result.friendsId,
            updateRequired, hostListPayload: list?.payload });
        // `online` tells a protocol 2 helper whether this host takes online Friends messages (FRIENDS_M2); protocol 1
        // welcomes are unchanged.
        const online = msg.protocol >= ONLINE_PROTOCOL ? { online: Boolean(this.host.online) } : {};
        this.sendSigned('welcome', { reservation: result.reservation, friends_id: result.friendsId,
            update_required: updateRequired, host_list: list, attestation: this.attestationFor(result), ...online },
        body);
        this.host.log('checkin', { conn: this.connId, result: result.reservation, protocol: msg.protocol });
        return undefined;
    }

    // Only with "reserved", for the ID reserved and this connection's key, dated today in UTC. Not covered by
    // host_sig: it carries its own signature, which is what a nearby requester checks.
    attestationFor(result) {
        if (result.reservation !== 'reserved' || !result.friendsId) return null;
        const { hostId, hostKey } = this.host.config;
        return signAttestation({ hostId, hostKey, friendsId: result.friendsId, identityKey: this.rootKey,
            day: utcDay(this.host.clock.now()) });
    }

    reserveFor(friendsId, afterCollision) {
        return this.host.reserve({ identityHash: this.personHash, friendsId, afterCollision, proof: this.proof,
            addressKey: this.ticket.key });
    }

    async reserve(msg) {
        if (this.state !== 'checked_in') return this.fail('not_checked_in', 'Check in before reserving an ID.');
        if (typeof msg.friends_id !== 'string' || msg.friends_id.length > MAX_ID_LENGTH) {
            return this.fail('bad_request', 'A reservation names one Friends ID.');
        }
        this.reserves += 1;
        if (this.reserves > MAX_RESERVES_PER_CONNECTION) {
            this.host.log('rate_limited', { conn: this.connId, scope: 'reserve' });
            return this.fail('too_many_reservations', 'Too many reservations on one connection.', CLOSE.tryLater);
        }
        const afterCollision = this.lastReservation === 'taken' || this.lastReservation === 'invalid';
        const result = await this.reserveFor(msg.friends_id, afterCollision);
        this.lastReservation = result.reservation;
        const body = reserveResultBody({ requested: msg.friends_id, reservation: result.reservation,
            friendsId: result.friendsId });
        this.sendSigned('reserve_result', { reservation: result.reservation, friends_id: result.friendsId,
            attestation: this.attestationFor(result) }, body);
        this.host.log('reserve', { conn: this.connId, result: result.reservation });
        return undefined;
    }

    // Reset Friends. Accepted as the first message (a helper that is not connected opens a connection just for
    // this) or after a check-in. The signature covers this connection's challenge and this host's id.
    async release(msg) {
        const identityKey = decodeBase64url(msg.identity_key, 32);
        const signature = decodeBase64url(msg.sig, 64);
        if (!identityKey || !signature || typeof msg.friends_id !== 'string' || msg.friends_id.length > MAX_ID_LENGTH) {
            return this.fail('bad_request', 'The release is missing a field or has a malformed one.');
        }
        if (this.identityKey && !this.identityKey.equals(identityKey)) {
            return this.fail('bad_request', 'A connection releases only the identity that checked in.');
        }
        const { hostId } = this.host.config;
        const signed = releaseSignedBytes({ hostId, challenge: this.challenge, identityKey,
            friendsId: msg.friends_id });
        if (!verifyEd25519(identityKey, signed, signature)) {
            return this.fail('bad_signature', 'The release signature does not verify.');
        }
        clearTimeout(this.deadline);
        // The person's first device leaving while its chain lists others: the ID is theirs too, so it stays.
        const keepsForOthers = this.otherDevices > 0 && this.rootKey?.equals(identityKey);
        const released = keepsForOthers ? false : await this.host.release({ identityHash: identityHash(
            this.host.config.identitySecret, identityKey), proof: releaseProof({ hostId, challenge: this.challenge,
            msg }) });
        this.sendSigned('released', { released }, releasedBody({ released }));
        this.host.log('release', { conn: this.connId,
            result: released ? 'released' : (keepsForOthers ? 'kept_for_devices' : 'unavailable') });
        this.close(CLOSE.released, 'released');
        return undefined;
    }
}
