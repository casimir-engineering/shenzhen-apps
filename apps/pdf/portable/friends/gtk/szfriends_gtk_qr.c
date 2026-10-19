/* A QR code encoder and the widget that draws one (szfriends_gtk_qr.h). The encoder follows ISO/IEC 18004 as
 * Project Nayuki's reference implementation lays it out: data bits, Reed-Solomon blocks interleaved, function
 * patterns, the zigzag placement, then the mask with the lowest penalty. */

#include "gtk/szfriends_gtk_qr.h"

#include <stdlib.h>
#include <string.h>

/* ---- The symbol ----------------------------------------------------------------------------------------- */

/* Correction level M, versions 1 to 10 (ISO/IEC 18004 table 9): codewords in all, correction codewords per block,
 * and the two groups of blocks with their data codewords. */
typedef struct {
    int ec, blocks1, data1, blocks2, data2;
} SZFriendsGtkQRVersion;
static const SZFriendsGtkQRVersion versions[11] = {
    {0, 0, 0, 0, 0},     {10, 1, 16, 0, 0},   {16, 1, 28, 0, 0},   {26, 1, 44, 0, 0},
    {18, 2, 32, 0, 0},   {24, 2, 43, 0, 0},   {16, 4, 27, 0, 0},   {18, 4, 31, 0, 0},
    {22, 2, 38, 2, 39},  {22, 3, 36, 2, 37},  {26, 4, 43, 1, 44},
};

typedef struct {
    int version, size;
    guint8 *dark, *function;
} SZFriendsGtkQR;

static void set_function(SZFriendsGtkQR *qr, int x, int y, gboolean dark) {
    qr->dark[y * qr->size + x] = (guint8)dark;
    qr->function[y * qr->size + x] = 1;
}

static int data_codewords(int version) {
    const SZFriendsGtkQRVersion *v = &versions[version];
    return v->blocks1 * v->data1 + v->blocks2 * v->data2;
}

static guint8 gf_multiply(guint8 x, guint8 y) {
    int z = 0;
    for (int i = 7; i >= 0; i--) {
        z = (z << 1) ^ ((z >> 7) * 0x11D);
        z ^= ((y >> i) & 1) * x;
    }
    return (guint8)z;
}

/* The generator polynomial of `degree` (highest coefficient dropped), then the remainder of `data` by it. */
static void reed_solomon(const guint8 *data, int length, int degree, guint8 *remainder) {
    guint8 divisor[32] = {0}, root = 1;
    divisor[degree - 1] = 1;
    for (int i = 0; i < degree; i++) {
        for (int j = 0; j < degree; j++) {
            divisor[j] = gf_multiply(divisor[j], root);
            if (j + 1 < degree) divisor[j] ^= divisor[j + 1];
        }
        root = gf_multiply(root, 0x02);
    }
    memset(remainder, 0, (size_t)degree);
    for (int i = 0; i < length; i++) {
        guint8 factor = data[i] ^ remainder[0];
        memmove(remainder, remainder + 1, (size_t)degree - 1);
        remainder[degree - 1] = 0;
        for (int j = 0; j < degree; j++) remainder[j] ^= gf_multiply(divisor[j], factor);
    }
}

static void append_bits(guint8 *bytes, int *bit, guint32 value, int count) {
    for (int i = count - 1; i >= 0; i--, (*bit)++)
        if ((value >> i) & 1) bytes[*bit >> 3] |= (guint8)(0x80 >> (*bit & 7));
}

/* Byte mode, count, the bytes, the terminator, then the pad codewords 0xEC 0x11 the standard prescribes; split
 * into blocks, each followed by its correction codewords, and interleaved. */
