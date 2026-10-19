# ADR 0007: Mentions

Status: Accepted by lead, 2026-10-13.
Brief: § Interface, Mentions. Areas: presentation (mention form, resolution, catalog), helper (writing mentions,
checking them on arrival, Add from a mention), client protocol (PROTOCOL.md § Mentions, the client builders).

## Context

`@` in a friend's composer names one of the person's friends inside a message. The recipient may or may not know the
person named, so a mention must carry enough to find them (their Friends ID, their identity key) and to show them
(a name), and each reader must see it resolved against their own Friends list: their own name for a friend, which
opens that chat; a stranger under the sender's name, never the ID, with a way to add them; and a forgery (a friend's
ID under someone else's key) as plain text. Views must never write IDs or keys, and the store and search keep a
message as one plain string, as do the session frames (ADR 0001: one MSG frame, 32 KiB of text).

## Decision

**Form on the wire and in the store.** A mention is part of the message text, a Markdown link with Friends' own
scheme: `[@Mei Lin](szfriends:mention?id=jasmine-street&key=<base64url key>)`. The link text is "@" and the name the
sender sees (their name for the friend, else the Friends ID with U+2011), at most 64 Unicode scalars on one line, with
a fixed set of Markdown punctuation backslash-escaped; the destination holds the Friends ID and the 32-byte identity
key in base64url without padding, in its one canonical spelling. Only that exact form is a mention, so two mentions of
one person are the same text and nothing hides in an unusual escape. One implementation of reading and writing it
(`service/presentation/SZFriendsMentions.{h,m}`, Foundation only) serves the helper and the presentation.

**Composing: the helper writes mentions.** `send_message` carries `mentions`, one `{conversation_id}` per `@` chip,
and its text holds U+FFFC once per chip, in order. U+FFFC is what both AppKit and GTK text views already put where an
inline chip sits, so a composer's serialisation is direct. The sending helper first turns every Friends link the
person typed into plain text, then writes the n-th friend's mention, from its own store, in place of the n-th U+FFFC.
A mention therefore always carries the key this Mac knows for that friend, and no view handles an ID or a key. Only
friends with a Friends ID can be mentioned; at most 20 per message.

**Arriving: the receiving helper checks.** Before storing a message, the helper keeps a mention only if it is
well-formed and its ID's words are in the list, and keeps at most 20; every other link to `szfriends:` (malformed, a
21st, another Friends link, an autolink, a reference definition) is stored as the plain text it showed. The search
for links starts from each "szfriends:" occurrence, so ordinary messages cost one substring search and a hostile one
a bounded amount of work per occurrence.

**Resolving: the presentation, per reader.** Snapshots resolve each mention against the same facts they show
(`SZFriendsMentionDirectory`): by identity key only, a friend shows the reader's own name for them and links to their
conversation; the reader's own key shows their own name; any other key shows the sender's name with a card (Add,
Request sent, Accept/Decline/Block, Blocked, or "no longer matches" when the Friends host vouched the ID is now
another key's); a key that is not a friend's under a friend's or the reader's own ID is plain text. The message item's
`text` carries each shown mention as `[@Label](szfriends:mention?ref=n)` and `mentions[n]` describes it, so views
compare a clicked link's destination with `url` and never parse it; IDs and keys reach a view only on the stranger
card's Add action, which has to send them. List previews and search excerpts show "@Name"; a search hit that matched
only a mention's destination is dropped. Clients that do not declare the `mentions` capability get every mention as
literal text, so views that predate mentions never meet a `szfriends:` link.

**Add from a mention: an Add by ID bound to the key.** `add_from_mention {friends_id, identity_key, name}` runs the
Add by ID flow of ADR 0004, nearby (and online with M2), but only the mentioned key may answer. The request's row holds
that key from the start (so the answer comes back to it and the card says Request sent), and the request token is
`BLAKE2b-128(key = the request's callback secret, "SZFriends mention request v1" || identity key)`. The callback
secret never leaves this Mac, so the token stays unpredictable; a token that hashes the row's key marks the request
as bound, and the listener's key policy refuses any other identity key presenting it before a session starts, whoever
holds the ID. Add by ID's random tokens match that hash with negligible probability, so they keep admitting any
holder. The binding needs no store change. When the person's own data already gives the ID to another key (their
own ID, a friend's, or one the Friends host vouched for), nothing is sent and the reply is `mention_mismatch`. The
answer is then taken as any answer to Add by ID is: one the host did not vouch for waits for the requester's
acceptance (ADR 0004, Review amendments).

## Alternatives considered

- **Mentions beside the text** (an array of ranges into the text, carried in the session frame): the store and
  search would need a second field, offsets would differ between UTF-16, UTF-8 and scalar counts across toolkits and
  a later Linux helper, and an edit to the text would silently shift every range.
- **Views write the canonical link**: every view would handle IDs and keys and could write any key; the helper could
  no longer promise that a mention carries the key it knows for that friend.
- **A placeholder token in text such as `@{1}`**: it collides with what people type (code, templates); U+FFFC is what
  text views already insert for a chip and nobody types it.
- **A store column for the bound key**: clean, but a schema migration for one value the token can carry, while other
  areas change the schema in the same wave.
- **Treating a bound answer as a friendship at once**: tempting, since only the mentioned key can answer, but the
  mention is the sender's claim about that key, so the requester still accepts the answer as for any Add by ID.

## Consequences

- A mention inside a Markdown code span or block shows there as its link's source, which names nobody's ID or key.
- The stored text keeps each mention's ID and key, so the full-text index holds them; the excerpt drops hits that
  matched only there, which can leave a page of results shorter than asked. Folding mentions to their labels in the
  index belongs to the store and would fix both.
- In M1 the Friends host cannot be asked who holds an ID, so "no longer matches" is known only from attestations this
  Mac has seen; an answer from the attested holder with another key is refused at the listener without being recorded.
- A host whose helper does not announce `mentions` must not offer `@`: an older helper would ignore `mentions` and
  send each U+FFFC as text.

## Verification

- Presentation suite: the exact written form, names with Markdown punctuation and 64-character limits, every
  malformed form and other Friends link becoming text on arrival, the 20-mention limit, typed links neutralised, a
  hostile 32 KB message staying quick; every resolution and card state, the golden
  `conversation-daniel-mentions.json`, clients without the capability, previews, search excerpts and the replies.
- Client suite: the `send_message` mentions and `add_from_mention` builders against `fixtures/intents.jsonl`.
- Two-helper harness: Ana mentions Cleo to Ben, who adds her from the mention while a second holder of Cleo's
  unreserved ID is refused; a peer's forged and malformed mentions show as plain text and search finds nothing behind
  them.

## Corrections

Recorded on 2026-10-13, wave 6b.

- **Search no longer holds IDs and keys.** The store now folds each message as a reader sees it, every mention as its
  "@Name" label (ADR 0003, Corrections), so the full-text index holds no mention's ID, key or scheme, nothing is found
  through them, and match ranges cover labels only: a page of results is no longer cut short. The second Consequence
  above no longer applies. Search matches the name the sender wrote; the excerpt shows each mention resolved for the
  reader, so a friend the reader calls by another name is found by the sender's name for them, not the reader's.
