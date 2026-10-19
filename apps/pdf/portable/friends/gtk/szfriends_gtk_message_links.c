/* What a click on a message's words does, and the words of the link menu (szfriends_gtk_conversation.h). Display-free.
 *
 * WHY a menu rather than opening on click (as mac/SZFriendsLinkMenu.m): a link's words are the sender's, and they can
 * show one address while the link goes to another. The menu says where the link really goes before anything opens,
 * and warns first when the words name another site or address. The rules here are the AppKit ones, so both apps warn
 * about the same links. */

#include "gtk/szfriends_gtk_conversation.h"

#include <string.h>

/* Longer addresses lose the end of their path in the menu, never their host. */
#define SZFRIENDS_GTK_LINK_TITLE_LENGTH 80
/* Plain text shown before Show all, and how far back a cut looks for a space (characters). */
#define SZFRIENDS_GTK_PLAIN_SHOWN 4096
#define SZFRIENDS_GTK_PLAIN_LOOK_BACK 256

static char *scheme_of(const char *url) {
    char *scheme = url ? g_uri_parse_scheme(url) : NULL;
    if (!scheme) return NULL;
    char *lower = g_ascii_strdown(scheme, -1);
    g_free(scheme);
    return lower;
}

gboolean szfriends_gtk_link_may_open(const char *url) {
    /* A friend's message must not open file: or app-scheme URLs; only the web and email. */
    char *scheme = scheme_of(url);
    gboolean web = scheme && (strcmp(scheme, "https") == 0 || strcmp(scheme, "http") == 0);
    gboolean mail = scheme && strcmp(scheme, "mailto") == 0;
    g_free(scheme);
    if (!web && !mail) return FALSE;
    GUri *uri = g_uri_parse(url, G_URI_FLAGS_PARSE_RELAXED, NULL);
    gboolean ok = uri && (mail || (g_uri_get_host(uri) && *g_uri_get_host(uri)));
    if (uri) g_uri_unref(uri);
    return ok;
}

SZFriendsGtkHit szfriends_gtk_link_hit(const SZFriendsGtkConversationItem *item, gsize index) {
    SZFriendsGtkHit hit = {SZFRIENDS_GTK_HIT_NONE, NULL, NULL};
    if (!item || index >= item->n_segments) return hit;
    const SZFriendsGtkSegment *segment = &item->segments[index];
    const char *destination = segment->url;
    if (segment->mention.set) {
        gint64 n = segment->mention.value;
        destination = n >= 0 && (guint64)n < item->n_mentions ? item->mentions[n].url : NULL;
    }
    if (!destination || !*destination) return hit;
    for (gsize i = 0; i < item->n_mentions; i++) {
        const SZFriendsGtkMention *mention = &item->mentions[i];
        if (!mention->url || strcmp(mention->url, destination) != 0) continue;
        /* The reader's own mention, or a kind this build does not know, does nothing. */
        if (mention->kind == SZFRIENDS_GTK_MENTION_FRIEND && mention->conversation_id && *mention->conversation_id)
            hit = (SZFriendsGtkHit){SZFRIENDS_GTK_HIT_FRIEND, NULL, mention};
        else if (mention->kind == SZFRIENDS_GTK_MENTION_STRANGER && mention->card)
            hit = (SZFriendsGtkHit){SZFRIENDS_GTK_HIT_CARD, NULL, mention};
        return hit;
    }
    if (!szfriends_gtk_link_may_open(destination)) return hit;
    char *scheme = scheme_of(destination);
    hit.kind = strcmp(scheme, "mailto") == 0 ? SZFRIENDS_GTK_HIT_EMAIL : SZFRIENDS_GTK_HIT_WEB;
    hit.url = destination;
    g_free(scheme);
    return hit;
}

/* ---- Where the words say the link goes ------------------------------------------------------------- */

static gboolean is_edge(gunichar c) {
    return g_unichar_isspace(c) || (c && strchr("<>()[]\"'.,;:!?", (int)c) && c < 0x80) || c == 0x201C ||
           c == 0x201D || c == 0x2018 || c == 0x2019;
}

