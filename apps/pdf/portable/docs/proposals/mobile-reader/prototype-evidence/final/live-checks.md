# Root-operated live browser checks

24 September 2026. Codex in-app browser controlled through CUA. These are manual/model-operated UI observations, not native Android tests or a benchmark. Initial round-6 source hashes are in `source-hashes.json`; subsequent corrections receive a separate final hash record.

| Flow | Observation |
|---|---|
| PDF → tap Switch → EPUB | EPUB title, passage and chapter progression shown |
| EPUB → Contents → Escape | EPUB chapter identity; focus returns to Contents |
| EPUB → Collection → another PDF menu → Escape → Reader | Menu focus restored; active reader remains EPUB |
| EPUB → More → History | EPUB document title and format shown |
| Groups → Create → Escape | Focus returns to Create group |
| Groups → Search everything → quiet | Two sample text results, scoped section and highlighted terms |
| Find → zzznomatch / light | No matches / two real sample DOM matches respectively |
| Find → second Light match → Return | Visible word highlight; Return clears match and restores reading origin |
| Switch sheet → Escape | Focus returns to Switch |
| Collection → quiet → result | Filtered sample documents; result opens reader directly, not History |
| History → 12 September → More → Save a copy | Header/footer/export all identify 12 Sep 2026 |
| Stale match fixture | Exact dated saved version, visible match, Open latest action |
| Storage cleanup | 312+48 MiB → 286+12 MiB = 298 MiB; 62 MiB reclaimed |
| 200% consent at 360×800 | All text enlarged; Keep copies/Not now reachable and work; button font 28px versus 14px normal |
| 200% History | Third dated row reachable and opens 12 Sep |
| 200% Storage | Review cleanup and Cancel reachable; returns focus to Review cleanup |
| 200% Groups/switcher | Text reflows; page width remains 360px; screenshots retained |
| Wheel at 412×915 | Center → northeast drag selects EPUB; source display agrees |

## Failures caught before final approval

Round 5 found context/menu state coupling, partial rather than genuine 200% typography, generic focus restoration, missing global search and inconsistent revision dates. These were corrected for round 6.

Round 6 caught dark foreground inheritance, recovery Return still pointing to unverified bytes, and History-row export using the active revision. These are explicitly failures in this evidence snapshot, not passes. The final critic report and additional screenshots record their corrections.

The original 21-check fixture harness and its PNGs predate these changes. They remain historical evidence only. New screenshots under this folder are root-CUA captures, not native app screenshots. No desktop app was launched.

## Round 7 corrections observed live

- Dark header, status, document title and bottom navigation are visibly readable in `dark-corrected.png`.
- Recovery: explicit unverified 24 Sep → Return to latest verified now shows Latest verified · 18 Sep 2026, removes the unverified warning and keeps Find original.
- History 18 Sep row → Save a copy now says 18 Sep 2026 version, while dismissal returns to unchanged History.
- Browser console reported no errors/warnings in this final check.

These observations match `source-hashes-round7.json`. No native performance claim is added.

## Round 8 final observations

Direct export from the unopened unverified-only recovery sheet now identifies **24 Sep 2026 version · source consistency unverified**. Dismissing returns to Groups without opening a document. History-row export still identifies **18 Sep 2026 version**. Final screenshots are `unverified-export-final.png` and `dark-final.png`; exact source hashes are in `source-hashes-final.json`.
