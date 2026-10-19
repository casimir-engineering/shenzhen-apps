// Pure-logic tests for spdf_state.c (glib only, no GTK). The GTK bits of the
// module are compiled out via SPDF_STATE_TESTING; everything else — the JSON
// readers/writers, the YAML file boundary + legacy-JSON migration, the
// session merge, geometry clamping, mtime/size validation — runs against a
// temp config dir.
//
// Schema fixtures below are byte-copies of what the GTK3 writer
// (portable/linux/ShenzhenPDFGtk.c save_settings/write_session/save_favorites,
// retired) and the Mac writer (portable/mac/ShenzhenPDFMac.mm
// savePersistentState) produced as JSON; writing them as .json files also
// exercises the auto-migration that runs inside spdf_state_load_from_dir.
#define SPDF_STATE_TESTING 1

#include "../spdf_state.c"

static char* test_make_config_dir(void) {
    char* dir = g_dir_make_tmp("spdf-state-test-XXXXXX", NULL);
    g_assert_nonnull(dir);
    return dir;
}

static void test_write_state_file(const char* dir, const char* name, const char* contents) {
    char* path = g_build_filename(dir, name, NULL);
    g_assert_true(g_file_set_contents(path, contents, -1, NULL));
    g_free(path);
}

static char* test_read_state_file(const char* dir, const char* name) {
    char* path = g_build_filename(dir, name, NULL);
    char* contents = NULL;
    g_assert_true(g_file_get_contents(path, &contents, NULL, NULL));
    g_free(path);
    return contents;
}

static void test_remove_tree(const char* dir) {
    GDir* handle = g_dir_open(dir, 0, NULL);
    const char* name;
    if (handle) {
        while ((name = g_dir_read_name(handle)) != NULL) {
            char* path = g_build_filename(dir, name, NULL);
            g_unlink(path);
            g_free(path);
        }
        g_dir_close(handle);
    }
    g_rmdir(dir);
}

// --- settings.json ------------------------------------------------------------

// Byte-copy of the GTK3 save_settings output shape (ShenzhenPDFGtk.c ~1111).
static const char* kGtk3SettingsFixture =
    "{\n"
    "  \"fitMode\": 2,\n"
    "  \"zoom\": 1.2500,\n"
    "  \"continuous\": true,\n"
    "  \"showSidebar\": false,\n"
    "  \"showMinimap\": true,\n"
    "  \"showFindMarkers\": false,\n"
    "  \"collapseWhitespaceWhenCopyingText\": false,\n"
    "  \"showShortcutHelpOnLaunch\": false,\n"
    "  \"sidebarWidth\": 320,\n"
    "  \"windowWidth\": 1440,\n"
    "  \"windowHeight\": 900,\n"
    "  \"commentAuthor\": \"Raph\",\n"
    "  \"translateSourceLanguage\": \"zh\",\n"
    "  \"translateTargetLanguage\": \"en\",\n"
    "  \"recentlyOpened\": [\n"
    "    \"/home/raph/docs/one.pdf\",\n"
    "    \"/home/raph/docs/two.pdf\"\n"
    "  ]\n"
    "}\n";

static void test_settings_gtk3_fixture(void) {
    char* dir = test_make_config_dir();
    SpdfState* state;
    SpdfSettings* settings;

    test_write_state_file(dir, "settings.json", kGtk3SettingsFixture);
    state = spdf_state_load_from_dir(dir);
    settings = spdf_state_settings(state);

    g_assert_cmpint(settings->fit_mode, ==, 2);
    g_assert_cmpfloat(settings->zoom, ==, 1.25);
    g_assert_false(settings->default_sidebar_visible); // legacy "showSidebar"
    g_assert_true(settings->default_minimap_visible);  // legacy "showMinimap"
    g_assert_false(settings->show_find_markers);
    g_assert_false(settings->collapse_whitespace_on_copy);
    g_assert_false(settings->show_shortcut_help_on_launch);
    g_assert_cmpint(settings->sidebar_width, ==, 320);
    g_assert_cmpint(settings->window_width, ==, 1440);  // legacy flat keys
    g_assert_cmpint(settings->window_height, ==, 900);
    g_assert_cmpstr(settings->comment_author, ==, "Raph");
    g_assert_cmpstr(settings->translate_source_language, ==, "zh");
    g_assert_cmpint(spdf_state_recent_count(state), ==, 2);
    g_assert_cmpstr(spdf_state_recent_path(state, 0), ==, "/home/raph/docs/one.pdf");
    g_assert_cmpstr(spdf_state_recent_path(state, 1), ==, "/home/raph/docs/two.pdf");
    // Keys the GTK3 file never wrote keep their defaults.
    g_assert_true(settings->auto_update_enabled);
    g_assert_true(settings->prevent_sleep_in_presentation);
    g_assert_true(settings->search_jumps_to_nearest_result);
    g_assert_true(settings->instant_launch_resident); // Wave D default on

    spdf_state_free(state);
    test_remove_tree(dir);
    g_free(dir);
}

// Byte-copy of the Mac savePersistentState output shape (pretty + sorted keys).
static const char* kMacSettingsFixture =
    "{\n"
    "  \"autoUpdateEnabled\" : false,\n"
    "  \"collapseWhitespaceWhenCopyingText\" : true,\n"
    "  \"commentAuthor\" : \"Raph\",\n"
    "  \"defaultMinimapVisibleForNewDocuments\" : false,\n"
    "  \"defaultReaderPromptDismissed\" : true,\n"
    "  \"defaultSidebarVisibleForNewDocuments\" : true,\n"
    "  \"fitMode\" : 3,\n"
    "  \"fullDiskAccessPromptDismissed\" : false,\n"
    "  \"minimapWidth\" : 126.5,\n"
    "  \"permissionsWizardShown\" : true,\n"
    "  \"preventSleepInPresentation\" : false,\n"
    "  \"printCustomScale\" : 0.5,\n"
    "  \"printScalingMode\" : 2,\n"
    "  \"recentlyOpened\" : [\n"
    "    \"/Users/raph/a.pdf\"\n"
    "  ],\n"
    "  \"searchJumpsToNearestResult\" : false,\n"
    "  \"showShortcutHelpOnLaunch\" : true,\n"
    "  \"sidebarWidth\" : 240,\n"
    "  \"skippedUpdateVersion\" : \"26.2.1\",\n"
    "  \"translateSourceLanguage\" : \"ja\",\n"
    "  \"translateTargetLanguage\" : \"en\",\n"
    "  \"version\" : 1,\n"
    "  \"viewMode\" : 1,\n"
    "  \"windowSize\" : {\n"
    "    \"height\" : 820,\n"
    "    \"width\" : 1180\n"
    "  }\n"
    "}";

