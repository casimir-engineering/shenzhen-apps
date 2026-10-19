/* friends-gtk-conversation-check, display-free: what a click on a message's words does (every mention kind, links,
 * destinations Friends never opens), the intents a card and the composer send (mention chips as U+FFFC with their
 * friends in order), the link menu's words, long messages cut, which actions an item shows, previews (only a small
 * PNG in the helper's own cache is ever decoded, anything else falls back to the type's icon, and the box is at most
 * 64 points), and a stranger card's name shown literally.
 *
 * Usage: SZFriendsGtkConversationTests <fixtures dir> */

#include "szfriends_gtk_support.h"
#include "gtk/szfriends_gtk_conversation.h"

#include <glib/gstdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static SZFriendsGtkConversationSnapshot *conversation_fixture(const char *name) {
    char *relative = g_strdup_printf("snapshots/%s", name);
    JsonObject *frame = szfg_fixture(relative);
    g_free(relative);
    if (!frame) return NULL;
    SZFriendsGtkConversationSnapshot *snapshot =
        szfriends_gtk_conversation_snapshot_parse(json_object_get_object_member(frame, "data"));
    json_object_unref(frame);
    return snapshot;
}

static const SZFriendsGtkConversationItem *find_item(const SZFriendsGtkConversationSnapshot *snapshot,
                                                     const char *item_id) {
    for (gsize i = 0; snapshot && i < snapshot->n_items; i++)
        if (strcmp(snapshot->items[i].item_id, item_id) == 0) return &snapshot->items[i];
    return NULL;
}

/* An intent's fields as JSON, for comparing with fixtures/intents.jsonl. */
static JsonObject *intent_fields(szfriends_intent *intent) {
    char *json = intent ? szfriends_intent_fields_json(intent) : NULL;
    JsonObject *fields = json ? szfriends_gtk_json_object_from_text(json, -1) : NULL;
    szfriends_free(json);
    return fields;
}

static JsonObject *fixture_intent(const char *id) {
    char *path = szfg_fixture_path("intents.jsonl"), *text = NULL;
    JsonObject *found = NULL;
    if (g_file_get_contents(path, &text, NULL, NULL)) {
        char **lines = g_strsplit(text, "\n", -1);
        for (char **line = lines; *line && !found; line++) {
            JsonObject *frame = **line ? szfriends_gtk_json_object_from_text(*line, -1) : NULL;
            if (frame && g_strcmp0(json_object_get_string_member_with_default(frame, "id", ""), id) == 0) found = frame;
            else if (frame) json_object_unref(frame);
        }
        g_strfreev(lines);
    }
    g_free(text);
    g_free(path);
    return found;
}

/* ---- Clicks on a message's words ---------------------------------------------------------------------------- */