/* A bare name reads as a site only with a common web ending: "apple.com" does, "report.pdf" does not, and a warning
 * on file names people link to their files would teach people to ignore the warning. */
static gboolean looks_like_site(const char *host, gboolean bare) {
    if (!host || strlen(host) > 253) return FALSE;
    char **labels = g_strsplit(host, ".", -1);
    guint count = g_strv_length(labels);
    gboolean ok = count >= 2;
    for (guint i = 0; ok && i < count; i++) {
        ok = labels[i][0] != '\0';
        for (const char *p = labels[i]; ok && *p; p = g_utf8_next_char(p)) {
            gunichar c = g_utf8_get_char(p);
            ok = g_unichar_isalnum(c) || c == '-';
        }
    }
    static const char *const endings[] = {"com", "net", "org", "io", "co", "app", "dev", "ai", "gov", "edu", "info",
                                          "biz", "me", "xyz", "online", "site", "shop", "cn", "hk", "tw", "jp", "sg",
                                          "uk", "de", "fr", "us", NULL};
    if (ok) {
        char *ending = g_utf8_strdown(labels[count - 1], -1);
        ok = !bare ? g_utf8_strlen(ending, -1) >= 2
                   : g_strv_contains(endings, ending) || g_str_has_prefix(ending, "xn--");
        g_free(ending);
    }
    g_strfreev(labels);
    return ok;
}

/* What a link's words present as where it goes: a host ("www.apple.com" from "https://www.apple.com/account", or
 * "apple.com"), or an email address (*mail TRUE); NULL for ordinary words ("the plan"). */
static char *shown_address(const char *text, gboolean *mail) {
    *mail = FALSE;
    const char *start = text, *end = text + strlen(text);
    while (start < end && is_edge(g_utf8_get_char(start))) start = g_utf8_next_char(start);
    while (end > start && is_edge(g_utf8_get_char(g_utf8_prev_char(end)))) end = g_utf8_prev_char(end);
    if (start == end || g_utf8_strlen(start, end - start) > 2048) return NULL;
    for (const char *p = start; p < end; p = g_utf8_next_char(p))
        if (g_unichar_isspace(g_utf8_get_char(p))) return NULL;
    char *words = g_strndup(start, (gsize)(end - start)), *result = NULL;
    const char *rest = words;
    gboolean addressed = FALSE; /* the words name a scheme or start with www., so they are meant as an address */
    if (g_ascii_strncasecmp(rest, "mailto:", 7) == 0) rest += 7, addressed = TRUE;
    const char *scheme = strstr(rest, "://");
    if (scheme) {
        GUri *uri = g_uri_parse(rest, G_URI_FLAGS_PARSE_RELAXED, NULL);
        const char *host = uri ? g_uri_get_host(uri) : NULL;
        if (host && *host) result = g_utf8_strdown(host, -1);
        if (uri) g_uri_unref(uri);
        if (result) goto done;
        rest = scheme + 3, addressed = TRUE;
    }
    char *head = g_strndup(rest, strcspn(rest, "/?#"));
    char *at = strrchr(head, '@');
    if (at && at > head) {
        if (looks_like_site(at + 1, FALSE)) *mail = TRUE, result = g_utf8_strdown(head, -1);
        g_free(head);
        goto done;
    }
    char *port = strchr(head, ':');
    if (port) *port = '\0';
    addressed = addressed || g_ascii_strncasecmp(head, "www.", 4) == 0;
    if (looks_like_site(head, !addressed)) result = g_utf8_strdown(head, -1);
    g_free(head);
done:
    g_free(words);
    return result;
}

/* A host as compared: one spelling for internationalized names, lowercase, without a final dot or a leading
 * "www.", which nobody reads as a different site. */