static void test_settings_mac_fixture(void) {
    char* dir = test_make_config_dir();
    SpdfState* state;
    SpdfSettings* settings;

    test_write_state_file(dir, "settings.json", kMacSettingsFixture);
    state = spdf_state_load_from_dir(dir);
    settings = spdf_state_settings(state);

    g_assert_false(settings->auto_update_enabled);
    g_assert_true(settings->collapse_whitespace_on_copy);
    g_assert_false(settings->default_minimap_visible);
    g_assert_true(settings->default_sidebar_visible);
    g_assert_true(settings->default_reader_prompt_dismissed);
    g_assert_cmpint(settings->fit_mode, ==, 3);
    g_assert_cmpfloat(settings->minimap_width, ==, 126.5);
    g_assert_false(settings->prevent_sleep_in_presentation);
    g_assert_cmpfloat(settings->print_custom_scale, ==, 0.5);
    g_assert_cmpint(settings->print_scaling_mode, ==, 2);
    g_assert_false(settings->search_jumps_to_nearest_result);
    g_assert_true(settings->show_shortcut_help_on_launch);
    g_assert_cmpint(settings->sidebar_width, ==, 240);
    g_assert_cmpstr(settings->skipped_update_version, ==, "26.2.1");
    g_assert_cmpstr(settings->translate_source_language, ==, "ja");
    g_assert_cmpint(settings->window_width, ==, 1180); // nested windowSize
    g_assert_cmpint(settings->window_height, ==, 820);
    g_assert_cmpint(spdf_state_recent_count(state), ==, 1);
    g_assert_cmpfloat(settings->zoom, ==, 1.0); // Mac never writes zoom; default kept

    // Mac-only permission flags parsed with presence tracking...
    g_assert_true(settings->has_mac_full_disk_prompt_dismissed);
    g_assert_false(settings->mac_full_disk_prompt_dismissed);
    g_assert_true(settings->has_mac_permissions_wizard_shown);
    g_assert_true(settings->mac_permissions_wizard_shown);

    // ...and round-tripped by the Linux writer: rewriting a Mac settings file
    // must not wipe them (the Mac app would re-run its permission prompts).
    {
        char* path = g_build_filename(dir, "settings.yaml", NULL);
        char* text = NULL;

        spdf_state_save_settings(state);
        spdf_state_flush(state);
        g_assert_true(g_file_get_contents(path, &text, NULL, NULL));
        g_assert_nonnull(strstr(text, "fullDiskAccessPromptDismissed: false"));
        g_assert_nonnull(strstr(text, "permissionsWizardShown: true"));
        g_free(text);
        g_free(path);
    }

    spdf_state_free(state);
    test_remove_tree(dir);
    g_free(dir);
}

static void test_settings_round_trip(void) {
    char* dir = test_make_config_dir();
    SpdfState* state = spdf_state_load_from_dir(dir);
    SpdfSettings* settings = spdf_state_settings(state);
    SpdfState* reloaded;
    SpdfSettings* loaded;
    char* text;

    settings->fit_mode = 1;
    settings->zoom = 2.5;
    settings->sidebar_width = 300;
    settings->minimap_width = 90.0;
    settings->default_sidebar_visible = FALSE;
    settings->default_minimap_visible = FALSE;
    settings->collapse_whitespace_on_copy = FALSE;
    settings->search_jumps_to_nearest_result = FALSE;
    settings->show_find_markers = FALSE;
    settings->show_shortcut_help_on_launch = FALSE;
    settings->auto_update_enabled = FALSE;
    settings->prevent_sleep_in_presentation = FALSE;
    settings->default_reader_prompt_dismissed = TRUE;
    settings->instant_launch_resident = FALSE; // Wave D (Linux-only key)
    settings->print_scaling_mode = 1;
    settings->print_custom_scale = 0.25;
    settings->window_width = 1600;
    settings->window_height = 1000;
    spdf_state_set_string(&settings->comment_author, "R \"quoted\" name");
    spdf_state_set_string(&settings->skipped_update_version, "26.3.0");
    spdf_state_set_string(&settings->translate_source_language, "de");
    spdf_state_set_string(&settings->translate_target_language, "fr");
    spdf_state_add_recent(state, "/tmp/b.pdf");
    spdf_state_add_recent(state, "/tmp/a.pdf");
    spdf_state_save_settings(state);
    spdf_state_flush(state);

    // The written file is YAML and carries the Mac schema markers.
    text = test_read_state_file(dir, "settings.yaml");
    g_assert_nonnull(strstr(text, "windowSize:"));
    g_assert_nonnull(strstr(text, "height: 1000"));
    g_assert_nonnull(strstr(text, "width: 1600"));
    g_assert_nonnull(strstr(text, "viewMode: 1"));
    g_assert_nonnull(strstr(text, "version: 1"));
    g_assert_null(strstr(text, "windowWidth")); // legacy flat keys migrated away
    g_free(text);

    reloaded = spdf_state_load_from_dir(dir);
    loaded = spdf_state_settings(reloaded);
    g_assert_cmpint(loaded->fit_mode, ==, 1);
    g_assert_cmpfloat(loaded->zoom, ==, 2.5);
    g_assert_cmpint(loaded->sidebar_width, ==, 300);
    g_assert_cmpfloat(loaded->minimap_width, ==, 90.0);
    g_assert_false(loaded->default_sidebar_visible);
    g_assert_false(loaded->default_minimap_visible);
    g_assert_false(loaded->collapse_whitespace_on_copy);
    g_assert_false(loaded->search_jumps_to_nearest_result);
    g_assert_false(loaded->show_find_markers);
    g_assert_false(loaded->show_shortcut_help_on_launch);
    g_assert_false(loaded->auto_update_enabled);
    g_assert_false(loaded->prevent_sleep_in_presentation);
    g_assert_true(loaded->default_reader_prompt_dismissed);
    g_assert_false(loaded->instant_launch_resident); // Wave D round-trips
    g_assert_cmpint(loaded->print_scaling_mode, ==, 1);
    g_assert_cmpfloat(loaded->print_custom_scale, ==, 0.25);
    g_assert_cmpint(loaded->window_width, ==, 1600);
    g_assert_cmpint(loaded->window_height, ==, 1000);
    g_assert_cmpstr(loaded->comment_author, ==, "R \"quoted\" name");
    g_assert_cmpstr(loaded->skipped_update_version, ==, "26.3.0");
    g_assert_cmpstr(loaded->translate_source_language, ==, "de");
    g_assert_cmpstr(loaded->translate_target_language, ==, "fr");
    g_assert_cmpint(spdf_state_recent_count(reloaded), ==, 2);
    g_assert_cmpstr(spdf_state_recent_path(reloaded, 0), ==, "/tmp/a.pdf");
    g_assert_cmpstr(spdf_state_recent_path(reloaded, 1), ==, "/tmp/b.pdf");

    spdf_state_free(reloaded);
    spdf_state_free(state);
    test_remove_tree(dir);
    g_free(dir);
}