static void test_mention_routing(void) {
    SZFriendsGtkConversationSnapshot *daniel = conversation_fixture("conversation-daniel-mentions.json");
    const SZFriendsGtkConversationItem *mei = find_item(daniel, "m_d0a1"), *leo = find_item(daniel, "m_d0a2");
    const SZFriendsGtkConversationItem *lena = find_item(daniel, "m_d0a3"), *kenji = find_item(daniel, "m_d0a4");
    const SZFriendsGtkConversationItem *priya = find_item(daniel, "m_d0a5");
    EXPECT(mei && leo && lena && kenji && priya, "the mentions fixture has its five messages");
    if (!mei || !leo || !lena || !kenji || !priya) goto done;
    SZFriendsGtkHit hit = szfriends_gtk_link_hit(mei, 0);
    EXPECT(hit.kind == SZFRIENDS_GTK_HIT_FRIEND && strcmp(hit.mention->conversation_id, "c_mei") == 0,
           "a friend's mention opens their conversation");
    EXPECT(szfriends_gtk_link_hit(mei, 1).kind == SZFRIENDS_GTK_HIT_NONE, "the words after it do nothing");
    hit = szfriends_gtk_link_hit(leo, 0);
    EXPECT(hit.kind == SZFRIENDS_GTK_HIT_CARD && strcmp(hit.mention->card->title, "Leo Park") == 0,
           "a stranger's mention shows their card");
    EXPECT(szfriends_gtk_link_hit(leo, 2).kind == SZFRIENDS_GTK_HIT_NONE, "the reader's own mention does nothing");
    EXPECT(szfriends_gtk_link_hit(lena, 0).kind == SZFRIENDS_GTK_HIT_CARD &&
               szfriends_gtk_link_hit(lena, 2).kind == SZFRIENDS_GTK_HIT_CARD,
           "a stranger who asked, and one who is blocked, show their cards");
    EXPECT(szfriends_gtk_link_hit(kenji, 0).kind == SZFRIENDS_GTK_HIT_NONE, "@Name as plain text is no link");
    EXPECT(szfriends_gtk_link_hit(priya, 1).kind == SZFRIENDS_GTK_HIT_FRIEND, "an outgoing message's mention too");
    EXPECT(szfriends_gtk_link_hit(priya, 9).kind == SZFRIENDS_GTK_HIT_NONE, "no such segment");

    /* Destinations: compared with mentions[].url, never parsed; only the web and email open otherwise. */
    SZFriendsGtkConversationItem item = *leo;
    SZFriendsGtkSegment segments[] = {
        {0, "a", "https://example.com/plan", FALSE, FALSE, {0, FALSE, 0}},
        {0, "b", "mailto:mei@example.com", FALSE, FALSE, {0, FALSE, 0}},
        {0, "c", "file:///etc/hosts", FALSE, FALSE, {0, FALSE, 0}},
        {0, "d", "javascript:alert(1)", FALSE, FALSE, {0, FALSE, 0}},
        {0, "e", "szfriends:mention?ref=7", FALSE, FALSE, {0, FALSE, 0}},
        {0, "f", "szfriends:add?id=brave-otter", FALSE, FALSE, {0, FALSE, 0}},
        {0, "g", "szfriends:mention?ref=0", FALSE, FALSE, {0, FALSE, 0}},
        {0, "h", NULL, FALSE, FALSE, {0, TRUE, 5}},
        {0, "i", "HTTPS://EXAMPLE.COM/", FALSE, FALSE, {0, FALSE, 0}},
        {0, "j", "https://", FALSE, FALSE, {0, FALSE, 0}},
    };
    item.segments = segments, item.n_segments = G_N_ELEMENTS(segments);
    static const SZFriendsGtkHitKind expected[] = {
        SZFRIENDS_GTK_HIT_WEB, SZFRIENDS_GTK_HIT_EMAIL, SZFRIENDS_GTK_HIT_NONE, SZFRIENDS_GTK_HIT_NONE,
        SZFRIENDS_GTK_HIT_NONE, SZFRIENDS_GTK_HIT_NONE, SZFRIENDS_GTK_HIT_CARD, SZFRIENDS_GTK_HIT_NONE,
        SZFRIENDS_GTK_HIT_WEB, SZFRIENDS_GTK_HIT_NONE};
    for (gsize i = 0; i < G_N_ELEMENTS(segments); i++)
        EXPECT(szfriends_gtk_link_hit(&item, i).kind == expected[i], "segment %s (%s) acts as %d, not %d",
               segments[i].text, segments[i].url ? segments[i].url : "mention 5", expected[i],
               szfriends_gtk_link_hit(&item, i).kind);
done:
    szfriends_gtk_conversation_snapshot_free(daniel);
}

static void expect_fields(szfriends_intent *intent, const char *fixture_id, const char *ignore, const char *what) {
    JsonObject *fields = intent_fields(intent), *frame = fixture_intent(fixture_id);
    EXPECT(fields && frame, "%s: built and in intents.jsonl", what);
    if (fields && frame) {
        EXPECT(g_strcmp0(szfriends_intent_type(intent), json_object_get_string_member(frame, "type")) == 0,
               "%s: the fixture's intent type", what);
        json_object_remove_member(frame, "type");
        json_object_remove_member(frame, "id");
        if (ignore) json_object_remove_member(frame, ignore), json_object_remove_member(fields, ignore);
        JsonNode *a = json_node_init_object(json_node_alloc(), fields), *b = json_node_init_object(json_node_alloc(),
                                                                                                  frame);
        GString *where = g_string_new(NULL);
        EXPECT(szfg_json_equal(a, b, where), "%s: the fixture's fields (%s)", what, where->str);
        g_string_free(where, TRUE);
        json_node_unref(a);
        json_node_unref(b);
    }
    if (fields) json_object_unref(fields);
    if (frame) json_object_unref(frame);
    szfriends_intent_free(intent);
}

