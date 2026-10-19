# Shenzhen Friends in this repository

Shenzhen Friends lives in `apps/pdf/portable/friends` (helper, client library, AppKit and GTK views, Rust core and
Tauri plugin) and `apps/pdf/portable/server/friends` (the host). ShenzhenPDF builds it as part of its own build;
Shenzhen Files and Shenzhen 3D embed the same helper.

## How Files and 3D build it

Before this repository existed, Files and 3D each pinned one shenzhen-pdf commit in `friends.lock` and their setup
scripts fetched that commit into `friends-src/` (3D's Tauri builds into `friends-core-src/`). Here they build from
`apps/pdf` in the same checkout instead. The setup scripts choose between two modes:

- **tree**, when the app sits in `apps/` beside `apps/pdf/portable/friends` and `SZF_FRIENDS_ROOT` is not set:
  Friends is `apps/pdf` as it is in the checkout, and the helper's version keys are `MAC_VERSION` and `MAC_BUILD`
  in `apps/pdf/portable/Makefile`.
- **pinned**, anywhere else or when `SZF_FRIENDS_ROOT` is set: Friends is `friends.lock`'s commit, fetched into
  `friends-src/` or given by `SZF_FRIENDS_ROOT`, with the version keys `friends.lock` names.

`SZF_FRIENDS_MODE=tree` or `SZF_FRIENDS_MODE=pinned` chooses explicitly. The scripts that decide:

- Files: `apps/files/tools/friends-lock.sh` (sourced by `setup-friends.sh`, `package/make-app.sh`,
  `package/check-friends-bundle.sh`, `setup-nautilus-tree.sh` and `test-friends-adapter.sh`, which passes
  `-Dfriends_root=<apps/pdf>` to the Nautilus build).
- 3D: `apps/3d/scripts/friends/friends-lock.sh` and `apps/3d/electron/friends/lock.cjs`, which decide the same way
  (`electron/friends-files.test.cjs` checks that they agree in both modes); `setup-tauri-friends.mjs` points the
  Tauri `friends` feature at `apps/pdf/portable/friends/tauri`.

In tree mode the Friends build goes to `apps/pdf/portable/build`, the same place ShenzhenPDF's own build puts it, so
the three apps share one build of the helper. `friends.lock` stays in `apps/files` and `apps/3d` for the pinned mode
and is no longer moved.

## The helper build number

Every app embeds the same helper, and a running helper hands over to an embedded one only when the embedded one has
a higher build number (`apps/pdf/portable/friends/PROTOCOL.md`, Lifecycle). The number is `YYMMDDBB`, computed from
ShenzhenPDF's `MAC_VERSION` and `MAC_BUILD`, so it says which Friends code a helper is.

The rule: **raise the number whenever Friends changes**, before any app ships that change. Preparing a ShenzhenPDF
release (`apps/pdf/portable/cut-release.sh --prepare-only`) raises it. `tools/check-friends-number.sh` fails when
Friends code changed after the number was last raised, and every release job runs it, so an app cannot ship a new
helper under an old number.

## Moving Friends to `friends/` (planned, not done)

Friends is shared code but lives inside ShenzhenPDF's tree. The plan:

1. Move `apps/pdf/portable/friends` to `friends/` and `apps/pdf/portable/server/friends` to `friends/server` with
   `git mv`, in one commit, so history follows the files.
2. Friends builds against libraries in ShenzhenPDF's `ext/`: cjson, libsodium, mbedtls, libjuice, libdatachannel,
   usrsctp, plog and miniupnpc. Move those to `friends/ext/` (or a top-level `third_party/`) and point
   `apps/pdf/portable/Makefile` and `friends/deps/*.mk` at the new place.
3. Give Friends its own makefile entry (`make -C friends helper-bundle`) that writes to `friends/build`, and have
   ShenzhenPDF's Makefile include it instead of `friends/friends.mk` by relative path.
4. Give the helper build number its own home, `friends/VERSION`, instead of ShenzhenPDF's `MAC_VERSION` and
   `MAC_BUILD`, so a Friends change can raise it without a ShenzhenPDF release. `tools/check-friends-number.sh`
   then compares against that file.
5. Change the tree mode of Files and 3D: `FRIENDS_ROOT` becomes `friends/`, and the paths they read
   (`portable/friends/...`, `portable/build/friends/...`, `ext/cjson`) lose their `portable/` prefix. Files'
   `-Dfriends_root` and the meson paths in `patches/friends-host-adapter.patch` follow.
6. Update the path filters of the workflows (`friends/**` instead of `apps/pdf/portable/friends/**`, and the
   libraries' new place instead of `apps/pdf/ext/...`), the deploy job
   of the host, and this file. Drop the pinned mode once nobody builds the old repositories.