static char *host_key(const char *host) {
    if (!host || !*host) return NULL;
    char *ascii = g_hostname_to_ascii(host);
    char *key = g_ascii_strdown(ascii ? ascii : host, -1);
    g_free(ascii);
    gsize length = strlen(key);
    while (length && key[length - 1] == '.') key[--length] = '\0';
    if (g_str_has_prefix(key, "www.")) memmove(key, key + 4, strlen(key + 4) + 1);
    if (*key) return key;
    g_free(key);
    return NULL;
}

/* TRUE when `destination` is the shown site or a part of it (support.apple.com for apple.com): only the owner of a
 * domain controls its subdomains, while apple.com.example.net belongs to example.net. */
static gboolean same_site(const char *destination, const char *shown) {
    char *to = host_key(destination), *from = host_key(shown);
    gboolean same = FALSE;
    if (to && from) {
        char *dotted = g_strconcat(".", from, NULL);
        same = strcmp(to, from) == 0 || g_str_has_suffix(to, dotted);
        g_free(dotted);
    }
    g_free(to);
    g_free(from);
    return same;
}

/* The address a mailto: link writes to, without its ?subject=... part. */
static char *mail_address(const char *url) {
    char *rest = g_strndup(url + 7, strcspn(url + 7, "?"));
    char *decoded = g_uri_unescape_string(rest, NULL);
    char *address = g_utf8_strdown(decoded ? decoded : rest, -1);
    g_free(decoded);
    g_free(rest);
    return address;
}

static char *url_host(const char *url) {
    GUri *uri = g_uri_parse(url, G_URI_FLAGS_PARSE_RELAXED, NULL);
    char *host = uri && g_uri_get_host(uri) ? g_utf8_strdown(g_uri_get_host(uri), -1) : g_strdup("");
    if (uri) g_uri_unref(uri);
    return host;
}

static gboolean is_mailto(const char *url) {
    return url && g_ascii_strncasecmp(url, "mailto:", 7) == 0;
}

char *szfriends_gtk_link_shown_elsewhere(const char *words, const char *url) {
    gboolean shown_mail = FALSE;
    char *shown = url ? shown_address(words ? words : "", &shown_mail) : NULL;
    if (!shown) return NULL;
    const char *site = shown_mail ? strrchr(shown, '@') + 1 : shown;
    gboolean same;
    if (is_mailto(url)) {
        char *address = mail_address(url);
        const char *at = strrchr(address, '@');
        same = shown_mail ? strcmp(address, shown) == 0 : same_site(at ? at + 1 : "", site);
        g_free(address);
    } else {
        char *host = url_host(url);
        same = same_site(host, site);
        g_free(host);
    }
    if (!same) return shown;
    g_free(shown);
    return NULL;
}

char *szfriends_gtk_link_address_title(const char *url) {
    if (!url) return g_strdup("");
    glong length = g_utf8_strlen(url, -1);
    if (length <= SZFRIENDS_GTK_LINK_TITLE_LENGTH) return g_strdup(url);
    /* The host and port end where the path, query or fragment starts after "scheme://". */
    const char *authority = strstr(url, "://");
    authority = authority ? authority + 3 : url;
    glong host_end = g_utf8_pointer_to_offset(url, authority + strcspn(authority, "/?#"));
    glong keep = MIN(length, MAX(host_end, SZFRIENDS_GTK_LINK_TITLE_LENGTH - 1));
    char *kept = g_utf8_substring(url, 0, keep);
    char *title = g_strconcat(kept, "…", NULL);
    g_free(kept);
    return title;
}

char *szfriends_gtk_fill(const char *format, const char *const *keys, const char *const *values, gsize count) {
    GString *text = g_string_new(NULL);
    for (const char *p = format ? format : ""; *p;) {
        gboolean replaced = FALSE;
        for (gsize i = 0; *p == '{' && i < count && !replaced; i++) {
            gsize length = strlen(keys[i]);
            if (strncmp(p + 1, keys[i], length) == 0 && p[1 + length] == '}') {
                g_string_append(text, values[i] ? values[i] : "");
                p += length + 2;
                replaced = TRUE;
            }
        }
        if (!replaced) g_string_append_c(text, *p++);
    }
    return g_string_free(text, FALSE);
}