static void test_card_and_composer_intents(void) {
    SZFriendsGtkConversationSnapshot *daniel = conversation_fixture("conversation-daniel-mentions.json");
    const SZFriendsGtkConversationItem *leo = find_item(daniel, "m_d0a2"), *lena = find_item(daniel, "m_d0a3");
    if (leo && leo->n_mentions && leo->mentions[0].card && leo->mentions[0].card->n_actions) {
        /* Add sends the action's own three fields, as they are: the view never builds an ID or a key. */
        expect_fields(szfriends_gtk_intent_for_action(&leo->mentions[0].card->actions[0], NULL), "52", NULL,
                      "Add from a mention");
    } else EXPECT(FALSE, "Leo's card carries Add");
    if (lena && lena->n_mentions && lena->mentions[0].card) {
        const SZFriendsGtkMentionCard *card = lena->mentions[0].card;
        SZFriendsGtkActionIds ids = {.conversation_id = card->conversation_id};
        JsonObject *fields = intent_fields(szfriends_gtk_intent_for_action(&card->actions[0], &ids));
        EXPECT(fields && g_strcmp0(json_object_get_string_member(fields, "conversation_id"), "c_lena") == 0,
               "a request's Accept on the card takes the card's conversation_id");
        if (fields) json_object_unref(fields);
    }
    szfriends_gtk_conversation_snapshot_free(daniel);

    /* One U+FFFC per chip and one mentions entry per chip, in order (fixtures/intents.jsonl id 53). */
    SZFriendsGtkComposerPiece pieces[] = {{NULL, "c_mei"}, {" has the bracket drawing. Ask her for rev B.", NULL}};
    expect_fields(szfriends_gtk_composer_intent("c_daniel", pieces, 2, NULL, "6c5d4e3f2a1b0c9d8e7f6a5b"), "53", NULL,
                  "a message with a mention chip");
    SZFriendsGtkComposerPiece pasted[] = {{"a\xEF\xBF\xBC" "b", NULL}};
    JsonObject *fields = intent_fields(szfriends_gtk_composer_intent("c_mei", pasted, 1, NULL, NULL));
    EXPECT(fields && strcmp(json_object_get_string_member(fields, "text"), "ab") == 0 &&
               !json_object_has_member(fields, "mentions"), "a pasted object character is dropped, never a mention");
    if (fields) json_object_unref(fields);
    SZFriendsGtkComposerPiece many[SZFRIENDS_GTK_MAX_MENTIONS + 1];
    for (gsize i = 0; i < G_N_ELEMENTS(many); i++) many[i] = (SZFriendsGtkComposerPiece){NULL, "c_mei"};
    szfriends_intent *limit = szfriends_gtk_composer_intent("c_mei", many, SZFRIENDS_GTK_MAX_MENTIONS, NULL, NULL);
    EXPECT(limit != NULL, "20 mentions go");
    szfriends_intent_free(limit);
    EXPECT(!szfriends_gtk_composer_intent("c_mei", many, G_N_ELEMENTS(many), NULL, NULL), "21 never do");
    SZFriendsGtkComposerPiece empty[] = {{"", NULL}};
    EXPECT(!szfriends_gtk_composer_intent("c_mei", empty, 1, NULL, NULL), "nothing typed or attached sends nothing");
    GPtrArray *items = g_ptr_array_new_with_free_func((GDestroyNotify)szfriends_gtk_host_item_free);
    g_ptr_array_add(items, szfriends_gtk_host_item_new("Plan.pdf", NULL, "PDF", "/tmp/Plan.pdf", NULL));
    fields = intent_fields(szfriends_gtk_composer_intent("c_mei", empty, 1, items, NULL));
    EXPECT(fields && json_object_has_member(fields, "attachments") &&
               strlen(json_object_get_string_member(fields, "client_token")) >= 16,
           "a chip alone sends, with a fresh client_token");
    if (fields) json_object_unref(fields);
    g_ptr_array_unref(items);
}