// --- session.json ---------------------------------------------------------------

// Byte-copy of the GTK3 write_session output shape (1-based "page", no
// viewMode/scroll keys; ShenzhenPDFGtk.c session_window_object_for_current_state).
static const char* kGtk3SessionFixture =
    "{\n"
    "  \"version\": 2,\n"
    "  \"windows\": [\n"
    "{ \"id\": \"gtk-1234-99\", \"frame\": { \"x\": 40, \"y\": 60, \"width\": 1280, \"height\": 800 }, "
    "\"selectedTab\": 1, \"tabs\": [\n"
    "    { \"path\": \"/home/raph/docs/one.pdf\", \"title\": \"one\", \"page\": 5, \"zoom\": 1.5000, "
    "\"fitMode\": 2, \"continuous\": true, \"showSidebar\": true, \"showMinimap\": false, "
    "\"searchText\": \"impedance\", \"searchRegex\": false, \"searchRegexMultiline\": true, \"findMatchIndex\": 3 },\n"
    "    { \"path\": \"/home/raph/docs/two.pdf\", \"title\": \"two\", \"page\": 1, \"zoom\": 1.0000, "
    "\"fitMode\": 4, \"continuous\": true, \"showSidebar\": false, \"showMinimap\": true, "
    "\"searchText\": \"\", \"searchRegex\": false, \"searchRegexMultiline\": false, \"findMatchIndex\": -1 }\n"
    "  ] }\n"
    "  ]\n"
    "}\n";

static void test_session_gtk3_fixture(void) {
    char* dir = test_make_config_dir();
    SpdfState* state;
    const SpdfSessionWindow* win;
    const SpdfSessionTab* tab;

    test_write_state_file(dir, "session.json", kGtk3SessionFixture);
    state = spdf_state_load_from_dir(dir);

    g_assert_cmpuint(spdf_state_session_window_count(state), ==, 1);
    win = spdf_state_session_window(state, 0);
    g_assert_cmpstr(win->id, ==, "gtk-1234-99");
    g_assert_true(win->has_frame);
    g_assert_cmpint(win->frame.x, ==, 40);
    g_assert_cmpint(win->frame.y, ==, 60);
    g_assert_cmpint(win->frame.width, ==, 1280);
    g_assert_cmpint(win->frame.height, ==, 800);
    g_assert_cmpint(win->selected_tab, ==, 1);
    g_assert_cmpuint(win->tabs->len, ==, 2);

    tab = g_ptr_array_index(win->tabs, 0);
    g_assert_cmpstr(tab->path, ==, "/home/raph/docs/one.pdf");
    g_assert_cmpint(tab->page, ==, 4); // GTK3 wrote 1-based "page": 5
    g_assert_cmpfloat(tab->zoom, ==, 1.5);
    g_assert_cmpint(tab->fit_mode, ==, 2);
    g_assert_cmpstr(tab->search_text, ==, "impedance");
    g_assert_true(tab->search_regex_multiline);
    g_assert_cmpint(tab->find_match_index, ==, 3);
    g_assert_true(tab->has_show_sidebar);
    g_assert_true(tab->show_sidebar);
    g_assert_false(tab->show_minimap);
    g_assert_false(tab->has_scroll_origin); // GTK3 had no scroll persistence

    tab = g_ptr_array_index(win->tabs, 1);
    g_assert_cmpint(tab->page, ==, 0); // "page": 1 -> 0
    g_assert_false(tab->search_regex_multiline);

    g_assert_nonnull(spdf_state_session_window_by_id(state, "gtk-1234-99"));
    g_assert_null(spdf_state_session_window_by_id(state, "nope"));

    spdf_state_free(state);
    test_remove_tree(dir);
    g_free(dir);
}

// Byte-copy of the Mac session tab shape (0-based "page", always "viewMode": 1,
// scroll origin, read-only shadow copy keys; SPDFMacModels.mm).
static const char* kMacSessionFixture =
    "{\n"
    "  \"version\" : 2,\n"
    "  \"windows\" : [\n"
    "    {\n"
    "      \"frame\" : {\n"
    "        \"height\" : 812,\n"
    "        \"width\" : 1120,\n"
    "        \"x\" : 240,\n"
    "        \"y\" : 120\n"
    "      },\n"
    "      \"id\" : \"E8B0C6A1-4E1E-4B3F-9AF2-000000000001\",\n"
    "      \"selectedTab\" : 0,\n"
    "      \"tabs\" : [\n"
    "        {\n"
    "          \"customZoom\" : 1.75,\n"
    "          \"findMatchIndex\" : -1,\n"
    "          \"fitMode\" : 0,\n"
    "          \"hasScrollOrigin\" : true,\n"
    "          \"page\" : 5,\n"
    "          \"path\" : \"/Users/raph/one.pdf\",\n"
    "          \"readOnly\" : true,\n"
    "          \"roCopyFileSize\" : 4242,\n"
    "          \"roCopyModifiedAt\" : 1750000000.5,\n"
    "          \"scrollX\" : 12.25,\n"
    "          \"scrollY\" : 3400.75,\n"
    "          \"searchRegex\" : true,\n"
    "          \"searchRegexMultiline\" : false,\n"
    "          \"searchText\" : \"C-PHY\",\n"
    "          \"showMinimap\" : true,\n"
    "          \"showSidebar\" : false,\n"
    "          \"title\" : \"one\",\n"
    "          \"viewMode\" : 1,\n"
    "          \"workingPath\" : \"/tmp/ReadOnlyCopies/one.pdf\",\n"
    "          \"zoom\" : 1.75\n"
    "        }\n"
    "      ]\n"
    "    }\n"
    "  ]\n"
    "}";

