# W6 — Full Disk Access onboarding: integration wiring

Everything below is ready to paste. The FDA feature itself is complete and
self-contained in `src/nautilus-macos-fda.m` (registered in
`src/meson.build`, W6 block) with its C API in the **Section W6** part of
`src/nautilus-macos-bridge.h`. Nothing here changes that code — these are
the two call sites the feature needs, both in files owned by **W1**
(`nautilus-application.c` and the menu resources), which is why they live in
this doc instead of a direct edit.

`nautilus-application.c` already `#include`s `nautilus-macos-bridge.h`
inside its existing `#ifdef __APPLE__` block (lines ~61–64), so all four
`nautilus_macos_fda_*` symbols are already in scope there. No new include is
needed.

The C API (from the bridge header):

```c
gboolean nautilus_macos_fda_is_granted (void);
void     nautilus_macos_fda_open_settings (void);
gboolean nautilus_macos_fda_should_prompt_on_launch (void);   /* not granted AND not dismissed */
void     nautilus_macos_fda_set_prompt_dismissed (void);
void     nautilus_macos_fda_show_dialog (GtkWindow *parent);  /* handles both not-granted and already-granted UX */
```

---

## 1. Startup hook — prompt on first launch, after the window shows

**Goal:** once, on launch, if FDA isn't granted and the user hasn't opted
out, show the prompt — but only *after* the first window is actually on
screen (never on the launch critical path), mirroring shenzhen-pdf's
deferred post-first-paint block.

**Where:** `nautilus_application_window_added()` in
`nautilus-application.c` (currently ~line 1230). This runs once per window
add and is the earliest point where we have a real `GtkWindow`; a static
one-shot guard keeps it to the first window only, and a low-priority idle
defers the dialog until the window has been presented and the loop has
settled.

**Paste this** — a small self-contained block plus one call inside the
existing function. Put the helper just above `nautilus_application_window_added`:

```c
#ifdef __APPLE__
/* First-launch Full Disk Access prompt (W6). Deferred to a low-priority
 * idle so it appears only after the first window is on screen, never on the
 * launch critical path. Fires at most once per process. */
static gboolean
macos_fda_prompt_idle (gpointer user_data)
{
    GtkWindow *window = user_data;

    if (nautilus_macos_fda_should_prompt_on_launch ())
    {
        nautilus_macos_fda_show_dialog (window);
    }

    return G_SOURCE_REMOVE;
}

static void
macos_maybe_prompt_fda_once (GtkWindow *window)
{
    static gboolean prompted = FALSE;

    if (prompted)
    {
        return;
    }
    prompted = TRUE;

    g_idle_add_full (G_PRIORITY_DEFAULT_IDLE,
                     macos_fda_prompt_idle, window, NULL);
}
#endif
```

Then, inside `nautilus_application_window_added()`, in the existing
`if (NAUTILUS_IS_WINDOW (window))` branch (right after the
`g_signal_connect_swapped (window, "locations-changed", …)` line), add:

```c
#ifdef __APPLE__
        macos_maybe_prompt_fda_once (window);
#endif
```

Notes:
- The idle holds a plain (unowned) pointer to `window`. That's safe here:
  `window_added` fires with a live window and the default-priority idle runs
  on the very next main-loop iteration, long before any window teardown. If
  you prefer belt-and-suspenders, wrap it with `g_object_ref`/`g_object_unref`
  via `g_idle_add_full`'s `GDestroyNotify`.
- Don't gate this behind `should_prompt_on_launch()` *before* the idle — the
  check is cheap but does a TCC probe (a few `open`/`opendir` calls); keeping
  it inside the idle keeps it off the critical path entirely.
- `should_prompt_on_launch()` already returns FALSE when FDA is granted, so
  a user who granted access in a prior run is never prompted again.

---

## 2. Menu item — "Grant Full Disk Access…" (re-launchable any time)

Two parts: a `GSimpleAction` in `nautilus-application.c`, and a menu item in
the model W1 owns. The action calls `show_dialog` **unconditionally**, so
picking it from the menu always shows something: the grant prompt if not
granted (even if previously dismissed), or the "access is active"
confirmation if already granted — that state handling is inside
`nautilus_macos_fda_show_dialog`, so the action stays a one-liner.

### 2a. The action (in `nautilus-application.c`)

Add the callback (near the other `action_*` handlers, e.g. just above
`app_entries`):

```c
#ifdef __APPLE__
static void
action_fda_prompt (GSimpleAction *action,
                   GVariant      *parameter,
                   gpointer       user_data)
{
    GtkApplication *application = user_data;
    GtkWindow *window = gtk_application_get_active_window (application);

    nautilus_macos_fda_show_dialog (window);
}
#endif
```

Register it. The `app_entries[]` array is shared across platforms, so add
the entry after the array is applied rather than editing the initializer —
put this at the end of `nautilus_init_application_actions()`:

