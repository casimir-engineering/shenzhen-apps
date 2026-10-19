// spdf_props.c — document-properties panel (Ctrl+I). See spdf_props.h.
// Port of SPDFMacPropertiesPanel.mm: grouped read-only rows built from core
// metadata + on-disk file info, an async-free Linux variant (no word-count
// walk — the Mac "Text" statistics row needs a per-document worker; the rest
// of the panel is cheap and builds synchronously on open). Formatting rules
// live in spdf_props_internal.h (ports of SPDFMacPropertiesFormat.mm).

#include <string.h>

#include "spdf_app.h"
#include "spdf_props.h"
#include "spdf_props_internal.h"

// Panel geometry (Mac: 560pt panel, 520pt max scroll height).
#define PROPS_DIALOG_WIDTH 480
#define PROPS_MAX_CONTENT_HEIGHT 560
// On-disk dates only show when the PDF metadata date is missing or differs
// meaningfully (Mac rule: > 60 s).
#define PROPS_DATE_SLOP_SECONDS 60.0

// ---------------------------------------------------------------------------
// Data helpers

static char* props_metadata(spdf_document* doc, const char* key) {
    char buffer[4096];
    if (!spdf_lookup_metadata(doc, key, buffer, sizeof(buffer))) return g_strdup("");
    return g_strstrip(g_strdup(buffer));
}

static char* props_display_date(GDateTime* date) {
    return date ? g_date_time_format(date, "%x %R") : g_strdup(""); // medium date + short time
}

static int props_outline_count(SpdfTab* tab) {
    spdf_outline outline;
    char err[256] = "";
    int count = 0;

    if (tab->outline_loaded) return tab->outline.count; // sidebar cache (spdf_sidebar.c)
    memset(&outline, 0, sizeof(outline));
    if (tab->doc && spdf_load_outline(tab->doc, &outline, err, sizeof(err))) {
        count = outline.count;
        spdf_free_outline(&outline);
    }
    return count;
}

static int props_comment_count(SpdfTab* tab) {
    spdf_comments comments;
    char err[256] = "";
    int count = 0;

    if (tab->comments_loaded) return tab->comments.count; // annot cache (spdf_annot.c)
    memset(&comments, 0, sizeof(comments));
    if (tab->doc && spdf_load_comments(tab->doc, &comments, err, sizeof(err))) {
        count = comments.count;
        spdf_free_comments(&comments);
    }
    return count;
}

// ---------------------------------------------------------------------------
// Row/group building. Every row is appended to the Copy All transcript too
// (Mac copyAll: "Section\n  Label: Value").

typedef struct {
    GtkWidget* box; // vertical box of AdwPreferencesGroup
    AdwPreferencesGroup* group;
    GString* transcript;
} PropsBuilder;

static void props_begin_group(PropsBuilder* b, const char* title) {
    b->group = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(b->group, title);
    gtk_box_append(GTK_BOX(b->box), GTK_WIDGET(b->group));
    if (b->transcript->len) g_string_append_c(b->transcript, '\n');
    g_string_append_printf(b->transcript, "%s\n", title);
}

static void props_add_row_full(PropsBuilder* b, const char* label, const char* value, const char* tooltip) {
    GtkWidget* row = adw_action_row_new();

    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), label);
    adw_action_row_set_subtitle(ADW_ACTION_ROW(row), value ? value : "");
    adw_action_row_set_subtitle_selectable(ADW_ACTION_ROW(row), TRUE);
    gtk_widget_add_css_class(row, "property");
    if (tooltip && *tooltip) gtk_widget_set_tooltip_text(row, tooltip);
    adw_preferences_group_add(b->group, row);
    g_string_append_printf(b->transcript, "  %s: %s\n", label, value ? value : "");
}

static void props_add_row(PropsBuilder* b, const char* label, const char* value) {
    props_add_row_full(b, label, value, NULL);
}

/* Adds the row only when the value is non-empty (Mac: metadata rows with
 * empty values are omitted). */
static void props_add_row_nonempty(PropsBuilder* b, const char* label, const char* value) {
    if (value && *value) props_add_row(b, label, value);
}

// ---------------------------------------------------------------------------
// Section content (port of buildSectionsForDocument)

static void props_build_file_group(PropsBuilder* b, SpdfTab* tab, GFileInfo* info) {
    char* format = props_metadata(tab->doc, "format");

    props_begin_group(b, "File");
    props_add_row_full(b, "Location", tab->path, tab->path);
    if (info) {
        char* size = spdf_props_format_file_size(g_file_info_get_size(info));
        props_add_row(b, "Size", size);
        g_free(size);
    }
    if (!*format && tab->path) {
        const char* dot = strrchr(tab->path, '.');
        if (dot && dot[1]) {
            g_free(format);
            format = g_ascii_strup(dot + 1, -1);
        }
    }
    props_add_row_nonempty(b, "Format", format);
    g_free(format);
}