static void test_session_mac_fixture(void) {
    char* dir = test_make_config_dir();
    SpdfState* state;
    const SpdfSessionWindow* win;
    const SpdfSessionTab* tab;

    test_write_state_file(dir, "session.json", kMacSessionFixture);
    state = spdf_state_load_from_dir(dir);

    g_assert_cmpuint(spdf_state_session_window_count(state), ==, 1);
    win = spdf_state_session_window(state, 0);
    g_assert_cmpstr(win->id, ==, "E8B0C6A1-4E1E-4B3F-9AF2-000000000001");
    g_assert_true(win->has_frame);
    g_assert_cmpint(win->frame.width, ==, 1120);
    g_assert_cmpuint(win->tabs->len, ==, 1);

    tab = g_ptr_array_index(win->tabs, 0);
    g_assert_cmpint(tab->page, ==, 5); // Mac "page" is 0-based, no migration
    g_assert_cmpfloat(tab->zoom, ==, 1.75);
    g_assert_cmpfloat(tab->custom_zoom, ==, 1.75);
    g_assert_cmpint(tab->fit_mode, ==, 0);
    g_assert_true(tab->has_scroll_origin);
    g_assert_cmpfloat(tab->scroll_x, ==, 12.25);
    g_assert_cmpfloat(tab->scroll_y, ==, 3400.75);
    g_assert_true(tab->search_regex);
    g_assert_false(tab->search_regex_multiline);
    g_assert_cmpstr(tab->search_text, ==, "C-PHY");
    g_assert_true(tab->read_only);
    g_assert_cmpstr(tab->working_path, ==, "/tmp/ReadOnlyCopies/one.pdf");
    g_assert_cmpuint(tab->ro_copy_file_size, ==, 4242);
    g_assert_cmpfloat(tab->ro_copy_modified_at, ==, 1750000000.5);

    spdf_state_free(state);
    test_remove_tree(dir);
    g_free(dir);
}

static void test_session_round_trip(void) {
    char* dir = test_make_config_dir();
    SpdfState* state = spdf_state_load_from_dir(dir);
    SpdfSessionWindow* win = spdf_session_window_new("gtk-777-1");
    SpdfSessionTab* tab = spdf_session_window_add_tab(win);
    SpdfState* reloaded;
    const SpdfSessionWindow* loaded_win;
    const SpdfSessionTab* loaded_tab;

    win->frame.x = -20;
    win->frame.y = 32;
    win->frame.width = 1500;
    win->frame.height = 950;
    win->has_frame = TRUE;
    win->selected_tab = 0;
    tab->path = g_strdup("/tmp/docs/schematic.pdf");
    tab->title = g_strdup("schematic \"rev B\"\nfinal");
    tab->page = 7; // 0-based
    tab->zoom = 1.3333;
    tab->custom_zoom = 2.0;
    tab->fit_mode = 0;
    tab->scroll_x = 40.5;
    tab->scroll_y = 9001.25;
    tab->has_scroll_origin = TRUE;
    tab->search_text = g_strdup("差分\tline \"impedance\"");
    tab->search_regex = TRUE;
    tab->search_regex_multiline = FALSE;
    tab->find_match_index = 12;
    tab->show_sidebar = FALSE;
    tab->show_minimap = TRUE;
    tab->read_only = TRUE;
    tab->working_path = g_strdup("/tmp/copy.pdf");
    tab->ro_copy_file_size = 123456789012345ULL;
    tab->ro_copy_modified_at = 1750000123.375;

    spdf_state_update_session_window(state, win);
    spdf_state_flush(state);

    reloaded = spdf_state_load_from_dir(dir);
    g_assert_cmpuint(spdf_state_session_window_count(reloaded), ==, 1);
    loaded_win = spdf_state_session_window_by_id(reloaded, "gtk-777-1");
    g_assert_nonnull(loaded_win);
    g_assert_true(loaded_win->has_frame);
    g_assert_cmpint(loaded_win->frame.x, ==, -20);
    g_assert_cmpint(loaded_win->frame.y, ==, 32);
    g_assert_cmpint(loaded_win->frame.width, ==, 1500);
    g_assert_cmpint(loaded_win->frame.height, ==, 950);
    g_assert_cmpuint(loaded_win->tabs->len, ==, 1);

    loaded_tab = g_ptr_array_index(loaded_win->tabs, 0);
    g_assert_cmpstr(loaded_tab->path, ==, "/tmp/docs/schematic.pdf");
    g_assert_cmpstr(loaded_tab->title, ==, "schematic \"rev B\"\nfinal");
    g_assert_cmpint(loaded_tab->page, ==, 7); // 0-based survives (viewMode marker present)
    g_assert_cmpfloat(loaded_tab->zoom, ==, 1.3333);
    g_assert_cmpfloat(loaded_tab->custom_zoom, ==, 2.0);
    g_assert_cmpint(loaded_tab->fit_mode, ==, 0);
    g_assert_true(loaded_tab->has_scroll_origin);
    g_assert_cmpfloat(loaded_tab->scroll_x, ==, 40.5);
    g_assert_cmpfloat(loaded_tab->scroll_y, ==, 9001.25);
    g_assert_cmpstr(loaded_tab->search_text, ==, "差分\tline \"impedance\"");
    g_assert_true(loaded_tab->search_regex);
    g_assert_false(loaded_tab->search_regex_multiline);
    g_assert_cmpint(loaded_tab->find_match_index, ==, 12);
    g_assert_false(loaded_tab->show_sidebar);
    g_assert_true(loaded_tab->show_minimap);
    g_assert_true(loaded_tab->read_only);
    g_assert_cmpstr(loaded_tab->working_path, ==, "/tmp/copy.pdf");
    g_assert_cmpuint(loaded_tab->ro_copy_file_size, ==, 123456789012345ULL);
    g_assert_cmpfloat(loaded_tab->ro_copy_modified_at, ==, 1750000123.375);

    spdf_state_free(reloaded);
    spdf_state_free(state);
    test_remove_tree(dir);
    g_free(dir);
}

