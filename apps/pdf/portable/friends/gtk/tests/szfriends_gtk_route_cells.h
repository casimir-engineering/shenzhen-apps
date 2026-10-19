/* The route icons' shapes, cell by cell: one table that the AppKit suite (mac/tests/SZFriendsViewsRouteIconTests.m)
 * and the GTK probes (szfriends_gtk_probe_routes.c) both check their own drawing against, so the two toolkits draw the
 * same six icons and a path changed in one fails until the other matches. It lives here because GTK code may not
 * include mac/; it is plain C with no GTK in it.
 *
 * Each icon is drawn black at 48 px for its 12 units (4 px a unit) and split into 12 x 12 cells of 4 x 4 px, top
 * row first: '#' is a cell at least 45% covered, '.' one at most 2% covered, '+' an edge either toolkit may
 * antialias its own way, which no check reads. Regenerate it from the AppKit drawing when a path changes on purpose. */

#ifndef SZFRIENDS_GTK_ROUTE_CELLS_H
#define SZFRIENDS_GTK_ROUTE_CELLS_H

#define SZFRIENDS_ROUTE_CELLS_SIDE 12
#define SZFRIENDS_ROUTE_CELLS_COUNT 6

/* `glyph` is the route method it draws (PROTOCOL.md type.route), or "offline". */
typedef struct {
    const char *glyph;
    const char *rows[SZFRIENDS_ROUTE_CELLS_SIDE];
} SZFriendsRouteCells;

static const SZFriendsRouteCells szfriends_route_cells[SZFRIENDS_ROUTE_CELLS_COUNT] = {
    {"lan",
     {"............",
      ".#+......+#.",
      "+#+......+#+",
      "##+#+..+#+##",
      "#+##.++.##+#",
      "#.#++##++#.#",
      "#.#++##++#.#",
      "#+##.++.##+#",
      "##+#+..+#+##",
      "+#+......+#+",
      ".#+......+#.",
      "............"}},
    {"p2p_wifi",
     {"....+##+....",
      "...######...",
      "..+#+..+#+..",
      ".++++..++++.",
      "+####..####+",
      "+#.+#++#+.#+",
      "+####++####+",
      ".+##+..+##+.",
      "++++++++++++",
      "#####++#####",
      "............",
      "............"}},
    {"bluetooth",
     {"............",
      ".....+#+....",
      ".....###+...",
      "...#+####...",
      "...#####+...",
      "....+##+....",
      "....+##+....",
      "...#####+...",
      "...#+####...",
      ".....###+...",
      ".....+#+....",
      "............"}},
    {"internet",
     {".....++.....",
      "...######...",
      "..###++###..",
      ".##+#..#+##.",
      ".#++#..#++#.",
      "+##########+",
      "+##########+",
      ".#++#..#++#.",
      ".##+#..#+##.",
      "..###++###..",
      "...######...",
      ".....++....."}},
    {"relay",
     {"..++++++++..",
      ".##########.",
      "+#++++++++#+",
      "+#+#+....+#+",
      "+#++++++++#+",
      ".##########.",
      ".##########.",
      "+#++++++++#+",
      "+#+#+....+#+",
      "+#++++++++#+",
      ".##########.",
      "..++++++++.."}},
    {"offline",
     {"............",
      ".....++..+#.",
      "...+######+.",
      "..+#+++###..",
      "..#+..+###..",
      ".+#+.+#++#+.",
      ".+#++#+.+#+.",
      "..###+..+#..",
      "..###+++#+..",
      ".+######+...",
      ".#+..++.....",
      "............"}},
};

#endif /* SZFRIENDS_GTK_ROUTE_CELLS_H */
