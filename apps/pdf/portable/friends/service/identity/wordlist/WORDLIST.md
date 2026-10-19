# Friends ID word list, version 1

`friends-id-words-v1.txt` holds the 2,048 words Friends IDs are made of (`maple-river`). The helper compiles it
into its executable and refuses it unless it is version 1, exactly 2,048 valid words, and matches the SHA-256 pinned
in `SZFriendsWordList.m` (`SZFriendsWordListV1Digest`). The decision behind it is
[ADR 0006](../../../docs/adr/0006-friends-id-word-list.md).

**Status: owner review pending.** Rules 1 to 5 hold and are enforced by `make -C portable friends-identity-check`.
Every word meets rules 6 to 9: since rule 2 moved from four letters to five (2026-10-12), the list no longer needs
words from below the bar; see [Changes on 2026-10-12](#changes-on-2026-10-12). Version 1 is not released, so words
can still change; after release it is frozen.

## Source

| | |
|---|---|
| Work | EFF Large Wordlist for Passphrases, Electronic Frontier Foundation, 2016 ([eff.org/dice][dice]) |
| File | https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt |
| Retrieved | 2026-10-12, from eff.org only; `Last-Modified: Mon, 18 Jul 2016 22:41:51 GMT`, 108,800 bytes |
| SHA-256 | `addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e` (published for this file since 2016) |
| Checked | 7,776 lines of dice digits and a word, dice in order, words sorted and unique (`curate.py`) |
| License | Creative Commons Attribution, per https://www.eff.org/copyright (verified 2026-10-12; see ADR 0006) |

[dice]: https://www.eff.org/dice

The file itself is not kept in the repository: `curate.py` verifies a downloaded copy against the digest above.

## Attribution

This text travels in the list's header, and must ship in the helper bundle's notices and the repository's
`NOTICE.md` (the lead's integration step):

> Friends ID words are a selection from the EFF Large Wordlist for Passphrases by the Electronic Frontier
> Foundation (https://www.eff.org/dice), used under CC BY 4.0
> (https://creativecommons.org/licenses/by/4.0/). Changes: 2,048 of its 7,776 words selected; none altered.

## How the list was made

1. Mechanical eligibility: of the 7,776 words, 6,216 are 3 to 8 letters a-z (the four with hyphens and every
   9-letter word drop out). They fall into 5,184 groups by first five letters; rule 2 allows one word per group.
   No EFF word begins another, so rule 2's second clause removes nothing.
2. Hand review (`review-v1.txt`): one word per group is accepted and given a tier (a few groups name an alternate
   for when the first loses to rule 3); every word not named there was rejected. The first pass grouped by four
   letters. When rule 2 moved to five, the 1,419 five-letter groups that split off from accepted four-letter groups
   were reviewed by the same rules, and 172 words were added; they are the block marked 2026-10-12 in the review.
   Groups with no accepted word were not reopened: the first pass had rejected every word in them. Rejected
   outright: offensive or insulting when it labels a person; violent, frightening, sexual, medical, religious,
   political or ethnic; bodies, age, weight and looks; drugs, alcohol, gambling, crime, death, disasters, money and
   debt; computing, finance and science jargon, brands, proper nouns, abbreviations; homophones and British/American
   spelling pairs (`cozy`, `chili`, `catalog`, `tidbit` went for that reason, `rubber` and `perky` for their second
   meanings, `whole` for sounding like *hole*).
3. Selection (`curate.py`): tiers 1 to 6 in full, keeping the word that blocks fewer others when two collide under
   rules 2 to 5; then tier 7, and after it tier 8, strictly in the order written until the list holds exactly
   2,048. Tier 7 is written best first, so the reviewer's order decides which unusual words make it: the list fills
   19 words into tier 7 and takes nothing from tier 8.
4. `curate.py` checks rules 1 to 5 once more on the result, writes the file with its header, and writes
   `sample-500.txt`.

| Tier | Meaning | Reviewed | In the list |
|---|---|---|---|
| 1 | simple concrete nouns and plain adjectives a beginner knows | 179 | 171 |
| 2 | simple, slightly less common | 367 | 331 |
| 3 | known to an intermediate learner | 715 | 618 |
| 4 | less common but neutral | 427 | 389 |
| 5 | neutral function words, verbs and abstract words | 330 | 282 |
| 6 | neutral, plain only to a fluent reader | 253 | 238 |
| 7 | acceptable under rules 7 to 9 but unusual | 36 | 19 |
| 8 | below the bar: mildly negative, informal or technical | 184 | 0 |

Reviewed words in tiers 1 to 6 that are missing from the list lost to rule 3 (edit distance): short words collide
constantly (`parrot` and `carrot`, `glass` and `grass`, `coat` and `boat`), and only one of each pair can stay. The
last 17 words of tier 7 and all of tier 8 are missing because the list is full without them.

## Changes on 2026-10-12

The first draft of version 1 kept rule 2 at four letters. ADR 0006's rules and the EFF list then gave only 1,913
words that met rules 6 and 7, and the last 135 came from tier 8: mildly negative, informal or technical words such
as `error`, `jinx`, `gossip`, `argue` and `unsigned`. The lead moved rule 2 to five letters (ADR 0006), and 172
newly reviewed words took the place of those 135 and of 37 weaker ones. The same pass moved 17 tier-7 words down to
tier 8 as negative (`amiss`, `awry`, `atypical`, `excuse`, `ditch`), frightening (`alarm`) or technical (`barcode`,
`battery`, `bleach`, `screen`, `wiring`, `operator`, `segment`, `cobalt`, `aeration`, `drainage`, `tubeless`), and
wrote tier 7 best first.

Removed, 172: the 135 tier-8 words, the 17 moved down, 17 from the end of tier 7 (`acts`, `effects`, `ended`,
`gauging`, `goes`, `halved`, `obscure`, `outmatch`, `rare`, `thorn`, `unaired`, `uncross`, `unguided`, `unsmooth`,
`unvocal`, `viable`, `why`), and three that lost to a new word under rule 3 (`clatter` to `platter`, `roster` to
`poster`, `swoop` to `scoop`):

> acts aeration alarm amiss argue atypical awry badland barcode barterer battery blah bleach bleep bunt cahoots
> calcium carbon cavalier chummy clatter clench climate clunky cobalt cryptic cushy dandy darling deskwork disband
> disjoin ditch doozy dragster drainage driller droop edgy effects elope empty ended error excess excuse faculty
> feisty fidgety flail flypaper frayed gaffe gauging gawk getup gimmick gizmo gnarly goatskin goes gooey gossip
> gothic groggy grumble grunge gutter halved hatless hazy helium huff hybrid impish irk jarring jinx jitters lagging
> laptop lesser lurch mobility monitor mundane murky nutlike obscure okay online oops operator ought outmatch oxygen
> palpable pang peculiar pledge porous posh pungent purist quadrant quirk rally rants rare rickety rigid rimless
> rival roster ruckus ruse scant screen scuff sector segment sessions shun sighing sinuous sludge slush smitten
> snazzy snippet species spill spree sputter stained staunch stoic stony stupor subdued swagger swoop tattered
> theorize thorn trekker tribute trifle trivial tubeless unaired uncross uneven ungraded unguided unknown unnamed
> unproven unranked unsigned unsmooth unvocal vendor venture viable virtuous why wilt wiring yeah yippee yummy

Added, 172:

> action anteater applause backdrop backrest backspin backyard bakeshop buckle bullfrog bullpen bullseye bunkmate
> campsite campus canal candy caravan cattail change chariot charm cheer circus cocoa collie comfort common company
> concrete constant corncob cornhusk cornmeal correct cottage creamer crease crumb cyclist daybed decade delivery
> dingo discuss doorknob doorstep doorway duration edition eleven entryway equal explain florist fondness foothill
> footnote footpath footrest footwear freehand freely gallon garland gladly glimpse glowing gracious granola
> greeting handmade handrail handsaw hardhat hardy headband headrest helper humming karate landing launch lettuce
> macaw magnify marina moonlit moonrise moonwalk outlast outsmart overall overlook overpass overtime panther
> parakeet parkway parsnip partner passage passerby pastel pastime pasture patience planner platter playpen playroom
> playset playtime poster pristine pushpin radio railcar railing ravine reassure reforest relative reliable reminder
> reverse sandbox sandlot satisfy scoop shelter shingle showcase sixth snowcap snowdrop snowfall snowshoe snowy
> speech spinner spirited squeeze squiggle stardust starlit starry starship street strength stretch strum student
> study sublime supply support surfer thrive trickle tropical uncommon uncover unicycle upriver upstream various
> verse violet vision wildcat willing

Words a reviewer may still question, kept on balance: `spider` (feared by some), `turkey` (also a country), `aloha`,
`amigo` and `parmesan` (loanwords), `grass`, `ice` and `speed` (slang second meanings), `kick`, `floss` and
`gargle`; from the new words, `karate` (a martial art, like `judo` already in the list), `squeeze` and `patience`
(which sounds like *patients*; someone who types that gets an unknown word, never another person's ID). `fifty`
was left out because it is easily heard as `fifteen`, which is in the list.

## The 500-ID sample

ADR 0006 asks reviewers to read 500 random IDs for unfortunate combinations. `sample-500.txt` holds them, drawn
with a fixed seed so the owner reads the same 500 the maintainer did.

## Reproducing or changing the list

```sh
mkdir -p /tmp/eff && curl -sS -o /tmp/eff/eff_large_wordlist.txt \
    https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt
cd portable/friends/service/identity/wordlist
python3 -I curate.py --eff /tmp/eff/eff_large_wordlist.txt --review review-v1.txt \
    --out friends-id-words-v1.txt --sample sample-500.txt
```

`curate.py` refuses an EFF file with any other digest. It prints the new word-lines digest; a changed list means a
new `SZFriendsWordListV1Digest` (or, after release, a new version file and pin), and `friends-identity-check`
fails until the two agree.
