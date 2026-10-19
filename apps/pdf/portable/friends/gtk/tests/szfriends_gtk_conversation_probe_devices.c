/* Files another of the person's computers holds, and You (PROTOCOL.md § Devices), offscreen against the fake helper:
 * a file on another computer says where it is and offers Get, which fetches it by its transfer_id; a copy under way
 * shows its progress with Cancel; and You copies a file to every computer. Rendered light and dark. */

#include "szfriends_gtk_conversation_probe.h"

#include <string.h>

static void serve(SZFGHarness *harness, const char *fixture) {
    char *data = szfg_conv_data_with_previews(harness, fixture, NULL);
    EXPECT(data && szfriends_fake_helper_set_view_data(harness->fake, "conversation", data) == SZFRIENDS_OK,
           "%s served", fixture);
    g_free(data);
}

static void test_files_on_other_computers(SZFGHarness *harness) {
    serve(harness, "devices-conversation-mei-files.json");
    SZFGConv *conv = szfg_conv_open(harness, "c_mei");
    szfg_pump_for(50);
    szfg_conv_layout(conv);
    GtkWidget *root = szfg_conv_root(conv);
    EXPECT(szfg_find_label(root, "On Raph’s Mac mini") != NULL, "a file on another computer says where it is");
    GtkWidget *get = szfg_find_button(root, "Get");
    EXPECT(get && gtk_widget_has_css_class(get, "suggested-action"), "and offers Get");
    guint before = szfg_fake_frames(harness, "fetch_from_device", NULL, NULL);
    if (get) g_signal_emit_by_name(get, "clicked");
    EXPECT(szfg_conv_wait_frames(harness, "fetch_from_device", before) &&
               szfg_fake_frames(harness, "fetch_from_device", "transfer_id", "t_c81f04d2") == before + 1,
           "Get fetches it by its transfer_id");
    EXPECT(szfg_find_label(root, "Copying from Raph’s Mac mini · 25%") != NULL &&
               szfg_find_label(root, "Copies when Studio workstation is nearby") != NULL,
           "a copy under way and one waiting for its computer say so");
    before = szfg_fake_frames(harness, "cancel_transfer", NULL, NULL);
    GtkWidget *cancel = szfg_find_button(root, "Cancel");
    if (cancel) g_signal_emit_by_name(cancel, "clicked");
    EXPECT(szfg_conv_wait_frames(harness, "cancel_transfer", before) &&
               szfg_fake_frames(harness, "cancel_transfer", "transfer_id", "t_4d9b7a35") >= 1,
           "Cancel stops the copy");
    for (int dark = 0; dark < 2; dark++) {
        szfg_set_dark(dark);
        szfg_conv_render(conv, dark ? "devices-files-dark" : "devices-files-light");
    }
    szfg_set_dark(FALSE);
    szfg_conv_close(conv);

    serve(harness, "devices-conversation-you.json");
    conv = szfg_conv_open(harness, "you");
    szfg_pump_for(50);
    szfg_conv_layout(conv);
    root = szfg_conv_root(conv);
    EXPECT(szfg_find_label(root, "Copying to your other computers · 40%") != NULL &&
               szfg_find_label(root, "On all your computers") != NULL,
           "You: a file copies to every computer, a message says it is on all of them");
    szfg_conv_render(conv, "devices-you-light");
    szfg_conv_close(conv);
}

void szfg_run_conversation_device_probes(void) {
    SZFGHarness *harness = szfg_conv_harness("conversation-devices", NULL);
    test_files_on_other_computers(harness);
    szfg_harness_free(harness);
}
