/* What a row shows, decided without a display (szfriends_gtk_row.h), so the suite checks the rules against the
 * fixtures and the widget only places what this says (mirrors -[SZFriendsRowView drawContent:reserving:]). */

#include "gtk/szfriends_gtk_row.h"

SZFriendsGtkRowLook szfriends_gtk_row_look_for(const SZFriendsGtkRowFacts *facts, SZFriendsGtkRowDrop drop,
                                               gboolean dimmed, gboolean hovered, const char *refusal) {
    SZFriendsGtkRowLook look = {0};
    /* Waiting for an answer: a bar at the leading edge (with the pill), which no hover state can imitate. */
    look.waiting_bar = facts->waiting && drop == SZFRIENDS_GTK_ROW_DROP_NONE;
    look.unread_dot = facts->list_row && facts->unread;
    look.id_check = facts->id_confirmed;
    look.muted = facts->muted;
    /* A row that cannot take files says why under the pointer while files are on their way ("Lena isn't your
     * friend yet"), at full strength over the faded row: the one thing on it meant to be read. */
    gboolean refusing = facts->list_row && !facts->drop_label && facts->drop_refusal && *facts->drop_refusal &&
                        (drop == SZFRIENDS_GTK_ROW_DROP_REFUSE || (dimmed && hovered));
    if (refusing) {
        look.right = SZFRIENDS_GTK_ROW_RIGHT_PILL;
        look.pill = facts->drop_refusal;
        look.pill_warning = TRUE;
    } else if (drop != SZFRIENDS_GTK_ROW_DROP_NONE && facts->drop_label) {
        /* A folder, a link or a special file over a row that takes files: the helper's words for why nothing
         * would go, unless the list's header already says them. Then the row only takes the refuse style, so the
         * sentence is not read twice and the name and the last message stay whole (UX verification, wave 6c). */
        const char *text = drop == SZFRIENDS_GTK_ROW_DROP_ACCEPT ? facts->drop_label
                           : facts->refusal_above              ? NULL
                                                               : refusal;
        look.right = text && *text ? SZFRIENDS_GTK_ROW_RIGHT_PILL : SZFRIENDS_GTK_ROW_RIGHT_NOTHING;
        look.pill = text && *text ? text : NULL;
        look.pill_warning = drop != SZFRIENDS_GTK_ROW_DROP_ACCEPT;
    } else if (facts->has_accessory) {
        look.right = SZFRIENDS_GTK_ROW_RIGHT_ACCESSORY;
    } else if (facts->has_actions) {
        look.right = SZFRIENDS_GTK_ROW_RIGHT_ACTIONS; /* in place of the time, the waiting pill and the route */
    } else if (facts->list_row) {
        look.right = SZFRIENDS_GTK_ROW_RIGHT_TIME;
        look.waiting_pill = facts->waiting;
        /* Route kind none means nothing to show (a request by ID that never connected): no icon. */
        look.route_icon = !facts->waiting && facts->route_label && facts->route != SZFRIENDS_GTK_ROUTE_NONE &&
                          facts->route != SZFRIENDS_GTK_ROUTE_UNKNOWN;
    } else if (facts->has_status) {
        look.right = SZFRIENDS_GTK_ROW_RIGHT_STATUS;
    }
    return look;
}

SZFriendsGtkRowFacts szfriends_gtk_row_facts(const SZFriendsGtkListRow *row) {
    SZFriendsGtkRowFacts facts = {0};
    facts.list_row = TRUE;
    facts.waiting = row->waiting != NULL;
    facts.unread = row->unread;
    facts.id_confirmed = row->id_confirmed;
    facts.muted = row->style == SZFRIENDS_GTK_ROW_MUTED; /* any other style draws as normal */
    for (gsize i = 0; i < row->n_actions && !facts.has_actions; i++)
        facts.has_actions = szfriends_gtk_row_action_known(&row->actions[i]);
    facts.route = row->route.kind;
    facts.route_method = row->route.method;
    facts.route_label = row->route.label != NULL;
    facts.drop_label = row->drop_label;
    facts.drop_refusal = row->drop_refusal;
    return facts;
}

SZFriendsGtkRowLook szfriends_gtk_row_look(const SZFriendsGtkListRow *row, SZFriendsGtkRowDrop drop, gboolean dimmed,
                                           gboolean hovered, const char *refusal) {
    SZFriendsGtkRowFacts facts = szfriends_gtk_row_facts(row);
    return szfriends_gtk_row_look_for(&facts, drop, dimmed, hovered, refusal);
}