static void test_session_merge_preserves_foreign_windows(void) {
    char* dir = test_make_config_dir();
    SpdfState* state;
    SpdfSessionWindow* win;
    SpdfSessionTab* tab;
    char* text;

    // A foreign window (another process) plus a stale copy of our own id.
    test_write_state_file(
        dir, "session.json",
        "{\n"
        "  \"version\": 2,\n"
        "  \"windows\": [\n"
        "{ \"id\": \"foreign-1\", \"selectedTab\": 0, \"tabs\": [\n"
        "    { \"path\": \"/elsewhere/x.pdf\", \"title\": \"x\", \"page\": 1, \"zoom\": 1.0000, \"fitMode\": 4, "
        "\"continuous\": true, \"showSidebar\": true, \"showMinimap\": true, \"searchText\": \"\", "
        "\"searchRegex\": false, \"searchRegexMultiline\": true, \"findMatchIndex\": -1 }\n"
        "  ] },\n"
        "{ \"id\": \"mine-1\", \"selectedTab\": 0, \"tabs\": [\n"
        "    { \"path\": \"/stale/old.pdf\", \"title\": \"old\", \"page\": 1, \"zoom\": 1.0000, \"fitMode\": 4, "
        "\"continuous\": true, \"showSidebar\": true, \"showMinimap\": true, \"searchText\": \"\", "
        "\"searchRegex\": false, \"searchRegexMultiline\": true, \"findMatchIndex\": -1 }\n"
        "  ] }\n"
        "  ]\n"
        "}\n");

    state = spdf_state_load_from_dir(dir);
    win = spdf_session_window_new("mine-1");
    tab = spdf_session_window_add_tab(win);
    tab->path = g_strdup("/fresh/new.pdf");
    spdf_state_update_session_window(state, win);
    spdf_state_flush(state);

    text = test_read_state_file(dir, "session.yaml");
    g_assert_nonnull(strstr(text, "\"foreign-1\"")); // untouched
    g_assert_nonnull(strstr(text, "/elsewhere/x.pdf"));
    g_assert_nonnull(strstr(text, "/fresh/new.pdf")); // replaced, not duplicated
    g_assert_null(strstr(text, "/stale/old.pdf"));
    g_free(text);

    // Deliberate close removes our window but keeps the foreign one.
    spdf_state_remove_session_window(state, "mine-1");
    spdf_state_flush(state);
    text = test_read_state_file(dir, "session.yaml");
    g_assert_nonnull(strstr(text, "\"foreign-1\""));
    g_assert_null(strstr(text, "\"mine-1\""));
    g_free(text);

    spdf_state_free(state);
    test_remove_tree(dir);
    g_free(dir);
}

static void test_session_legacy_single_document(void) {
    char* dir = test_make_config_dir();
    SpdfState* state;
    const SpdfSessionWindow* win;
    const SpdfSessionTab* tab;

    // Oldest GTK3 shape: one bare document record, 1-based page.
    test_write_state_file(dir, "session.json",
                          "{ \"path\": \"/home/raph/docs/one.pdf\", \"page\": 3, \"searchText\": \"vias\", "
                          "\"searchRegex\": false, \"searchRegexMultiline\": true, \"findMatchIndex\": 2 }\n");
    state = spdf_state_load_from_dir(dir);
    g_assert_cmpuint(spdf_state_session_window_count(state), ==, 1);
    win = spdf_state_session_window(state, 0);
    g_assert_cmpuint(win->tabs->len, ==, 1);
    tab = g_ptr_array_index(win->tabs, 0);
    g_assert_cmpstr(tab->path, ==, "/home/raph/docs/one.pdf");
    g_assert_cmpint(tab->page, ==, 2);
    g_assert_cmpstr(tab->search_text, ==, "vias");
    g_assert_cmpint(tab->find_match_index, ==, 2);

    spdf_state_free(state);
    test_remove_tree(dir);
    g_free(dir);
}

// --- favorites.json --------------------------------------------------------------

// Byte-copy of the GTK3 save_favorites output shape (wrapper object, 1-based page).
static const char* kGtk3FavoritesFixture =
    "{\n"
    "  \"favorites\": [\n"
    "    { \"path\": \"/home/raph/docs/one.pdf\", \"title\": \"one\", \"page\": 12, \"document\": false },\n"
    "    { \"path\": \"/home/raph/docs/two.pdf\", \"title\": \"two\", \"page\": 1, \"document\": true }\n"
    "  ]\n"
    "}\n";

static void test_favorites_gtk3_fixture(void) {
    char* dir = test_make_config_dir();
    SpdfState* state;
    const SpdfFavorite* favorite;

    test_write_state_file(dir, "favorites.json", kGtk3FavoritesFixture);
    state = spdf_state_load_from_dir(dir);

    g_assert_cmpuint(spdf_state_favorite_count(state), ==, 2);
    favorite = spdf_state_favorite(state, 0);
    g_assert_cmpstr(favorite->type, ==, "page");
    g_assert_cmpstr(favorite->path, ==, "/home/raph/docs/one.pdf");
    g_assert_cmpint(favorite->page, ==, 11); // 1-based legacy page migrated
    favorite = spdf_state_favorite(state, 1);
    g_assert_cmpstr(favorite->type, ==, "document");
    g_assert_cmpint(favorite->page, ==, 0);

    spdf_state_free(state);
    test_remove_tree(dir);
    g_free(dir);
}

// Byte-copy of the Mac favorites shape (top-level array, 0-based page).
static const char* kMacFavoritesFixture =
    "[\n"
    "  {\n"
    "    \"created\" : 1750000000,\n"
    "    \"labels\" : [\n"
    "      \"flex\",\n"
    "      \"usb\"\n"
    "    ],\n"
    "    \"name\" : \"one p.13\",\n"
    "    \"page\" : 12,\n"
    "    \"path\" : \"/Users/raph/one.pdf\",\n"
    "    \"title\" : \"one\",\n"
    "    \"type\" : \"page\"\n"
    "  }\n"
    "]";