/* ---- The link menu's words, long messages, actions ------------------------------------------------------ */

static void test_link_words(void) {
    static const char *const elsewhere[][3] = {
        {"https://www.apple.com/account", "https://appleid-verify.example.net/login", "www.apple.com"},
        {"paypal.com", "https://paypal.com.example.net/", "paypal.com"},
        {"apple.com", "https://example.net/", "apple.com"},
        {"support@apple.com", "https://example.net/", "support@apple.com"},
        {"mei@example.com", "mailto:boss@example.net", "mei@example.com"},
    };
    for (gsize i = 0; i < G_N_ELEMENTS(elsewhere); i++) {
        char *found = szfriends_gtk_link_shown_elsewhere(elsewhere[i][0], elsewhere[i][1]);
        EXPECT(g_strcmp0(found, elsewhere[i][2]) == 0, "%s -> %s shows %s, not %s", elsewhere[i][0],
               elsewhere[i][1], elsewhere[i][2], found);
        g_free(found);
    }
    static const char *const same[][2] = {
        {"apple.com", "https://www.apple.com/iphone"}, {"www.apple.com", "https://support.apple.com/"},
        {"<https://example.com/plan>", "https://example.com/plan"}, {"the plan", "https://example.net/"},
        {"report.pdf", "https://files.example.net/report.pdf"}, {"Pages 3-5", "https://example.net/"},
        {"mei@example.com", "mailto:Mei@Example.com?subject=Hi"}, {"2.5", "https://example.net/"},
    };
    for (gsize i = 0; i < G_N_ELEMENTS(same); i++) {
        char *found = szfriends_gtk_link_shown_elsewhere(same[i][0], same[i][1]);
        EXPECT(!found, "%s -> %s is not elsewhere (%s)", same[i][0], same[i][1], found);
        g_free(found);
    }
    const char *host = "www.apple.com.account-verify.secure-login.session-update.billing-center.example.net";
    char *url = g_strdup_printf("https://%s/%s", host, "path/path/path/path/path/path/path/path/path/path/path/"
                                                       "path/path/path/path/path/path/path/path/path/path/path/");
    char *title = szfriends_gtk_link_address_title(url), *prefix = g_strconcat("https://", host, NULL);
    EXPECT(g_str_has_prefix(title, prefix) && g_str_has_suffix(title, "…") && g_utf8_strlen(title, -1) < 100,
           "a long address is cut in its path, never in its host: %s", title);
    g_free(prefix);
    g_free(title);
    g_free(url);
    title = szfriends_gtk_link_address_title("https://example.com/plan");
    EXPECT(strcmp(title, "https://example.com/plan") == 0, "a short address shows whole");
    g_free(title);

    SZFriendsGtkLinkMenuText *menu = szfriends_gtk_link_menu_text(
        "https://appleid-verify.example.net/login", "https://www.apple.com/account", "Goes to {host}, not {shown}",
        "Open in Browser", "New Email");
    EXPECT(g_strcmp0(menu->warning, "Goes to appleid-verify.example.net, not www.apple.com") == 0 &&
               strcmp(menu->address, "https://appleid-verify.example.net/login") == 0 &&
               strcmp(menu->open_label, "Open in Browser") == 0 && !menu->email,
           "the warning first, then where it goes, then Open: %s", menu->warning);
    szfriends_gtk_link_menu_text_free(menu);
    menu = szfriends_gtk_link_menu_text("mailto:{shown}@example.net", "mei@example.com", "Goes to {host}, not {shown}",
                                        "Open in Browser", "New Email");
    EXPECT(g_strcmp0(menu->warning, "Goes to {shown}@example.net, not mei@example.com") == 0 && menu->email &&
               strcmp(menu->open_label, "New Email") == 0,
           "placeholders are filled in one pass, so an address never fills one: %s", menu->warning);
    szfriends_gtk_link_menu_text_free(menu);
    menu = szfriends_gtk_link_menu_text("https://example.com/plan", "the plan", "", "", "");
    EXPECT(!menu->warning && !*menu->open_label, "without the catalog's words: no warning, the address opens it");
    szfriends_gtk_link_menu_text_free(menu);
}

