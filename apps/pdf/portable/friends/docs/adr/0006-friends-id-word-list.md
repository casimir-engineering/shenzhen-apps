# ADR 0006: Friends ID word list

Status: Accepted by lead; owner review pending. Date: 2026-10-12. Amended 2026-10-12: rule 2.
Brief: § Friends ID. Areas: identity (owner of the list file and ID generator), host (ID syntax), presentation.

## Context

A Friends ID is two words from a 2,048-word list: 4,194,304 IDs, drawn offline at first start, shared
aloud and typed by people in China and elsewhere. The list must be licensed for redistribution, simple,
and free of words that offend, frighten or confuse.

## Decision

**Source: the EFF Large Wordlist for Passphrases** (Electronic Frontier Foundation, 2016,
https://www.eff.org/dice, file `eff_large_wordlist.txt`). Its 7,776 words of 3 to 9 letters were chosen
from Ghent University word-familiarity data for recognisability and concreteness, and EFF already removed
profane, insulting, sensitive and emotionally charged words, homophones, hard-to-spell words and any word
that is a prefix of another. We select 2,048 of them and change none.

**License, verified at the primary source on 2026-10-12.** https://www.eff.org/copyright: original
material on the site may be freely distributed under Creative Commons Attribution; the page text names
CC BY 4.0 International and its badge links CC BY 3.0 US. Either version is permissive and asks only for
attribution, a link to the license and a note of changes, which the attribution below satisfies.

**Attribution**, in the list file's header, in the helper bundle's notices and in the repository's
`NOTICE.md`:

> Friends ID words are a selection from the EFF Large Wordlist for Passphrases by the Electronic Frontier
> Foundation (https://www.eff.org/dice), used under CC BY 4.0
> (https://creativecommons.org/licenses/by/4.0/). Changes: 2,048 of its 7,776 words selected; none altered.

**Curation rules.** Rules 1 to 5 are mechanical and enforced by the word-list test; 6 to 9 are reviewed.

1. Exactly 2,048 unique entries, sorted, lowercase `a` to `z` only, 3 to 8 letters.
2. Unique first five letters (the whole word for shorter words), and no word that begins another, so five typed
   letters, or all of a shorter word, identify a word.
   *Amended 2026-10-12 by the lead: the rule said four letters. With four, the EFF list and rules 3 to 9 gave
   1,913 words, and the 135 that filled the list to 2,048 were mildly negative, informal or technical (error,
   jinx, gossip, unsigned). Five letters let compound and longer everyday words such as backyard (beside
   backpack), candy (beside candle) and doorknob (beside doorbell) replace them. Typo safety is unchanged: rule 3
   still holds between every pair. The EFF list has no word that begins another, so that clause removes nothing
   today; it is checked so the promise survives a change of source.*
3. Edit distance of at least 2 between any two words, so one typo never turns an ID into another valid one.
4. No word that is a plural, past tense, `-ing` or `-er` form of another listed word.
5. No pair that differs only by `l`/`r` or `n`/`l` (light and right, night and light), which some Chinese
   speakers of English, Cantonese speakers especially, find hard to tell apart; keep at most one of each.
6. Simple: words a beginner English learner knows; prefer concrete nouns and plain adjectives.
7. Nothing offensive, violent, frightening, sexual, medical, religious, political or ethnic; nothing about
   bodies, age, weight or looks, because an ID labels a person; no drugs, alcohol, gambling, crime, death,
   disasters, money or debt.
8. Nothing technical or brand-like: no computing, finance or science jargon, trademarks, proper nouns or
   abbreviations.
9. Nothing easily confused: no remaining homophones or near-homophones, no British/American spelling pairs.
   Reviewers also read 500 randomly generated IDs for unfortunate combinations.

**Format and versioning.**

- One word per line, after `#` header lines carrying list version, source, license and attribution. The
  identity area chooses the path under `friends/service/identity/`.
- The helper pins the SHA-256 of the v1 word lines; any change fails a test, so a new list is always a
  deliberate new version.
- IDs are stored and sent as text (`walnut-valley`), never as list indexes, so later versions cannot
  reinterpret existing IDs.
- A released version is frozen. A later version may add words or retire words from new draws; parsing
  accepts every word any released version contained, so no existing ID stops working. The host checks
  syntax only (ADR 0005).
- Shown as lowercase words joined by `-`. Input accepts any case and spaces, hyphens, dots or underscores
  between words, trims whitespace, and normalises to the shown form.
- Each word is drawn with libsodium's `randombytes_uniform(2048)`.

**Three-word threshold.** The first ID is drawn offline before any host contact, so the chance that it is
already taken equals the occupancy of the two-word space, and each collision renames an ID its owner may
already have shared nearby.

- When reserved two-word IDs reach 1/32 of the space (131,072 IDs, about a 3% rename chance for a new
  install), the admin publishes a host list with `new_id_words: 3`; the dashboard draws occupancy against
  this line. New installs and every collision retry then draw three words (8,589,934,592 IDs). Bundled
  lists carry the value, so later releases start new installs with three words offline.
- A client whose reservation collides three times in a row draws three words from then on, whatever its
  list says, which covers a stale list.
- Existing two-word IDs stay valid indefinitely.

## Alternatives considered

- **BIP-39 English** (MIT, per the BIP's own License field): exactly 2,048 words with unique four-letter
  prefixes, but it includes words such as bomb, gun, weapon, assault, prison and disease, plus "satoshi",
  and reads like a crypto seed phrase. Replacing roughly 200 words would need a second source anyway.
- **EFF short lists** (1,296 words): too few for two-word IDs.
- **Corpus frequency lists**: licenses unclear or restrictive.

## Consequences

- The attribution must ship wherever the list ships (app bundle notices, repository notices).
- Curation is a one-time manual job with a mechanical test behind it; the owner signs off the final list.
- With three-word IDs, IDs get longer for new installs only.

## Verification

- Word-list test: rules 1 to 5, the SHA-256 pin, and the attribution header present.
- ID tests: normalisation table (case, separators, whitespace; unknown words and one- or four-word input
  rejected), uniform draws through an injected random source, the switch to three words on the list value
  and after three consecutive collisions.
- Host harness: dashboard occupancy against the 1/32 line.
- Before release: the owner approves the list and the 500-ID sample.
