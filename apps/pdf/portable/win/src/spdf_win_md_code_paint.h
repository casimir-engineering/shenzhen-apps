/* spdf_win_md_code_paint.h -- drawing the code box's two pills.
 *
 * A REAL TRANSLATION UNIT, not a header included at the end of
 * spdf_win_d2d.cpp beside spdf_win_d2d_overlay.h, for one reason: the app build
 * discovers portable\win\src\*.cpp (build-native.cmd:96), so this file is
 * compiled by `app.build` whether or not the one-line call site has landed. A
 * drawing routine that only compiles once someone applies a patch is a drawing
 * routine that quietly stops compiling.
 *
 * IT DRAWS IN THE CANVAS PHASE, inside the canvas clip and under the canvas
 * translation, so its coordinates are CANVAS-LOCAL device pixels -- which is
 * exactly what spdf_win_md_code_pills() returns, and why nothing here can spill
 * onto the toolbar.
 *
 * THE COLOURS ARE THE MAC'S, and unlike the search and selection marks they ARE
 * theme colours: a pill is a surface, and the mac takes it from
 * SPDFMarkdownTheme rather than hard-coding it. Both renditions are here
 * because the page underneath is either the light or the Obsidian-dark
 * rendition and the pill has to sit on it.
 *
 * A FAILED BRUSH OR FONT IS A SKIPPED PILL, never a failed frame -- the rule
 * spdf_win_chrome_paint.h states for every chrome element.
 *
 * NOTHING HERE REACHES PRINT OR EXPORT, by construction rather than by a check:
 * print, Save as PDF and Copy Page render through spdf_export_pdf and the
 * flagless render path, and neither builds a scene. That is the whole mechanism
 * by which the mac's "no control chrome is baked into the exported page" holds
 * here too.
 */
#ifndef SPDF_WIN_MD_CODE_PAINT_H
#define SPDF_WIN_MD_CODE_PAINT_H

#include <d2d1.h>

struct spdf_win_scene;

/* Draw the pills the last spdf_win_md_code_publish_geometry() produced. A no-op
 * when there are none, which is every non-Markdown document and every Markdown
 * document with no fences on the drawn pages. */
void spdf_win_md_code_paint(ID2D1RenderTarget* target, const struct spdf_win_scene* scene);

/* Release the cached text format and DirectWrite factory. Optional: they are
 * process-lifetime objects and Windows reclaims them at exit. Wire it beside
 * spdf_win_chrome_content_shutdown() if a leak checker ever needs a clean run. */
void spdf_win_md_code_paint_shutdown(void);

#endif /* SPDF_WIN_MD_CODE_PAINT_H */