static void test_cut_and_actions(void) {
    EXPECT(szfriends_gtk_plain_cut("Short message.") == -1, "a short message shows whole");
    GString *text = g_string_new(NULL);
    while (g_utf8_strlen(text->str, -1) < 5000) g_string_append(text, "word ");
    gssize cut = szfriends_gtk_plain_cut(text->str);
    EXPECT(cut > 3800 && cut <= 4096 && text->str[cut] == ' ' && text->str[cut - 1] != ' ',
           "a long message is cut where a word ends (%zd)", cut);
    g_string_assign(text, "x"); /* so the 4,096th character is a mark */
    while (g_utf8_strlen(text->str, -1) < 5000) g_string_append(text, "e\xCC\x81"); /* e and a combining acute */
    cut = szfriends_gtk_plain_cut(text->str);
    EXPECT(cut > 0 && (gunichar)g_utf8_get_char(text->str + cut) == 'e', "never between a letter and its mark");
    g_string_truncate(text, 0);
    for (int i = 0; i < 4090; i++) g_string_append_c(text, 'a');
    for (int i = 0; i < 300; i++) g_string_append_c(text, ' ');
    EXPECT(szfriends_gtk_plain_cut(text->str) == -1, "nothing but spaces after the cut: shown whole");
    g_string_free(text, TRUE);

    SZFriendsGtkAction cancel = {.action = SZFRIENDS_GTK_ACTION_CANCEL_MESSAGE, .label = "Cancel",
                                 .style = SZFRIENDS_GTK_STYLE_LINK};
    EXPECT(szfriends_gtk_item_shows_action(&cancel, TRUE) && !szfriends_gtk_item_shows_action(&cancel, FALSE),
           "Cancel on a queued message only from a helper that announces messages.cancel");
    SZFriendsGtkAction retry = cancel, unknown = cancel, asking = cancel;
    retry.action = SZFRIENDS_GTK_ACTION_RETRY_ITEM;
    unknown.action = SZFRIENDS_GTK_ACTION_UNKNOWN;
    SZFriendsGtkConfirm confirm = {0};
    asking.action = SZFRIENDS_GTK_ACTION_RETRY_ITEM, asking.confirm = &confirm;
    EXPECT(szfriends_gtk_item_shows_action(&retry, FALSE), "Try again shows from any helper");
    EXPECT(!szfriends_gtk_item_shows_action(&unknown, TRUE), "an action this build does not know is hidden");
    EXPECT(!szfriends_gtk_item_shows_action(&asking, TRUE), "one that would ask first is left to views that ask");
}

void szfg_run_conversation_preview_tests(void); /* szfriends_gtk_conversation_test_previews.c */
void szfg_run_conversation_literal_tests(void); /* szfriends_gtk_conversation_test_literal.c */

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <fixtures>\n", argv[0]);
        return 2;
    }
    char *fixtures = realpath(argv[1], NULL);
    if (!fixtures) return 2;
    szfg_fixtures = fixtures;
    szfg_watch_logs();
    test_mention_routing();
    test_card_and_composer_intents();
    test_link_words();
    test_cut_and_actions();
    szfg_run_conversation_preview_tests();
    szfg_run_conversation_literal_tests();
    EXPECT(szfg_unexpected_warnings() == 0, "no GLib warnings (%d)", szfg_unexpected_warnings());
    free(fixtures);
    if (szfg_failures) {
        fprintf(stderr, "SZFriendsGtkConversationTests: %d failure(s)\n", szfg_failures);
        return 1;
    }
    printf("SZFriendsGtkConversationTests passed\n");
    return 0;
}
