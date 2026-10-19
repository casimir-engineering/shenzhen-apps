// The sid table's indexes: which sids each connection and each other host takes part in, and how many sids each
// connection opened, kept in step with every change so a connection closing or a flood of opens never scans every sid.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { SidTable, localEnd, remoteEnd } from '../src/signaling.js';
import { FakeClock } from './helpers.js';

function scan(table, end) {
    return [...table.entries.values()].filter((entry) => table.place(entry, end)).map((entry) => entry.sid).sort();
}

function indexed(table, end) {
    return table.involving(end).map(({ entry }) => entry.sid).sort();
}

test('the indexes agree with a full scan through opens, deliveries, answers, departures and deletions', () => {
    const table = new SidTable({ clock: new FakeClock(), lifetimeMs: 120_000, waitMs: 1_800_000 });
    const [alice, bob, carol] = ['a', 'b', 'c'].map((name) => ({ name, identityHash: Buffer.from(name) }));
    const ends = { alice: localEnd(alice), bob: localEnd(bob), carol: localEnd(carol), sg: remoteEnd('alt-sg') };
    const one = table.create({ sid: 's1', a: localEnd(alice), via: 'rdv' });
    const two = table.create({ sid: 's2', a: localEnd(alice), via: 'rdv' });
    const three = table.create({ sid: 's3', a: remoteEnd('alt-sg'), via: 'rdv', originHere: false });
    table.deliver(one, localEnd(bob));
    table.deliver(one, localEnd(carol));
    table.deliver(one, remoteEnd('alt-sg', 'ff'));
    table.deliver(two, localEnd(bob));
    table.deliver(three, localEnd(carol));
    const check = () => {
        for (const end of Object.values(ends)) assert.deepEqual(indexed(table, end), scan(table, end));
    };
    check();
    assert.equal(table.openedBy(alice), 2);
    assert.equal(table.openedBy(bob), 0);
    assert.deepEqual(table.withRemoteEnds((id) => id === 'alt-sg').map((e) => e.sid).sort(), ['s1', 's3']);

    const others = table.choose(one, one.waiting.find((end) => end.session === carol));
    assert.equal(others.length, 2);
    check();
    assert.deepEqual(indexed(table, ends.bob), ['s2']);
    assert.deepEqual(table.withRemoteEnds((id) => id === 'alt-sg').map((e) => e.sid), ['s3']);

    table.forget(two, two.waiting[0]);
    check();
    assert.deepEqual(indexed(table, ends.bob), []);
    assert.equal(table.byEnd.has(bob), false, 'nothing left filed under a connection with no sids');

    table.delete('s1');
    table.delete('s1');
    check();
    assert.equal(table.openedBy(alice), 1);
    table.delete('s2');
    table.delete('s3');
    check();
    assert.equal(table.openedBy(alice), 0);
    assert.equal(table.byEnd.size, 0);
    assert.equal(table.opened.size, 0);
});
