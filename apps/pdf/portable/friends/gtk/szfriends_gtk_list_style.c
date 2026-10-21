/* The pages' stylesheet (szfriends_gtk_list_page.h § Shared by every page): the rules the list, its rows, the
 * footer, the notices and the other pages share, loaded once per display. The ways out, the confirmation and action
 * running stay in szfriends_gtk_list_support.c. */

#include "gtk/szfriends_gtk_list_page.h"

#include <adwaita.h>

/* The AppKit views' metrics (mac/SZFriendsListPage.m, SZFriendsRowView.m), in the views' colour tokens so a host's
 * appearance_css restyles these too. Colours only through tokens: no media query is needed for dark. Secondary text
 * is @szfriends_secondary_text (.szfriends-secondary, .szfriends-caption), never libadwaita's .dimmed: its 55 %
 * opacity measures 3.2:1 on white, under the 4.5:1 that text of 11 to 13 px needs. */
static const char list_css[] =
    ".szfriends-list-search { margin: 0 6px; }\n"
    ".szfriends-tabs { margin: 2px 12px 8px 12px; }\n"
    ".szfriends-notice { border-radius: 8px; padding: 10px; margin: 0 12px 8px 12px; }\n"
    ".szfriends-notice.send { border: 1.5px dashed alpha(@szfriends_accent, 0.7); }\n"
    ".szfriends-notice.banner { background-color: alpha(@szfriends_warning, 0.14); }\n"
    ".szfriends-notice.prompt { background-color: @szfriends_field_background; }\n"
    ".szfriends-notice-title { font-weight: 600; }\n"
    ".szfriends-caption { font-size: 0.85em; color: @szfriends_secondary_text; }\n"
    ".szfriends-secondary { color: @szfriends_secondary_text; }\n"
    ".szfriends-caption.szfriends-success { color: @szfriends_success; }\n"
    ".szfriends-empty-title { font-weight: 600; }\n"
    "button.szfriends-link { color: @szfriends_accent; font-weight: 600; padding: 2px 4px; min-height: 0; }\n"
    "szfriends-row { border-radius: 8px; margin: 0 6px; padding-right: 8px; }\n"
    "szfriends-row.clickable:hover { background-color: @szfriends_hover; }\n"
    "szfriends-row:focus-visible { outline: 2px solid alpha(@szfriends_accent, 0.5); outline-offset: -2px; }\n"
    "szfriends-row.drop-accept { background-color: @szfriends_selection;\n"
    "  box-shadow: inset 0 0 0 1.5px @szfriends_accent; }\n"
    "szfriends-row.drop-refuse { background-color: alpha(@szfriends_warning, 0.18); }\n"
    "szfriends-row.dimmed .szfriends-row-fade { opacity: 0.4; }\n"
    "szfriends-row.muted szfriends-avatar { opacity: 0.45; }\n"
    "szfriends-row.muted .szfriends-row-title { color: @szfriends_secondary_text; }\n"
    ".szfriends-row-title { font-weight: 600; }\n"
    ".szfriends-row-subtitle, .szfriends-row-status, .szfriends-row-found-label {\n"
    "  color: @szfriends_secondary_text; }\n"
    ".szfriends-row-subtitle.waiting { color: @szfriends_accent; }\n"
    ".szfriends-row-time { color: @szfriends_secondary_text; font-size: 0.85em; }\n"
    ".szfriends-row-bar { background-color: @szfriends_accent; border-radius: 2px; min-width: 3px; }\n"
    ".szfriends-row-dot { background-color: @szfriends_accent; border-radius: 4px; min-width: 7px;\n"
    "  min-height: 7px; }\n"
    ".szfriends-pill { background-color: @szfriends_accent; color: @szfriends_background; font-weight: bold;\n"
    "  font-size: 10px; border-radius: 4px; padding: 1px 5px; }\n"
    ".szfriends-pill.drop { font-size: 12px; padding: 2px 5px; }\n"
    ".szfriends-pill.warning { background-color: @szfriends_warning; }\n"
    ".szfriends-route { color: @szfriends_offline_route; }\n"
    ".szfriends-route.local { color: @szfriends_local_route; }\n"
    ".szfriends-found-icon { color: @szfriends_local_route; }\n"
    ".szfriends-route.online { color: @szfriends_online_route; }\n"
    ".szfriends-id-check { color: @szfriends_success; }\n"
    "button.szfriends-row-action { min-width: 28px; min-height: 28px; padding: 0; border-radius: 14px;\n"
    "  background: none; box-shadow: none; color: @szfriends_text; }\n"
    "button.szfriends-row-action:hover { background-color: @szfriends_hover; }\n"
    "button.szfriends-row-action.accept { color: @szfriends_success; }\n"
    "button.szfriends-row-action.worded { padding: 0 11px; font-weight: 600; font-size: 12px; }\n"
    "button.szfriends-row-action.worded.accept { background-color: @szfriends_primary_button;\n"
    "  color: @szfriends_primary_button_text; }\n"
    "button.szfriends-row-action.worded.decline { color: @szfriends_text;\n"
    "  box-shadow: inset 0 0 0 1px alpha(currentColor, 0.25); }\n"
    "button.szfriends-row-action.block, button.szfriends-row-action.armed { color: @szfriends_destructive; }\n"
    /* A row's menu: Remove in the destructive colour, as the confirmation's button that follows it. */
    ".szfriends-row-menu modelbutton.szfriends-menu-destructive { color: @szfriends_destructive; }\n"
    "button.szfriends-row-action.armed { padding: 0 10px 0 8px; font-weight: bold; font-size: 12px;\n"
    "  background-color: mix(@szfriends_background, @szfriends_destructive, 0.12);\n"
    "  box-shadow: inset 0 0 0 1px alpha(@szfriends_destructive, 0.6); }\n"
    ".szfriends-footer { border-top: 1px solid @szfriends_separator; padding: 10px 12px; }\n"
    "button.szfriends-footer-button { padding: 2px 6px; min-height: 0; }\n"
    "button.szfriends-footer-button label { font-weight: normal; }\n"
    "button.szfriends-footer-button label.szfriends-footer-name { font-weight: 600; }\n"
    ".szfriends-visibility.visible { background-color: alpha(@szfriends_accent, 0.12); border-radius: 8px;\n"
    "  border: 1px solid alpha(@szfriends_accent, 0.45); padding: 12px; }\n"
    ".szfriends-countdown { font-size: 20px; font-weight: 600; font-feature-settings: \"tnum\"; }\n"
    ".szfriends-alert { background-color: alpha(@szfriends_warning, 0.14); border-radius: 8px;\n"
    "  border: 1px solid alpha(@szfriends_warning, 0.45); padding: 12px; }\n"
    ".szfriends-people-header { font-weight: 600; font-size: 0.85em; color: @szfriends_secondary_text; }\n"
    ".szfriends-confirm { margin: 0 16px; }\n"
    /* Several computers: a join request waits for the person like a request row; its code is read digit by digit. */
    ".szfriends-join-request { background-color: alpha(@szfriends_accent, 0.08); border-radius: 10px;\n"
    "  border: 1px solid alpha(@szfriends_accent, 0.5); padding: 12px; margin: 0 12px 8px 12px; }\n"
    ".szfriends-join-code { font-size: 28px; font-weight: 600; font-feature-settings: \"tnum\"; }\n"
    ".szfriends-device-dot { border-radius: 5px; min-width: 8px; min-height: 8px;\n"
    "  border: 1px solid @szfriends_secondary_text; }\n"
    ".szfriends-device-dot.connected { background-color: @szfriends_success; border-color: @szfriends_success; }\n"
    ".szfriends-confirm-face { padding: 16px; }\n"
    /* Text actions (Remove friend, Block, Use your own picture) start where the column's words start, as AppKit
     * draws them: no side padding, so their notes need no indent to sit under them. Armed, a pill gets its padding
     * back with its fill. */
    "button.flat.szfriends-text-action { padding-left: 0; padding-right: 0; min-width: 0; }\n"
    /* Friends is a beta: the title beside the search field, with a small tag that says so. */
    ".szfriends-list-title { font-weight: 600; }\n"
    ".szfriends-beta { background-color: alpha(@szfriends_accent, 0.14); color: @szfriends_accent; border-radius: 4px;\n"
    "  font-size: 10px; font-weight: 600; padding: 1px 5px; }\n";

void szfriends_gtk_list_style_ensure(GtkWidget *widget) {
    GdkDisplay *display = widget ? gtk_widget_get_display(widget) : gdk_display_get_default();
    if (!display || g_object_get_data(G_OBJECT(display), "szfriends-list-style")) return;
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_string(provider, list_css);
    /* The views' priority: the host's provider (one above) still redefines the tokens these rules use. */
    gtk_style_context_add_provider_for_display(display, GTK_STYLE_PROVIDER(provider),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_set_data_full(G_OBJECT(display), "szfriends-list-style", provider, g_object_unref);
}