static void test_favorites_mac_fixture_and_round_trip(void) {
    char* dir = test_make_config_dir();
    SpdfState* state;
    SpdfState* reloaded;
    const SpdfFavorite* favorite;
    SpdfFavorite added;
    char* labels[3] = {(char*)"dsi", (char*)"cabline", NULL};

    test_write_state_file(dir, "favorites.json", kMacFavoritesFixture);
    state = spdf_state_load_from_dir(dir);

    g_assert_cmpuint(spdf_state_favorite_count(state), ==, 1);
    favorite = spdf_state_favorite(state, 0);
    g_assert_cmpstr(favorite->type, ==, "page");
    g_assert_cmpint(favorite->page, ==, 12); // 0-based preserved
    g_assert_cmpstr(favorite->name, ==, "one p.13");
    g_assert_cmpint(favorite->created, ==, 1750000000);
    g_assert_nonnull(favorite->labels);
    g_assert_cmpstr(favorite->labels[0], ==, "flex");
    g_assert_cmpstr(favorite->labels[1], ==, "usb");
    g_assert_null(favorite->labels[2]);

    memset(&added, 0, sizeof(added));
    added.type = (char*)"page";
    added.path = (char*)"/Users/raph/one.pdf";
    added.title = (char*)"one";
    added.name = (char*)"one p.13 again";
    added.labels = labels;
    added.page = 12;
    added.created = 1750001111;
    spdf_state_add_favorite(state, &added); // dedupes the identical (path, page)
    g_assert_cmpuint(spdf_state_favorite_count(state), ==, 1);

    added.type = (char*)"document";
    added.page = 0;
    added.name = (char*)"one";
    spdf_state_add_favorite(state, &added); // document favorite coexists
    g_assert_cmpuint(spdf_state_favorite_count(state), ==, 2);
    spdf_state_flush(state);

    reloaded = spdf_state_load_from_dir(dir);
    g_assert_cmpuint(spdf_state_favorite_count(reloaded), ==, 2);
    favorite = spdf_state_favorite(reloaded, 0);
    g_assert_cmpstr(favorite->name, ==, "one p.13 again");
    g_assert_cmpint(favorite->created, ==, 1750001111);
    g_assert_nonnull(favorite->labels);
    g_assert_cmpstr(favorite->labels[0], ==, "dsi");
    g_assert_cmpstr(favorite->labels[1], ==, "cabline");
    favorite = spdf_state_favorite(reloaded, 1);
    g_assert_cmpstr(favorite->type, ==, "document");

    g_assert_true(spdf_state_remove_favorite(reloaded, 0));
    g_assert_cmpuint(spdf_state_favorite_count(reloaded), ==, 1);

    spdf_state_free(reloaded);
    spdf_state_free(state);
    test_remove_tree(dir);
    g_free(dir);
}

// --- documents.json ---------------------------------------------------------------

// Byte-copy of the Mac documents.json shape.
static const char* kMacDocumentsFixture =
    "{\n"
    "  \"/Users/raph/one.pdf\" : {\n"
    "    \"geometryFileSize\" : 123456,\n"
    "    \"geometryModifiedAt\" : 1750000000.25,\n"
    "    \"geometryPageCount\" : 2,\n"
    "    \"geometryVersion\" : 1,\n"
    "    \"pageGeometry\" : [\n"
    "      612,\n"
    "      792,\n"
    "      612,\n"
    "      1008\n"
    "    ],\n"
    "    \"path\" : \"/Users/raph/one.pdf\",\n"
    "    \"showMinimap\" : false,\n"
    "    \"showSidebar\" : true,\n"
    "    \"title\" : \"one\",\n"
    "    \"updatedAt\" : 1750000001\n"
    "  }\n"
    "}";

static void test_documents_mac_fixture(void) {
    char* dir = test_make_config_dir();
    SpdfState* state;
    const SpdfDocState* doc_state;

    test_write_state_file(dir, "documents.json", kMacDocumentsFixture);
    state = spdf_state_load_from_dir(dir);

    doc_state = spdf_state_document_lookup(state, "/Users/raph/one.pdf");
    g_assert_nonnull(doc_state);
    g_assert_cmpstr(doc_state->title, ==, "one");
    g_assert_true(doc_state->show_sidebar);
    g_assert_false(doc_state->show_minimap);
    g_assert_true(doc_state->has_show_sidebar);
    g_assert_cmpint(doc_state->updated_at, ==, 1750000001);
    g_assert_cmpint(doc_state->geometry_version, ==, 1);
    g_assert_cmpuint(doc_state->geometry_file_size, ==, 123456);
    g_assert_cmpint(doc_state->geometry_page_count, ==, 2);
    g_assert_nonnull(doc_state->page_geometry);
    g_assert_cmpfloat(doc_state->page_geometry[0], ==, 612.0);
    g_assert_cmpfloat(doc_state->page_geometry[3], ==, 1008.0);

    // mtime + size validation (park/restore rule).
    g_assert_true(spdf_doc_state_geometry_valid(doc_state, 123456, 1750000000.25, 2));
    g_assert_true(spdf_doc_state_geometry_valid(doc_state, 123456, 1750000000.2505, 2)); // within 1ms
    g_assert_false(spdf_doc_state_geometry_valid(doc_state, 123456, 1750000000.30, 2));  // stale mtime
    g_assert_false(spdf_doc_state_geometry_valid(doc_state, 123457, 1750000000.25, 2));  // size mismatch
    g_assert_false(spdf_doc_state_geometry_valid(doc_state, 123456, 1750000000.25, 3));  // page count
    g_assert_false(spdf_doc_state_geometry_valid(doc_state, 0, 1750000000.25, 2));       // no stat

    g_assert_null(spdf_state_document_lookup(state, "/Users/raph/other.pdf"));

    spdf_state_free(state);
    test_remove_tree(dir);
    g_free(dir);
}