/* Dates: PDF metadata dates first (raw string as tooltip; unparseable values
 * shown verbatim); on-disk dates appear when there is no PDF counterpart or
 * when they differ meaningfully (> 60 s). */
static void props_build_dates_group(PropsBuilder* b, SpdfTab* tab, GFileInfo* info) {
    char* raw_created = props_metadata(tab->doc, "info:CreationDate");
    char* raw_modified = props_metadata(tab->doc, "info:ModDate");
    GDateTime* pdf_created = spdf_props_parse_pdf_date(raw_created);
    GDateTime* pdf_modified = spdf_props_parse_pdf_date(raw_modified);
    GDateTime* disk_created = info ? g_file_info_get_creation_date_time(info) : NULL;
    GDateTime* disk_modified = info ? g_file_info_get_modification_date_time(info) : NULL;
    gboolean any = *raw_created || *raw_modified || disk_created || disk_modified;

    if (any) {
        props_begin_group(b, "Dates");
        if (pdf_created) {
            char* text = props_display_date(pdf_created);
            props_add_row_full(b, "Created", text, raw_created);
            g_free(text);
        } else if (*raw_created) {
            props_add_row(b, "Created", raw_created);
        }
        if (pdf_modified) {
            char* text = props_display_date(pdf_modified);
            props_add_row_full(b, "Modified", text, raw_modified);
            g_free(text);
        } else if (*raw_modified) {
            props_add_row(b, "Modified", raw_modified);
        }
        if (disk_created &&
            (!pdf_created ||
             ABS(g_date_time_difference(disk_created, pdf_created)) > PROPS_DATE_SLOP_SECONDS * G_TIME_SPAN_SECOND)) {
            char* text = props_display_date(disk_created);
            props_add_row(b, "Created (on disk)", text);
            g_free(text);
        }
        if (disk_modified && (!pdf_modified || ABS(g_date_time_difference(disk_modified, pdf_modified)) >
                                                   PROPS_DATE_SLOP_SECONDS * G_TIME_SPAN_SECOND)) {
            char* text = props_display_date(disk_modified);
            props_add_row(b, "Modified (on disk)", text);
            g_free(text);
        }
    }
    if (disk_created) g_date_time_unref(disk_created);
    if (disk_modified) g_date_time_unref(disk_modified);
    if (pdf_created) g_date_time_unref(pdf_created);
    if (pdf_modified) g_date_time_unref(pdf_modified);
    g_free(raw_created);
    g_free(raw_modified);
}

static void props_build_document_group(PropsBuilder* b, SpdfTab* tab) {
    static const struct {
        const char* label;
        const char* key;
    } k_metadata_rows[] = {
        {"Title", "info:Title"},     {"Author", "info:Author"},     {"Subject", "info:Subject"},
        {"Keywords", "info:Keywords"}, {"Creator", "info:Creator"}, {"Producer", "info:Producer"},
    };
    char* encryption = props_metadata(tab->doc, "encryption");
    char* security;

    props_begin_group(b, "Document");
    for (gsize i = 0; i < G_N_ELEMENTS(k_metadata_rows); ++i) {
        char* value = props_metadata(tab->doc, k_metadata_rows[i].key);
        props_add_row_nonempty(b, k_metadata_rows[i].label, value);
        g_free(value);
    }
    if (strcmp(encryption, "None") == 0) encryption[0] = '\0';
    if (*encryption && spdf_needs_password(tab->doc)) {
        char* with_note = g_strconcat(encryption, " (password protected)", NULL);
        g_free(encryption);
        encryption = with_note;
    }
    security = spdf_props_security_summary(encryption, spdf_has_permission(tab->doc, 'p'),
                                           spdf_has_permission(tab->doc, 'c'), spdf_has_permission(tab->doc, 'e'),
                                           spdf_has_permission(tab->doc, 'n'));
    props_add_row(b, "Security", security);
    g_free(security);
    g_free(encryption);
}