```c
#ifdef __APPLE__
    {
        g_autoptr (GSimpleAction) fda_action =
            g_simple_action_new ("fda-prompt", NULL);
        g_signal_connect (fda_action, "activate",
                          G_CALLBACK (action_fda_prompt), app);
        g_action_map_add_action (G_ACTION_MAP (app), G_ACTION (fda_action));
    }
#endif
```

(Or, if you prefer the table form, add
`{ .name = "fda-prompt", .activate = action_fda_prompt }` to `app_entries[]`
guarded so it only exists on Apple — but the table is a single shared
initializer, so the separate `g_action_map_add_action` above avoids touching
it.)

The action is now available as **`app.fda-prompt`**.

### 2b. The menu item

**Preferred — app-name menu.** On the GTK4 macOS backend the first submenu
of the `gtk_application_set_menubar` model becomes the application (app-name)
menu. Put the item in that menu's lower section, next to Preferences /
About, so it reads "Nautilus ▸ Grant Full Disk Access…". In the GMenu W1 is
building for the menubar, add to the app submenu:

```xml
<item>
  <attribute name="label" translatable="yes">Grant Full Disk Access…</attribute>
  <attribute name="action">app.fda-prompt</attribute>
</item>
```

**Fallback — Help menu.** If wiring it into the synthesized app menu is
awkward, the Help menu is a fine home (it's where "permissions/setup" items
commonly live). Same item, placed in the Help submenu:

```xml
<item>
  <attribute name="label" translatable="yes">Grant Full Disk Access…</attribute>
  <attribute name="action">app.fda-prompt</attribute>
</item>
```

If W1 is instead extending the existing Blueprint `app_menu` in
`src/resources/ui/nautilus-window.blp` (the hamburger menu, section with
Preferences / Help / About at lines ~35–55), the equivalent Blueprint item
is:

```blueprint
item {
  label: _("Grant Full Disk Access…");
  action: "app.fda-prompt";
}
```

No accelerator is needed (this is a rare, deliberate action). If W1 wants
one for consistency, nothing in W6 depends on it.

---

## 3. Dev-vs-bundle TCC caveat + packaging note

### The caveat (important for anyone testing this)

`nautilus_macos_fda_is_granted()` works by trying to read TCC-protected
paths (`~/Library/Application Support/com.apple.TCC/TCC.db`, then `~/.Trash`
and `~/Library/Safari` as fallbacks). `EPERM`/`EACCES` ⇒ not granted; a
successful read ⇒ granted.

**TCC attributes file access to the *responsible process*, not the process
that literally issues the syscall.** When Nautilus is launched from a
terminal, an IDE, or via `run-nautilus.sh`, the responsible process is that
terminal/IDE. So:

- If you run it from a terminal that itself has Full Disk Access,
  `is_granted()` returns **TRUE** and the launch prompt is suppressed — even
  though "Nautilus" has no grant of its own.
- If you run it from a terminal *without* FDA, it returns **FALSE**
  regardless of any grant a future bundle would have.

This is expected and not a bug. The check is **truthful for the shipped
`.app` bundle launched via Finder/LaunchServices**, which is the only case
that matters for end users. When testing the not-granted UX from a terminal,
use a terminal that does *not* have Full Disk Access (verified in this repo's
scratch harness: detection returned FALSE, and the grant prompt showed
correctly).

### Packaging note (for the packaging worker)

**Full Disk Access requires NO Info.plist usage-description key.** Unlike
camera/mic/contacts/etc. (which need `NS…UsageDescription` strings or the app
crashes on first access), FDA is granted entirely by the user in System
Settings ▸ Privacy & Security ▸ Full Disk Access. There is no
`NSFullDiskAccessUsageDescription` key and nothing to add to `Info.plist` for
this feature. The app simply receives `EPERM` on protected paths until the
user toggles it on.

Two things the packaging worker *should* keep in mind, though:

1. **Stable bundle identity.** TCC keys the grant on the app's bundle
   identifier + code signature (designated requirement). Ad-hoc signing that
   churns the signature on every rebuild will reset the grant, so a user who
   granted FDA to yesterday's build may show as "not granted" today. A
   stable Developer ID signature avoids this; for dev builds it's just a
   known annoyance (documented the same way in shenzhen-pdf's
   `portable/docs/architecture.md`).
2. **Relaunch after granting.** macOS only re-evaluates a process's FDA on
   (re)launch. The dialog body already tells the user to quit and reopen
   Nautilus after enabling it; no code needs to poll for the change.

---

## Summary for the integrator

Two integration points, both in W1-owned files, both `#ifdef __APPLE__`:

1. **First-launch prompt:** a one-shot deferred idle in
   `nautilus_application_window_added()` calling
   `nautilus_macos_fda_should_prompt_on_launch()` → `…_show_dialog(window)`.
2. **Menu item:** an `app.fda-prompt` `GSimpleAction` calling
   `…_show_dialog()` unconditionally, exposed as a "Grant Full Disk Access…"
   item in the app-name menu (preferred) or Help menu (fallback).

No Info.plist key is required for FDA.
