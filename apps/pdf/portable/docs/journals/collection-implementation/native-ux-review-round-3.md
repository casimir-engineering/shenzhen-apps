# Native Collection redesign — independent UX review, round 3

23 September 2026 · **9.2 / 10** · Accepted for the reviewed native flows. **No major or medium finding remains.**

The actual AppKit interface now follows the approved mockup's hierarchy and restrained styling: quiet icon navigation, full-width document rows, contextual multiline matches beside real thumbnails, trailing History actions, secondary operations in menus, and clearly divided Settings sections. The previous exact-version, search-editor, navigation-accessibility and pending-policy defects are closed through actual native retests. This is a native-app score, not the mockup's score.

## Candidate and method

I used only `portable/build/collection-native-review/ShenzhenPDF Collection Final.app`, bundle identifier `engineering.casimir.shenzhenpdf.collectionnative20260923v3`, with isolated `state-v3` and disposable fixture data. Root identified the candidate as `6d6b16b9c` plus `9680e3d48`; native build and focused tests had passed before handoff. I made no production edits, did not quit or restart any app, and did not manipulate the user's regular instance.

The fresh process opened the persisted Settings destination with Unlimited applied. I then tested Documents search, exact older-version entry twice, Back/Escape, focused and empty search field geometry, accessible navigation names, pending custom-limit behavior and a reversible finite-limit application. Screenshots below are native app captures. Nominal 940×560 and 1100×690 content geometry is covered by the implementation's headless checks; screenshot pixel dimensions are not asserted to be exact content bounds.

## Final native views

![Documents browsing follows the approved full-width layout](assets/native-final-documents-dark.jpg)

![Contextual search: readable page labels, highlighted terms and exact saved-version identities](assets/native-final-search-dark.jpg)

![The older saved page opens with its date, Keep state and actual content](assets/native-final-history-dark.jpg)

![Settings: unlimited default, explicit policy and a single location](assets/native-final-settings-dark.jpg)

## Round-two findings closed

**NUX-4 — exact saved version/page: closed.** From `orchid` with All saved versions, activating the older **13:42 · Kept** page-two context now opens History on the older **13:42** version at page **2**. The rendered text says the shelf faces **east**, with `orchid` highlighted. Latest remains the separate 13:44 revision. After Escape, clearing and re-entering the query, the same older hit again opens the correct revision/page. The original failing candidate instead selected the latest page one; that failure was not reproduced in this replacement.

**NUX-5 — focused search geometry: closed.** Typed query, selected query and empty placeholder are centered vertically after the magnifier. Cmd+F selects the Collection query, and clearing/retyping works. The field's visible focus indicator remains intact.

**NUX-6 — navigation names: closed.** The native accessibility tree now reports explicit **Documents** and **Settings** toggle-button descriptions together with their on/off states, instead of `copy` and an unnamed button.

**NUX-7 — pending cap policy: closed.** Selecting Custom limit shows the proposed least-opened/older-versions-first policy. Editing 10 GB to 5 GB retains **Pending change · Apply to review. Applied limit: Unlimited.** Applying the non-destructive 5 GB cap changes the status to **Applied limit: 5 GB**, and a read-only manifest check confirms `storageLimitBytes: 5000000000`. I then selected and applied Unlimited again; the UI returned to **Applied limit: Unlimited**. This validates both draft clarity and persistence without deleting any copies.

![Finite draft describes its proposed cleanup policy and identifies the still-applied unlimited setting](assets/native-final-pending-limit-dark.jpg)

## Visual acceptance and minor residuals

The removed options tower was the main visual mismatch in round one. Its replacement gives filenames, capture identity, preview and matches the space and hierarchy seen in the approved mockup. Flat 26-point controls, subdued slate selection, thin separators, smaller sidebar caption and consistent body typography now form one coherent native screen. History keeps the protection explanation adjacent to Keep, and its Actions menu avoids returning to an equally weighted button wall. Settings has a clear Collection→Storage→Location reading order.

Two minor polish details remain in this observed build:

1. The selected History row's right rounded edge appears clipped beside the scrollbar. All exercised metadata remains readable. Root is addressing the table-to-clip-view sizing with a focused geometry check; that later adjustment is not claimed as a live retest here.
2. A single browsing result says **1 items**. Use singular wording for one result.

Neither residual prevents finding a document, identifying its revision, navigating history or understanding applied storage behavior. No additional major or medium issue appeared during the targeted final review.

## Coverage boundaries

Round two already exercised actual export-sheet cancellation, all secondary menu actions' availability, protected-cap refusal, explicit cleanup review/cancellation and restoration of fixture Keep. It also confirmed the resize fix preserves the highlighted matching sentence in a shortened History viewport. Those flows were not needlessly repeated after the targeted changes.

I inspected app menus for a local Collection appearance switch. They expose a reader theme switch, not a Collection UI appearance override; I did not change the Mac's global appearance. Live light-appearance review remains outside coverage. Live PDF History, completed comparison rendering, completed relocation/export, destructive cleanup, exhaustive keyboard traversal and a same-bundle quit/relaunch cycle also remain outside this review. Fresh-process persisted destination restoration and actual on-disk cap persistence were observed. The accepted **9.2 / 10** reflects the exercised native experience and stated limits, not exhaustive product validation.


## Final candidate polish follow-up

After the two minor fixes, the critic launched the separate V4 candidate and confirmed the earlier version and Page 2 restored in a fresh process. Both right selection corners render fully; a single Documents result reads **1 item**. Both minor residuals above are closed. This targeted live follow-up leaves the **9.2/10** acceptance unchanged. The final Documents and History images in the action journal reflect V4.