static void props_build_statistics_group(PropsBuilder* b, SpdfTab* tab) {
    int page_count = spdf_page_count(tab->doc);
    int page_index = tab->view ? spdf_doc_view_current_page(tab->view) : 0;
    int outline_count = props_outline_count(tab);
    int comment_count = props_comment_count(tab);
    char* grouped;

    props_begin_group(b, "Statistics");
    grouped = spdf_props_grouped_number((guint64)MAX(0, page_count));
    props_add_row(b, "Pages", grouped);
    g_free(grouped);

    if (page_index >= 0 && page_index < page_count) {
        float width = 0, height = 0;
        char err[256] = "";
        if (spdf_page_size(tab->doc, page_index, &width, &height, err, sizeof(err))) {
            char* size = spdf_props_format_page_size(width, height);
            if (*size) {
                char* label = g_strdup_printf("Page %d size", page_index + 1);
                props_add_row(b, label, size);
                g_free(label);
            }
            g_free(size);
        }
    }

    if (outline_count > 0) {
        grouped = spdf_props_grouped_number((guint64)outline_count);
        char* value = g_strdup_printf("%s entries", grouped);
        props_add_row(b, "Table of contents", value);
        g_free(value);
        g_free(grouped);
    } else {
        props_add_row(b, "Table of contents", "None");
    }
    if (comment_count > 0) {
        grouped = spdf_props_grouped_number((guint64)comment_count);
        props_add_row(b, "Annotations", grouped);
        g_free(grouped);
    } else {
        props_add_row(b, "Annotations", "None");
    }
    // The Mac panel adds a Fonts-like "Text" word-count row here from an async
    // document walk; the core exposes no font enumeration and the count needs
    // a worker document, so both are deliberately absent on Linux.
}

// ---------------------------------------------------------------------------
// Copy All

static void props_copy_all_clicked(GtkButton* button, gpointer user_data) {
    const char* transcript = g_object_get_data(G_OBJECT(button), "spdf-transcript");
    GtkWidget* dialog = user_data;
    if (transcript) gdk_clipboard_set_text(gtk_widget_get_clipboard(dialog), transcript);
}

// ---------------------------------------------------------------------------
// Panel construction + action

static void props_present(SpdfWindow* win, SpdfTab* tab) {
    PropsBuilder builder;
    AdwDialog* dialog;
    GtkWidget* toolbar_view;
    GtkWidget* header;
    GtkWidget* scroller;
    GtkWidget* clamp;
    GtkWidget* copy_button;
    GFile* file;
    GFileInfo* info;
    char* base;

    file = g_file_new_for_path(tab->path);
    info = g_file_query_info(file, G_FILE_ATTRIBUTE_STANDARD_SIZE "," G_FILE_ATTRIBUTE_TIME_MODIFIED
                             "," G_FILE_ATTRIBUTE_TIME_CREATED,
                             G_FILE_QUERY_INFO_NONE, NULL, NULL);
    g_object_unref(file);

    builder.box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 18);
    builder.group = NULL;
    builder.transcript = g_string_new("");
    gtk_widget_set_margin_top(builder.box, 12);
    gtk_widget_set_margin_bottom(builder.box, 18);
    gtk_widget_set_margin_start(builder.box, 12);
    gtk_widget_set_margin_end(builder.box, 12);

    props_build_file_group(&builder, tab, info);
    props_build_dates_group(&builder, tab, info);
    props_build_document_group(&builder, tab);
    props_build_statistics_group(&builder, tab);
    if (info) g_object_unref(info);

    clamp = adw_clamp_new();
    adw_clamp_set_child(ADW_CLAMP(clamp), builder.box);
    scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(scroller), TRUE);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(scroller), PROPS_MAX_CONTENT_HEIGHT);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), clamp);

    header = adw_header_bar_new();
    copy_button = gtk_button_new_from_icon_name("edit-copy-symbolic");
    gtk_widget_set_tooltip_text(copy_button, "Copy all properties");
    adw_header_bar_pack_start(ADW_HEADER_BAR(header), copy_button);

    toolbar_view = adw_toolbar_view_new();
    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(toolbar_view), header);
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(toolbar_view), scroller);

    dialog = adw_dialog_new();
    base = g_path_get_basename(tab->path ? tab->path : "Untitled");
    adw_dialog_set_title(dialog, base);
    g_free(base);
    adw_dialog_set_content_width(dialog, PROPS_DIALOG_WIDTH);
    adw_dialog_set_child(dialog, toolbar_view);

    g_object_set_data_full(G_OBJECT(copy_button), "spdf-transcript", g_string_free(builder.transcript, FALSE),
                           g_free);
    g_signal_connect(copy_button, "clicked", G_CALLBACK(props_copy_all_clicked), toolbar_view);

    adw_dialog_present(dialog, GTK_WIDGET(win)); // Escape closes (AdwDialog default)
}

static void action_properties(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    (void)action;
    (void)parameter;
    if (tab && tab->doc && tab->path) props_present(win, tab);
}

static const GActionEntry k_props_actions[] = {
    {"properties", action_properties, NULL, NULL, NULL, {0}},
};

void spdf_props_install(SpdfWindow* win) {
    g_return_if_fail(SPDF_IS_WINDOW(win));
    g_action_map_add_action_entries(G_ACTION_MAP(win), k_props_actions, G_N_ELEMENTS(k_props_actions), win);
}
