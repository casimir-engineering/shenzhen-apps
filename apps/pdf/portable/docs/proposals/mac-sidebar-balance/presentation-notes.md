# Sidebar balance — presentation and evidence

The user-facing entry point is [index.html](index.html). No external fonts, images or services are required.

## What changed

The preferred layout preserves full-width vertical icon-and-text modes. Navigation becomes compact and neutral while enabled text retains equal contrast. Groups replaces its stacked summary/search header and permanent explanatory footer with search above the list and counts plus contextual help below. Smaller group/document rows recover actual content height. No sidebar-width setting or group navigation behavior changes.

History removes its repeated heading and action tower. Revisions appear before recovery actions in a short panel. Compact comparison, Keep and Actions controls retain the existing destinations. Its56pt rows put the full date first, time/Latest second, and reason/size third, so the date does not compete with a badge at minimum width.

## Evidence types

- **Native headless renders:** files in `native/` instantiate production AppKit controls in hidden windows. These establish actual component geometry and appearance. The minimum fixtures assert their requested176pt width after layout. They do not show the user's running app.
- **Before renders:** `baseline/groups-pdf-short.png` and `baseline/history-short-window.png` are copied unmodified from the collection-implementation journal. Groups before/after is matched at220×340pt with five PDF modes. History before is220×300pt and after is176×296pt; the gallery states that difference beside the pair.
- **Whole-reader CSS illustrations:** `comparison.html` and `evidence/proposal-*.png` are design mockups, not native integration captures. Their purpose is to compare reader/sidebar proportions at the same illustrated document/window size. They cannot establish AppKit scrolling, focus, truncation or persistence.
- **Retired illustration:** `evidence/proposal-a-history-minimum.png` preserves an earlier failed CSS proposal for the review trail. It showed no revision at minimum height and must not be presented as the implemented result. The live comparison routes History to native evidence instead.

## Verification and limits

Four focused sidebar suites and25 UI integration suites pass, with the final journal recording the commands and scope. Native rendering and tests remain separate from live-app interaction. Native Groups at176×296pt has an81pt content viewport starting at193pt, enough for two full36pt group rows including spacing. The copied baseline does not contain an identically narrow fixture, so no fabricated before measurement is claimed for that exact size.

The gallery includes light, dark, minimum width/height, hidden-and-active, empty History and scrolled History actions. Tall edge-state examples have scrollable image containers and link to full-resolution PNGs. No native file or user session is modified by gallery controls.

No app was launched, quit or captured for this work. VoiceOver speech and live trackpad feel are outside the headless evidence. Final independent review scores belong to the review documents; this presentation does not promise a score or treat it as a substitute for evidence.