static void test_documents_round_trip_and_version_gate(void) {
    char* dir = test_make_config_dir();
    SpdfState* state = spdf_state_load_from_dir(dir);
    SpdfState* reloaded;
    SpdfDocState update;
    const SpdfDocState* doc_state;
    double geometry[4] = {595.0, 842.0, 595.0, 842.0};

    memset(&update, 0, sizeof(update));
    update.path = (char*)"/tmp/docs/board.pdf";
    update.title = (char*)"board";
    update.show_sidebar = FALSE;
    update.show_minimap = TRUE;
    update.geometry_file_size = 777;
    update.geometry_modified_at = 1750009999.125;
    update.geometry_page_count = 2;
    update.page_geometry = geometry;
    spdf_state_document_update(state, &update);
    spdf_state_flush(state);

    reloaded = spdf_state_load_from_dir(dir);
    doc_state = spdf_state_document_lookup(reloaded, "/tmp/docs/board.pdf");
    g_assert_nonnull(doc_state);
    g_assert_cmpstr(doc_state->title, ==, "board");
    g_assert_false(doc_state->show_sidebar);
    g_assert_true(doc_state->show_minimap);
    g_assert_cmpint(doc_state->geometry_version, ==, SPDF_STATE_PAGE_GEOMETRY_VERSION);
    g_assert_cmpint(doc_state->geometry_page_count, ==, 2);
    g_assert_cmpfloat(doc_state->page_geometry[1], ==, 842.0);
    g_assert_true(spdf_doc_state_geometry_valid(doc_state, 777, 1750009999.125, 2));
    spdf_state_free(reloaded);

    // A future/unknown geometryVersion must invalidate the cache. Drop the
    // live YAML file first so the legacy-JSON fixture is the one migrated
    // and loaded (migration never overwrites an existing .yaml).
    {
        char* yaml_path = g_build_filename(dir, "documents.yaml", NULL);
        g_unlink(yaml_path);
        g_free(yaml_path);
    }
    test_write_state_file(dir, "documents.json",
                          "{\n"
                          "  \"/tmp/docs/board.pdf\" : {\n"
                          "    \"geometryFileSize\" : 777,\n"
                          "    \"geometryModifiedAt\" : 1750009999.125,\n"
                          "    \"geometryPageCount\" : 2,\n"
                          "    \"geometryVersion\" : 99,\n"
                          "    \"pageGeometry\" : [ 595, 842, 595, 842 ],\n"
                          "    \"path\" : \"/tmp/docs/board.pdf\",\n"
                          "    \"showMinimap\" : true,\n"
                          "    \"showSidebar\" : true,\n"
                          "    \"title\" : \"board\",\n"
                          "    \"updatedAt\" : 1750009999\n"
                          "  }\n"
                          "}\n");
    reloaded = spdf_state_load_from_dir(dir);
    doc_state = spdf_state_document_lookup(reloaded, "/tmp/docs/board.pdf");
    g_assert_nonnull(doc_state);
    g_assert_false(spdf_doc_state_geometry_valid(doc_state, 777, 1750009999.125, 2));
    spdf_state_free(reloaded);

    spdf_state_free(state);
    test_remove_tree(dir);
    g_free(dir);
}

// --- recents + closed ring ----------------------------------------------------------

static void test_recents_dedupe_and_cap(void) {
    char* dir = test_make_config_dir();
    SpdfState* state = spdf_state_load_from_dir(dir);
    char buffer[64];

    spdf_state_add_recent(state, "/tmp/a.pdf");
    spdf_state_add_recent(state, "/tmp/b.pdf");
    spdf_state_add_recent(state, "/tmp/a.pdf"); // moves to front, no duplicate
    g_assert_cmpint(spdf_state_recent_count(state), ==, 2);
    g_assert_cmpstr(spdf_state_recent_path(state, 0), ==, "/tmp/a.pdf");
    g_assert_cmpstr(spdf_state_recent_path(state, 1), ==, "/tmp/b.pdf");

    for (int i = 0; i < 12; ++i) {
        g_snprintf(buffer, sizeof(buffer), "/tmp/doc-%d.pdf", i);
        spdf_state_add_recent(state, buffer);
    }
    g_assert_cmpint(spdf_state_recent_count(state), ==, SPDF_STATE_MAX_RECENT_DOCUMENTS);
    g_assert_cmpstr(spdf_state_recent_path(state, 0), ==, "/tmp/doc-11.pdf");

    spdf_state_remove_recent(state, "/tmp/doc-11.pdf");
    g_assert_cmpint(spdf_state_recent_count(state), ==, SPDF_STATE_MAX_RECENT_DOCUMENTS - 1);
    g_assert_cmpstr(spdf_state_recent_path(state, 0), ==, "/tmp/doc-10.pdf");

    spdf_state_free(state);
    test_remove_tree(dir);
    g_free(dir);
}

static void test_closed_ring(void) {
    char* dir = test_make_config_dir();
    SpdfState* state = spdf_state_load_from_dir(dir);
    char buffer[64];
    char* popped;

    g_assert_null(spdf_state_pop_closed(state));
    for (int i = 1; i <= 12; ++i) {
        g_snprintf(buffer, sizeof(buffer), "/tmp/closed-%d.pdf", i);
        spdf_state_remember_closed(state, buffer);
    }
    g_assert_cmpint(spdf_state_closed_count(state), ==, SPDF_STATE_MAX_CLOSED_DOCUMENTS);

    popped = spdf_state_pop_closed(state); // LIFO
    g_assert_cmpstr(popped, ==, "/tmp/closed-12.pdf");
    g_free(popped);
    for (int i = 0; i < SPDF_STATE_MAX_CLOSED_DOCUMENTS - 2; ++i) g_free(spdf_state_pop_closed(state));
    popped = spdf_state_pop_closed(state); // oldest two fell off the ring
    g_assert_cmpstr(popped, ==, "/tmp/closed-3.pdf");
    g_free(popped);
    g_assert_null(spdf_state_pop_closed(state));

    spdf_state_free(state);
    test_remove_tree(dir);
    g_free(dir);
}

// --- write coalescing ----------------------------------------------------------------