static guint8 *codewords(const guint8 *payload, int length, int version, int *count) {
    const SZFriendsGtkQRVersion *v = &versions[version];
    int capacity = data_codewords(version), bit = 0;
    guint8 *data = g_malloc0((size_t)capacity);
    append_bits(data, &bit, 0x4, 4);
    append_bits(data, &bit, (guint32)length, version <= 9 ? 8 : 16);
    for (int i = 0; i < length; i++) append_bits(data, &bit, payload[i], 8);
    append_bits(data, &bit, 0, MIN(4, capacity * 8 - bit));
    bit = (bit + 7) / 8 * 8;
    for (guint8 pad = 0xEC; bit < capacity * 8; pad ^= 0xEC ^ 0x11) append_bits(data, &bit, pad, 8);
    int blocks = v->blocks1 + v->blocks2;
    *count = capacity + blocks * v->ec;
    guint8 *out = g_malloc0((size_t)*count), ec[32];
    int written = 0;
    for (int i = 0; i < MAX(v->data1, v->data2); i++)
        for (int b = 0, start = 0; b < blocks; start += b < v->blocks1 ? v->data1 : v->data2, b++)
            if (i < (b < v->blocks1 ? v->data1 : v->data2)) out[written++] = data[start + i];
    for (int b = 0, start = 0; b < blocks; start += b < v->blocks1 ? v->data1 : v->data2, b++) {
        reed_solomon(data + start, b < v->blocks1 ? v->data1 : v->data2, v->ec, ec);
        for (int i = 0; i < v->ec; i++) out[capacity + i * blocks + b] = ec[i];
    }
    g_free(data);
    return out;
}

static void draw_format(SZFriendsGtkQR *qr, int mask) {
    int data = mask, remainder = data; /* level M's two bits are 00 */
    for (int i = 0; i < 10; i++) remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537);
    int bits = (data << 10 | remainder) ^ 0x5412, size = qr->size;
    for (int i = 0; i <= 5; i++) set_function(qr, 8, i, (bits >> i) & 1);
    set_function(qr, 8, 7, (bits >> 6) & 1);
    set_function(qr, 8, 8, (bits >> 7) & 1);
    set_function(qr, 7, 8, (bits >> 8) & 1);
    for (int i = 9; i < 15; i++) set_function(qr, 14 - i, 8, (bits >> i) & 1);
    for (int i = 0; i < 8; i++) set_function(qr, size - 1 - i, 8, (bits >> i) & 1);
    for (int i = 8; i < 15; i++) set_function(qr, 8, size - 15 + i, (bits >> i) & 1);
    set_function(qr, 8, size - 8, TRUE);
}

static void draw_function_patterns(SZFriendsGtkQR *qr) {
    int size = qr->size;
    for (int i = 0; i < size; i++) {
        set_function(qr, 6, i, i % 2 == 0);
        set_function(qr, i, 6, i % 2 == 0);
    }
    const int finders[3][2] = {{3, 3}, {size - 4, 3}, {3, size - 4}};
    for (int f = 0; f < 3; f++)
        for (int dy = -4; dy <= 4; dy++)
            for (int dx = -4; dx <= 4; dx++) {
                int x = finders[f][0] + dx, y = finders[f][1] + dy, distance = MAX(abs(dx), abs(dy));
                if (x >= 0 && x < size && y >= 0 && y < size) set_function(qr, x, y, distance != 2 && distance != 4);
            }
    int count = qr->version == 1 ? 0 : qr->version / 7 + 2, positions[7];
    if (count) {
        int step = (qr->version * 4 + count * 2 + 1) / (count * 2 - 2) * 2;
        positions[0] = 6;
        for (int i = count - 1, position = size - 7; i >= 1; i--, position -= step) positions[i] = position;
    }
    for (int i = 0; i < count; i++)
        for (int j = 0; j < count; j++) {
            if ((i == 0 && j == 0) || (i == 0 && j == count - 1) || (i == count - 1 && j == 0)) continue;
            for (int dy = -2; dy <= 2; dy++)
                for (int dx = -2; dx <= 2; dx++)
                    set_function(qr, positions[i] + dx, positions[j] + dy, MAX(abs(dx), abs(dy)) != 1);
        }
    draw_format(qr, 0); /* reserved now, written with the chosen mask later */
    if (qr->version < 7) return;
    int remainder = qr->version;
    for (int i = 0; i < 12; i++) remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25);
    long bits = (long)qr->version << 12 | remainder;
    for (int i = 0; i < 18; i++) {
        int a = size - 11 + i % 3, b = i / 3;
        set_function(qr, a, b, (bits >> i) & 1);
        set_function(qr, b, a, (bits >> i) & 1);
    }
}