SZFriendsGtkLinkMenuText *szfriends_gtk_link_menu_text(const char *url, const char *words, const char *elsewhere,
                                                       const char *open_web, const char *open_email) {
    SZFriendsGtkLinkMenuText *text = g_new0(SZFriendsGtkLinkMenuText, 1);
    text->email = is_mailto(url);
    char *shown = szfriends_gtk_link_shown_elsewhere(words, url);
    if (shown && elsewhere && *elsewhere) {
        char *destination = text->email ? mail_address(url) : url_host(url);
        const char *keys[] = {"host", "shown"}, *values[] = {destination, shown};
        text->warning = szfriends_gtk_fill(elsewhere, keys, values, 2);
        g_free(destination);
    }
    g_free(shown);
    text->address = szfriends_gtk_link_address_title(url);
    const char *open = text->email ? open_email : open_web;
    text->open_label = g_strdup(open ? open : "");
    return text;
}

void szfriends_gtk_link_menu_text_free(SZFriendsGtkLinkMenuText *text) {
    if (!text) return;
    g_free(text->warning);
    g_free(text->address);
    g_free(text->open_label);
    g_free(text);
}

/* ---- Long plain messages, and which actions an item shows ----------------------------------------- */

/* A cut never splits what draws as one character: a mark, a joiner or a selector stays with what precedes it. */
static gboolean continues_cluster(gunichar c) {
    return g_unichar_ismark(c) || c == 0x200D || (c >= 0xFE00 && c <= 0xFE0F) || (c >= 0x1F3FB && c <= 0x1F3FF) ||
           (c >= 0xE0020 && c <= 0xE007F);
}

gssize szfriends_gtk_plain_cut(const char *text) {
    /* WHY: laying text out costs about as much as it is long, so a 32 KB message lays out only its start until the
     * person asks for the rest, and a history of them still opens at once. */
    if (!text || g_utf8_strlen(text, -1) <= SZFRIENDS_GTK_PLAIN_SHOWN) return -1;
    const char *limit = g_utf8_offset_to_pointer(text, SZFRIENDS_GTK_PLAIN_SHOWN);
    const char *look = g_utf8_offset_to_pointer(text, SZFRIENDS_GTK_PLAIN_SHOWN - SZFRIENDS_GTK_PLAIN_LOOK_BACK);
    const char *cut = NULL;
    for (const char *p = look; p < limit; p = g_utf8_next_char(p))
        if (g_unichar_isspace(g_utf8_get_char(p))) cut = p;
    if (!cut) {
        cut = limit;
        while (cut > text && (continues_cluster(g_utf8_get_char(cut)) ||
                              g_utf8_get_char(g_utf8_prev_char(cut)) == 0x200D))
            cut = g_utf8_prev_char(cut);
    }
    gboolean more = FALSE; /* nothing but spaces after the cut: Show all would show nothing more */
    for (const char *p = cut; *p && !more; p = g_utf8_next_char(p)) more = !g_unichar_isspace(g_utf8_get_char(p));
    if (!more) return -1;
    while (cut > text && g_unichar_isspace(g_utf8_get_char(g_utf8_prev_char(cut)))) cut = g_utf8_prev_char(cut);
    return cut - text;
}

gboolean szfriends_gtk_item_shows_action(const SZFriendsGtkAction *action, gboolean helper_cancels_messages) {
    if (!action || !szfriends_gtk_action_is_known(action->action)) return FALSE;
    /* Conversation actions never ask first in this protocol; one that would is left to the views that can ask. */
    if (action->confirm) return FALSE;
    /* Cancel withdraws a message only on a helper announcing messages.cancel; any other answers unknown_intent. */
    return action->action != SZFRIENDS_GTK_ACTION_CANCEL_MESSAGE || helper_cancels_messages;
}