static void test_writes_are_coalesced_until_flush(void) {
    char* dir = test_make_config_dir();
    SpdfState* state = spdf_state_load_from_dir(dir);
    char* path = g_build_filename(dir, "settings.yaml", NULL);

    spdf_state_save_settings(state);
    spdf_state_save_settings(state); // marking dirty twice arms one timer
    g_assert_false(g_file_test(path, G_FILE_TEST_EXISTS)); // nothing hit disk yet

    spdf_state_flush(state);
    g_assert_true(g_file_test(path, G_FILE_TEST_EXISTS));

    spdf_state_free(state);
    g_free(path);
    test_remove_tree(dir);
    g_free(dir);
}

static void test_suppressed_session_writes(void) {
    char* dir = test_make_config_dir();
    SpdfState* state = spdf_state_load_from_dir(dir);
    SpdfSessionWindow* win = spdf_session_window_new(NULL);
    SpdfSessionTab* tab = spdf_session_window_add_tab(win);
    char* path = g_build_filename(dir, "session.yaml", NULL);

    tab->path = g_strdup("/tmp/x.pdf");
    g_assert_nonnull(win->id); // NULL id gets a "gtk-<pid>-<us>" identity
    g_assert_true(g_str_has_prefix(win->id, "gtk-"));

    spdf_state_set_suppress_session_write(state, TRUE);
    spdf_state_update_session_window(state, win);
    spdf_state_flush(state);
    g_assert_false(g_file_test(path, G_FILE_TEST_EXISTS));

    spdf_state_set_suppress_session_write(state, FALSE);
    spdf_state_save_session(state);
    spdf_state_flush(state);
    g_assert_true(g_file_test(path, G_FILE_TEST_EXISTS));

    spdf_state_free(state);
    g_free(path);
    test_remove_tree(dir);
    g_free(dir);
}

// --- geometry clamp (June defect #3) ---------------------------------------------------

static void test_clamp_geometry(void) {
    GdkRectangle wa = {0, 0, 1920, 1160};
    GdkRectangle frame;

    // Fully visible frame: untouched.
    frame = (GdkRectangle){100, 100, 800, 600};
    spdf_state_clamp_geometry(&wa, &frame);
    g_assert_cmpint(frame.x, ==, 100);
    g_assert_cmpint(frame.y, ==, 100);
    g_assert_cmpint(frame.width, ==, 800);
    g_assert_cmpint(frame.height, ==, 600);

    // Restored on a monitor that no longer exists: centered on the workarea.
    frame = (GdkRectangle){5000, 5000, 800, 600};
    spdf_state_clamp_geometry(&wa, &frame);
    g_assert_cmpint(frame.x, ==, 560);
    g_assert_cmpint(frame.y, ==, 280);

    // Partially off the left edge with plenty visible: origin clamped in.
    frame = (GdkRectangle){-700, 100, 800, 600};
    spdf_state_clamp_geometry(&wa, &frame);
    g_assert_cmpint(frame.x, ==, 0);
    g_assert_cmpint(frame.y, ==, 100);

    // Only a sliver visible in the corner (< 80x80): treated as off-screen.
    frame = (GdkRectangle){1900, 1150, 800, 600};
    spdf_state_clamp_geometry(&wa, &frame);
    g_assert_cmpint(frame.x, ==, 560);
    g_assert_cmpint(frame.y, ==, 280);

    // Larger than the workarea: shrunk to fit, pinned at the origin edge.
    frame = (GdkRectangle){0, 0, 4000, 3000};
    spdf_state_clamp_geometry(&wa, &frame);
    g_assert_cmpint(frame.width, ==, 1920);
    g_assert_cmpint(frame.height, ==, 1160);
    g_assert_cmpint(frame.x, ==, 0);
    g_assert_cmpint(frame.y, ==, 0);

    // Below the minimum size: raised to the floor.
    frame = (GdkRectangle){10, 10, 100, 100};
    spdf_state_clamp_geometry(&wa, &frame);
    g_assert_cmpint(frame.width, ==, SPDF_STATE_MIN_WINDOW_WIDTH);
    g_assert_cmpint(frame.height, ==, SPDF_STATE_MIN_WINDOW_HEIGHT);

    // Offset workarea (panel on the left/top): centering respects the offset.
    wa = (GdkRectangle){100, 50, 1000, 800};
    frame = (GdkRectangle){-2000, -2000, 800, 600};
    spdf_state_clamp_geometry(&wa, &frame);
    g_assert_cmpint(frame.x, ==, 200);
    g_assert_cmpint(frame.y, ==, 150);

    // No usable workarea (headless / unknown monitor): only hard caps apply.
    frame = (GdkRectangle){0, 0, 9000, 100};
    spdf_state_clamp_geometry(NULL, &frame);
    g_assert_cmpint(frame.width, ==, SPDF_STATE_MAX_WINDOW_WIDTH);
    g_assert_cmpint(frame.height, ==, SPDF_STATE_MIN_WINDOW_HEIGHT);
}

int main(int argc, char** argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/state/settings/gtk3-fixture", test_settings_gtk3_fixture);
    g_test_add_func("/state/settings/mac-fixture", test_settings_mac_fixture);
    g_test_add_func("/state/settings/round-trip", test_settings_round_trip);
    g_test_add_func("/state/session/gtk3-fixture", test_session_gtk3_fixture);
    g_test_add_func("/state/session/mac-fixture", test_session_mac_fixture);
    g_test_add_func("/state/session/round-trip", test_session_round_trip);
    g_test_add_func("/state/session/merge-foreign-windows", test_session_merge_preserves_foreign_windows);
    g_test_add_func("/state/session/legacy-single-document", test_session_legacy_single_document);
    g_test_add_func("/state/favorites/gtk3-fixture", test_favorites_gtk3_fixture);
    g_test_add_func("/state/favorites/mac-fixture-round-trip", test_favorites_mac_fixture_and_round_trip);
    g_test_add_func("/state/documents/mac-fixture", test_documents_mac_fixture);
    g_test_add_func("/state/documents/round-trip-version-gate", test_documents_round_trip_and_version_gate);
    g_test_add_func("/state/recents/dedupe-and-cap", test_recents_dedupe_and_cap);
    g_test_add_func("/state/closed-ring", test_closed_ring);
    g_test_add_func("/state/writes/coalesced-until-flush", test_writes_are_coalesced_until_flush);
    g_test_add_func("/state/writes/suppressed-session", test_suppressed_session_writes);
    g_test_add_func("/state/clamp-geometry", test_clamp_geometry);
    return g_test_run();
}
