# Writing release notes

Release notes are read by people updating from the **last published release** of that app. They know that version
and nothing else: not our branches, test builds, local installs or bugs we found and fixed along the way. Every line
must be true and useful from where they stand.

## The rule

A line belongs in the notes only if someone using the last published release will notice the difference after
updating.

So, never write about:

- **A bug that was never released.** If a problem appeared and was fixed between two releases, nobody outside had it.
  Describe the finished feature as it now works; don't mention the fix. A new feature's bugs are not news.
- **A problem that never existed for them.** Don't promise the absence of something they never saw: "you're never
  asked to save" is noise if the app never asked.
- **Another platform's or app's change.** A Windows fix doesn't go in the Mac notes; a Shenzhen 3D change doesn't go in
  ShenzhenPDF's, even when the code is shared (Friends, the helper).
- **Internal work.** Tests, refactors, release tooling, build or helper numbers, CI, speed-ups nobody can feel.

## How to check each line

1. List what changed: `git log <last-release-tag>..HEAD -- apps/<app>` plus the shared code the app ships.
2. For every candidate line, name the published version where the old behaviour can be seen. If you can't, because it
   only ever existed in an unreleased build, cut the line or fold it into the feature it belongs to.
3. Check it's true as the reader will see it: claims about speed or reliability are measured on the build being
   released, not hoped for.
4. Read the notes as someone who has only ever used the last release. Every line should make sense to them without
   asking us anything.

## Shape

- First, a few short bullets: the summary shown in the update window. Lead with what people will use most.
- Then sections by area (Assistant, Tabs, Friends (Beta)…), each point in a sentence or two.
- Write for the reader: what they can now do or will notice, not how it works. No mechanism words.

Each app's guide says where its notes file lives (see [RELEASING.md](RELEASING.md#before-every-release)).