static void place(SZFriendsGtkQR *qr, const guint8 *data, int count) {
    int bit = 0, size = qr->size;
    for (int right = size - 1; right >= 1; right -= 2) {
        if (right == 6) right = 5; /* the vertical timing pattern */
        for (int vertical = 0; vertical < size; vertical++)
            for (int j = 0; j < 2; j++) {
                int x = right - j, y = ((right + 1) & 2) == 0 ? size - 1 - vertical : vertical;
                if (qr->function[y * size + x] || bit >= count * 8) continue;
                qr->dark[y * size + x] = (data[bit >> 3] >> (7 - (bit & 7))) & 1;
                bit++;
            }
    }
}

static void apply_mask(SZFriendsGtkQR *qr, int mask) {
    for (int y = 0; y < qr->size; y++)
        for (int x = 0; x < qr->size; x++) {
            int flip;
            switch (mask) {
            case 0: flip = (x + y) % 2 == 0; break;
            case 1: flip = y % 2 == 0; break;
            case 2: flip = x % 3 == 0; break;
            case 3: flip = (x + y) % 3 == 0; break;
            case 4: flip = (x / 3 + y / 2) % 2 == 0; break;
            case 5: flip = x * y % 2 + x * y % 3 == 0; break;
            case 6: flip = (x * y % 2 + x * y % 3) % 2 == 0; break;
            default: flip = ((x + y) % 2 + x * y % 3) % 2 == 0; break;
            }
            if (!qr->function[y * qr->size + x]) qr->dark[y * qr->size + x] ^= (guint8)flip;
        }
}

/* ---- The penalty rules ------------------------------------------------------------------------------------ */

static void add_run(int length, int history[7], int size) {
    if (history[0] == 0) length += size; /* the light border before the first run */
    memmove(history + 1, history, 6 * sizeof history[0]);
    history[0] = length;
}

static int finder_like(const int history[7], int size) {
    int n = history[1];
    (void)size;
    gboolean core = n > 0 && history[2] == n && history[3] == n * 3 && history[4] == n && history[5] == n;
    return (core && history[0] >= n * 4 && history[6] >= n) + (core && history[6] >= n * 4 && history[0] >= n);
}

static long line_penalty(const SZFriendsGtkQR *qr, gboolean columns) {
    long result = 0;
    int size = qr->size;
    for (int a = 0; a < size; a++) {
        int dark = 0, run = 0, history[7] = {0};
        for (int b = 0; b < size; b++) {
            int module = columns ? qr->dark[b * size + a] : qr->dark[a * size + b];
            if (module == dark) {
                run++;
                if (run == 5) result += 3;
                else if (run > 5) result++;
            } else {
                add_run(run, history, size);
                if (!dark) result += finder_like(history, size) * 40;
                dark = module;
                run = 1;
            }
        }
        if (dark) {
            add_run(run, history, size);
            run = 0;
        }
        add_run(run + size, history, size); /* the light border after the last run */
        result += finder_like(history, size) * 40;
    }
    return result;
}

static long penalty(const SZFriendsGtkQR *qr) {
    int size = qr->size;
    long result = line_penalty(qr, FALSE) + line_penalty(qr, TRUE), dark = 0, total = (long)size * size;
    for (int y = 0; y < size; y++)
        for (int x = 0; x < size; x++) {
            int module = qr->dark[y * size + x];
            dark += module;
            if (x + 1 < size && y + 1 < size && module == qr->dark[y * size + x + 1] &&
                module == qr->dark[(y + 1) * size + x] && module == qr->dark[(y + 1) * size + x + 1])
                result += 3;
        }
    long k = (labs(dark * 20 - total * 10) + total - 1) / total - 1;
    return result + k * 10;
}

