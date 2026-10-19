# Flatpak packaging

Files:

- `com.intuition.shenzhenpdf.yml` — flatpak-builder manifest (GNOME 50
  runtime, builds vendored MuPDF + the GTK4 app from the local tree).
- `com.intuition.shenzhenpdf.metainfo.xml` — AppStream metainfo, installed to
  `/app/share/metainfo/`.

## Building locally

flatpak-builder is consumed as the Flatpak app `org.flatpak.Builder` (the
distro package is not required):

    flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    flatpak install --user -y flathub org.flatpak.Builder org.gnome.Platform//50 org.gnome.Sdk//50

Then, from the **repo root** (the manifest's `dir` source resolves relative
to the manifest file, four levels up):

    flatpak run org.flatpak.Builder --user --install --force-clean \
        build-dir portable/linux/pkg/flatpak/com.intuition.shenzhenpdf.yml

The first build compiles MuPDF's static libraries inside the sandbox
(~10–30 min); `--force-clean` only clears `build-dir`, and ccache inside
flatpak-builder softens rebuilds. Run with:

    flatpak run com.intuition.shenzhenpdf some.pdf

Single-file bundle (installable via `flatpak install ShenzhenPDF.flatpak`):

    flatpak build-bundle ~/.local/share/flatpak/repo \
        dist/ShenzhenPDF.flatpak com.intuition.shenzhenpdf

Validate the metadata:

    appstreamcli validate --no-net portable/linux/pkg/flatpak/com.intuition.shenzhenpdf.metainfo.xml
    flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest \
        portable/linux/pkg/flatpak/com.intuition.shenzhenpdf.yml

The linter currently reports exactly one error,
`finish-args-host-ro-filesystem-access` — the documented `--filesystem=host:ro`
trade-off (see point 4 below; a Flathub submission needs either the portal
work or a linter exception request).

## What a Flathub submission additionally needs

1. **App id decision — flag for the maintainer.** Flathub [requires
   verifiable control of the app id's
   domain](https://docs.flathub.org/docs/for-app-authors/requirements#application-id).
   `com.intuition.shenzhenpdf` implies control of `intuition.com`, which we
   almost certainly do **not** own — Flathub would reject or leave the app
   unverified. Recommended: submit as
   **`io.github.casimir_engineering.shenzhen_pdf`** (GitHub-based ids are
   verified with a repo/pages marker, no domain purchase needed; note
   Flathub's rule that hyphens in the GitHub owner/repo become underscores in
   the id). Going that route means changing, in lock-step:
   - `SPDF_APP_ID` in `portable/linux/gtk4/spdf_app.h` (this is also the
     GApplication D-Bus name and the `StartupWMClass`),
   - the desktop file name, `Icon=` and `StartupWMClass=` values,
   - the metainfo `<id>` / `<launchable>`, and this manifest's `app-id`,
     icon/desktop install paths.
   Keeping `com.intuition.*` is only viable if someone actually controls
   `intuition.com` and can serve the verification token.

2. **Git/archive source instead of `type: dir`.** Flathub builds from a
   pinned source; replace the `dir` source with:

   ```yaml
   sources:
     - type: git
       url: https://github.com/casimir-engineering/shenzhen-pdf.git
       tag: "26.7.17"
       commit: <full commit sha>
   ```

   The repo must be public. Everything vendored (MuPDF, its `ext/` thirdparty
   tree) is already in-tree, so no extra modules are needed; note that Flathub
   generally prefers system/runtime libraries over vendored copies, so expect
   review questions about the vendored MuPDF (static linking is accepted for
   apps like this, but be ready to justify it).

3. **Screenshots at stable URLs.** The metainfo currently points at the raw
   GitHub URL of `portable/docs/gtk4-captures/00-launch.png` on `master`;
   that file must actually be reachable there when Flathub's build validates
   the metainfo (`appstreamcli validate` without `--no-net` checks the URL —
   it currently 404s because the capture hasn't landed on `master`).
   Flathub wants 2+ screenshots at 16:9-ish sizes ideally; padding/window
   shots from `portable/docs/gtk4-captures/` are fine.

4. **Sandbox tightening (review pressure).** `--filesystem=host:ro` will draw
   reviewer attention. It is currently load-bearing: documents arrive as bare
   paths (argv, session restore, recents, the file watcher re-stats paths).
   Moving document opening to the document portal (and persisting portal doc
   ids in the session) would let both filesystem grants be dropped.

5. **Release cadence.** Each release needs a new `<release>` entry in the
   metainfo (Flathub surfaces it as the changelog) and a manifest bump to the
   new tag/commit.

## What is intentionally disabled inside the sandbox

`spdf_running_in_flatpak()` (checks `/.flatpak-info` / `FLATPAK_ID`) gates:

- the self-updater (`spdf_updater.c`) — updates come from Flathub; the manual
  "Check for Updates" explains this instead of checking,
- login autostart for resident instant-launch (`spdf_resident.c`) — writing
  `~/.config/autostart` inside the sandbox does nothing on the host; the XDG
  Background portal is the future path,
- default-reader registration (`spdf_default_reader.c`) — `xdg-mime` would
  edit the sandbox's mimeapps.list, not the host's; the menu action points
  users at system Settings.