guint8 *szfriends_gtk_qr_encode(const char *payload, int mask, int *size) {
    int length = payload ? (int)strlen(payload) : 0, version = 1;
    while (version <= 10 && 4 + (version <= 9 ? 8 : 16) + 8 * length > data_codewords(version) * 8) version++;
    if (!payload || version > 10 || mask > 7) return NULL;
    SZFriendsGtkQR qr = {version, 17 + 4 * version, NULL, NULL};
    qr.dark = g_malloc0((size_t)qr.size * qr.size);
    qr.function = g_malloc0((size_t)qr.size * qr.size);
    draw_function_patterns(&qr);
    int count = 0;
    guint8 *data = codewords((const guint8 *)payload, length, version, &count);
    place(&qr, data, count);
    g_free(data);
    if (mask < 0) {
        long best = -1;
        for (int candidate = 0; candidate < 8; candidate++) {
            apply_mask(&qr, candidate);
            draw_format(&qr, candidate);
            long score = penalty(&qr);
            if (best < 0 || score < best) {
                best = score;
                mask = candidate;
            }
            apply_mask(&qr, candidate); /* XOR again: back to unmasked */
        }
    }
    apply_mask(&qr, mask);
    draw_format(&qr, mask);
    g_free(qr.function);
    *size = qr.size;
    return qr.dark;
}

/* ---- The widget ------------------------------------------------------------------------------------------ */

typedef struct {
    guint8 *modules;
    int size;
} SZFriendsGtkQRView;

static void view_free(gpointer data) {
    SZFriendsGtkQRView *view = data;
    g_free(view->modules);
    g_free(view);
}

static void draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)area;
    SZFriendsGtkQRView *view = data;
    double side = MIN(width, height), inset = 6, radius = 6;
    /* Dark on white in both appearances: scanners need the contrast, not the theme. */
    cairo_new_sub_path(cr);
    cairo_arc(cr, side - radius, radius, radius, -G_PI / 2, 0);
    cairo_arc(cr, side - radius, side - radius, radius, 0, G_PI / 2);
    cairo_arc(cr, radius, side - radius, radius, G_PI / 2, G_PI);
    cairo_arc(cr, radius, radius, radius, G_PI, 3 * G_PI / 2);
    cairo_close_path(cr);
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_fill(cr);
    if (!view->modules || view->size <= 0) return;
    /* Hard edges at any size: antialiased modules blur into grey seams a camera misreads. */
    cairo_set_antialias(cr, CAIRO_ANTIALIAS_NONE);
    cairo_set_source_rgb(cr, 0, 0, 0);
    double module = (side - 2 * inset) / view->size;
    for (int y = 0; y < view->size; y++)
        for (int x = 0; x < view->size; x++)
            if (view->modules[y * view->size + x])
                cairo_rectangle(cr, inset + x * module, inset + y * module, module, module);
    cairo_fill(cr);
}

GtkWidget *szfriends_gtk_qr_new(void) {
    GtkWidget *area = gtk_drawing_area_new();
    SZFriendsGtkQRView *view = g_new0(SZFriendsGtkQRView, 1);
    g_object_set_data_full(G_OBJECT(area), "szfriends-qr", view, view_free);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), draw, view, NULL);
    szfriends_gtk_qr_set_large(area, FALSE);
    return area;
}

gboolean szfriends_gtk_qr_set_payload(GtkWidget *area, const char *payload) {
    SZFriendsGtkQRView *view = g_object_get_data(G_OBJECT(area), "szfriends-qr");
    g_free(view->modules);
    view->modules = szfriends_gtk_qr_encode(payload, -1, &view->size);
    gtk_widget_queue_draw(area);
    return view->modules != NULL;
}

void szfriends_gtk_qr_set_slots(GtkWidget *area, GtkWidget *beside, GtkWidget *below) {
    g_object_set_data(G_OBJECT(area), "szfriends-qr-beside", beside);
    g_object_set_data(G_OBJECT(area), "szfriends-qr-below", below);
    gtk_box_append(GTK_BOX(beside), area);
}

void szfriends_gtk_qr_set_large(GtkWidget *area, gboolean large) {
    gtk_widget_set_size_request(area, large ? 200 : 92, large ? 200 : 92);
    gtk_widget_set_halign(area, large ? GTK_ALIGN_CENTER : GTK_ALIGN_END);
    GtkWidget *slot = g_object_get_data(G_OBJECT(area), large ? "szfriends-qr-below" : "szfriends-qr-beside");
    GtkWidget *parent = gtk_widget_get_parent(area);
    if (!slot || parent == slot) return;
    g_object_ref(area);
    gtk_box_remove(GTK_BOX(parent), area);
    gtk_box_append(GTK_BOX(slot), area);
    g_object_unref(area);
}
