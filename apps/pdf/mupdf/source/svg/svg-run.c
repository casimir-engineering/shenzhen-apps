// Copyright (C) 2004-2025 Artifex Software, Inc.
//
// This file is part of MuPDF.
//
// MuPDF is free software: you can redistribute it and/or modify it under the
// terms of the GNU Affero General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.
//
// MuPDF is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
// details.
//
// You should have received a copy of the GNU Affero General Public License
// along with MuPDF. If not, see <https://www.gnu.org/licenses/agpl-3.0.en.html>
//
// Alternative licensing terms are available from the licensor.
// For commercial licensing, see <https://www.artifex.com/> or contact
// Artifex Software, Inc., 39 Mesa Street, Suite 108A, San Francisco,
// CA 94129, USA, for further information.

#include "mupdf/fitz.h"
#include "svg-imp.h"

#include <string.h>
#include <math.h>

/* default page size */
#define DEF_WIDTH 612
#define DEF_HEIGHT 792
#define DEF_FONTSIZE 12

#define MAX_USE_DEPTH 100

/* ShenzhenPDF: what matplotlib and hand-written charts need, which upstream
   lacked -- the CSS `font` shorthand and font properties that inherit from
   any ancestor (svg_parse_font_attributes), a family list mapped to the sans,
   serif or mono face (svg_font_class), style declarations matched by exact
   name and ranked above presentation attributes (svg_prop, svg_style_lookup),
   opacity, fill-opacity, stroke-opacity and stroke-dasharray from either,
   dominant-baseline, per-character x/y lists, and clip-path to one shape. */

typedef struct svg_state
{
	fz_matrix transform;
	fz_stroke_state *stroke;
	int use_depth;

	float viewport_w, viewport_h;
	float viewbox_w, viewbox_h, viewbox_size;
	float fontsize;

	float opacity;

	int fill_rule;
	int fill_is_set;
	float fill_color[3];
	float fill_opacity;

	int stroke_is_set;
	float stroke_color[3];
	float stroke_opacity;

	/* Inherited font properties. The family is the CSS family list as
	   written ("'DejaVu Sans', Arial, sans-serif"); svg_load_font picks. */
	char font_family[128];
	int is_bold;
	int is_italic;
	int text_anchor;
	int dominant_baseline;
} svg_state;

static void svg_parse_common(fz_context *ctx, svg_document *doc, fz_xml *node, svg_state *state);
static void svg_run_element(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *root, const svg_state *state);

static int svg_push_use(fz_context *ctx, svg_document *doc, svg_cycle_list *here, fz_xml *symbol)
{
	svg_cycle_list *x = doc->cycle;
	while (x)
	{
		if (x->symbol == symbol)
			return 0;
		x = x->up;
	}
	here->up = doc->cycle;
	here->symbol = symbol;
	doc->cycle = here;
	return 1;
}

static void svg_pop_use(fz_context *ctx, svg_document *doc)
{
	if (doc->cycle)
		doc->cycle = doc->cycle->up;
}

void svg_begin_state(fz_context *ctx, svg_state *child, const svg_state *parent)
{
	memcpy(child, parent, sizeof(svg_state));
	child->stroke = fz_clone_stroke_state(ctx, parent->stroke);
}

void svg_end_state(fz_context *ctx, svg_state *child)
{
	fz_drop_stroke_state(ctx, child->stroke);
}

static void svg_fill(fz_context *ctx, fz_device *dev, svg_document *doc, fz_path *path, svg_state *state)
{
	float opacity = state->opacity * state->fill_opacity;
	if (path)
		fz_fill_path(ctx, dev, path, state->fill_rule, state->transform, fz_device_rgb(ctx), state->fill_color, opacity, fz_default_color_params);
}

static void svg_stroke(fz_context *ctx, fz_device *dev, svg_document *doc, fz_path *path, svg_state *state)
{
	float opacity = state->opacity * state->stroke_opacity;
	if (path)
		fz_stroke_path(ctx, dev, path, state->stroke, state->transform, fz_device_rgb(ctx), state->stroke_color, opacity, fz_default_color_params);
}

static void svg_draw_path(fz_context *ctx, fz_device *dev, svg_document *doc, fz_path *path, svg_state *state)
{
	if (state->fill_is_set)
		svg_fill(ctx, dev, doc, path, state);
	if (state->stroke_is_set)
		svg_stroke(ctx, dev, doc, path, state);
}

/*
	We use the MAGIC number 0.551915 as a bezier subdivision to approximate
	a quarter circle arc. The reasons for this can be found here:
	http://mechanicalexpressions.com/explore/geometric-modeling/circle-spline-approximation.pdf
*/
static const float MAGIC_CIRCLE = 0.551915f;

static void approx_circle(fz_context *ctx, fz_path *path, float cx, float cy, float rx, float ry)
{
	float mx = rx * MAGIC_CIRCLE;
	float my = ry * MAGIC_CIRCLE;
	fz_moveto(ctx, path, cx, cy+ry);
	fz_curveto(ctx, path, cx + mx, cy + ry, cx + rx, cy + my, cx + rx, cy);
	fz_curveto(ctx, path, cx + rx, cy - my, cx + mx, cy - ry, cx, cy - ry);
	fz_curveto(ctx, path, cx - mx, cy - ry, cx - rx, cy - my, cx - rx, cy);
	fz_curveto(ctx, path, cx - rx, cy + my, cx - mx, cy + ry, cx, cy + ry);
	fz_closepath(ctx, path);
}

static void
svg_run_rect(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *node, const svg_state *inherit_state)
{
	svg_state local_state;

	char *x_att = fz_xml_att(node, "x");
	char *y_att = fz_xml_att(node, "y");
	char *w_att = fz_xml_att(node, "width");
	char *h_att = fz_xml_att(node, "height");
	char *rx_att = fz_xml_att(node, "rx");
	char *ry_att = fz_xml_att(node, "ry");

	float x = 0;
	float y = 0;
	float w = 0;
	float h = 0;
	float rx = 0;
	float ry = 0;

	fz_path *path = NULL;

	fz_var(path);

	svg_begin_state(ctx, &local_state, inherit_state);
	fz_try(ctx)
	{
		svg_parse_common(ctx, doc, node, &local_state);

		if (x_att) x = svg_parse_length(x_att, local_state.viewbox_w, local_state.fontsize);
		if (y_att) y = svg_parse_length(y_att, local_state.viewbox_h, local_state.fontsize);
		if (w_att) w = svg_parse_length(w_att, local_state.viewbox_w, local_state.fontsize);
		if (h_att) h = svg_parse_length(h_att, local_state.viewbox_h, local_state.fontsize);
		if (rx_att) rx = svg_parse_length(rx_att, local_state.viewbox_w, local_state.fontsize);
		if (ry_att) ry = svg_parse_length(ry_att, local_state.viewbox_h, local_state.fontsize);

		if (rx_att && !ry_att)
			ry = rx;
		if (ry_att && !rx_att)
			rx = ry;
		if (rx > w * 0.5f)
			rx = w * 0.5f;
		if (ry > h * 0.5f)
			ry = h * 0.5f;

		if (w <= 0 || h <= 0)
			break;

		path = fz_new_path(ctx);
		if (rx == 0 || ry == 0)
		{
			fz_moveto(ctx, path, x, y);
			fz_lineto(ctx, path, x + w, y);
			fz_lineto(ctx, path, x + w, y + h);
			fz_lineto(ctx, path, x, y + h);
		}
		else
		{
			float rxs = rx * MAGIC_CIRCLE;
			float rys = rx * MAGIC_CIRCLE;
			fz_moveto(ctx, path, x + w - rx, y);
			fz_curveto(ctx, path, x + w - rxs, y, x + w, y + rys, x + w, y + ry);
			fz_lineto(ctx, path, x + w, y + h - ry);
			fz_curveto(ctx, path, x + w, y + h - rys, x + w - rxs, y + h, x + w - rx, y + h);
			fz_lineto(ctx, path, x + rx, y + h);
			fz_curveto(ctx, path, x + rxs, y + h, x, y + h - rys, x, y + h - rx);
			fz_lineto(ctx, path, x, y + rx);
			fz_curveto(ctx, path, x, y + rxs, x + rxs, y, x + rx, y);
		}
		fz_closepath(ctx, path);

		svg_draw_path(ctx, dev, doc, path, &local_state);
	}
	fz_always(ctx)
	{
		fz_drop_path(ctx, path);
		svg_end_state(ctx, &local_state);
	}
	fz_catch(ctx)
		fz_rethrow(ctx);

}

static void
svg_run_circle(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *node, const svg_state *inherit_state)
{
	svg_state local_state;

	char *cx_att = fz_xml_att(node, "cx");
	char *cy_att = fz_xml_att(node, "cy");
	char *r_att = fz_xml_att(node, "r");

	float cx = 0;
	float cy = 0;
	float r = 0;
	fz_path *path = NULL;

	fz_var(path);

	svg_begin_state(ctx, &local_state, inherit_state);
	fz_try(ctx)
	{
		svg_parse_common(ctx, doc, node, &local_state);

		if (cx_att) cx = svg_parse_length(cx_att, local_state.viewbox_w, local_state.fontsize);
		if (cy_att) cy = svg_parse_length(cy_att, local_state.viewbox_h, local_state.fontsize);
		if (r_att) r = svg_parse_length(r_att, local_state.viewbox_size, 12);

		if (r > 0)
		{
			path = fz_new_path(ctx);
			approx_circle(ctx, path, cx, cy, r, r);
			svg_draw_path(ctx, dev, doc, path, &local_state);
		}
	}
	fz_always(ctx)
	{
		fz_drop_path(ctx, path);
		svg_end_state(ctx, &local_state);
	}
	fz_catch(ctx)
		fz_rethrow(ctx);

}

static void
svg_run_ellipse(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *node, const svg_state *inherit_state)
{
	svg_state local_state;

	char *cx_att = fz_xml_att(node, "cx");
	char *cy_att = fz_xml_att(node, "cy");
	char *rx_att = fz_xml_att(node, "rx");
	char *ry_att = fz_xml_att(node, "ry");

	float cx = 0;
	float cy = 0;
	float rx = 0;
	float ry = 0;

	fz_path *path = NULL;

	fz_var(path);

	svg_begin_state(ctx, &local_state, inherit_state);
	fz_try(ctx)
	{
		svg_parse_common(ctx, doc, node, &local_state);

		if (cx_att) cx = svg_parse_length(cx_att, local_state.viewbox_w, local_state.fontsize);
		if (cy_att) cy = svg_parse_length(cy_att, local_state.viewbox_h, local_state.fontsize);
		if (rx_att) rx = svg_parse_length(rx_att, local_state.viewbox_w, local_state.fontsize);
		if (ry_att) ry = svg_parse_length(ry_att, local_state.viewbox_h, local_state.fontsize);

		if (rx > 0 && ry > 0)
		{
			path = fz_new_path(ctx);
			approx_circle(ctx, path, cx, cy, rx, ry);
			svg_draw_path(ctx, dev, doc, path, &local_state);
		}
	}
	fz_always(ctx)
	{
		fz_drop_path(ctx, path);
		svg_end_state(ctx, &local_state);
	}
	fz_catch(ctx)
		fz_rethrow(ctx);
}

static void
svg_run_line(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *node, const svg_state *inherit_state)
{
	svg_state local_state;
	fz_path *path = NULL;

	char *x1_att = fz_xml_att(node, "x1");
	char *y1_att = fz_xml_att(node, "y1");
	char *x2_att = fz_xml_att(node, "x2");
	char *y2_att = fz_xml_att(node, "y2");

	float x1 = 0;
	float y1 = 0;
	float x2 = 0;
	float y2 = 0;

	fz_var(path);

	svg_begin_state(ctx, &local_state, inherit_state);
	fz_try(ctx)
	{
		svg_parse_common(ctx, doc, node, &local_state);

		if (x1_att) x1 = svg_parse_length(x1_att, local_state.viewbox_w, local_state.fontsize);
		if (y1_att) y1 = svg_parse_length(y1_att, local_state.viewbox_h, local_state.fontsize);
		if (x2_att) x2 = svg_parse_length(x2_att, local_state.viewbox_w, local_state.fontsize);
		if (y2_att) y2 = svg_parse_length(y2_att, local_state.viewbox_h, local_state.fontsize);

		if (local_state.stroke_is_set)
		{
			path = fz_new_path(ctx);
			fz_moveto(ctx, path, x1, y1);
			fz_lineto(ctx, path, x2, y2);
			svg_stroke(ctx, dev, doc, path, &local_state);
		}
	}
	fz_always(ctx)
	{
		fz_drop_path(ctx, path);
		svg_end_state(ctx, &local_state);
	}
	fz_catch(ctx)
		fz_rethrow(ctx);
}

static fz_path *
svg_parse_polygon_imp(fz_context *ctx, svg_document *doc, fz_xml *node, int doclose)
{
	fz_path *path;

	const char *str = fz_xml_att(node, "points");
	float number;
	float args[2];
	int nargs;
	int isfirst;

	if (!str)
		return NULL;

	isfirst = 1;
	nargs = 0;

	path = fz_new_path(ctx);
	fz_try(ctx)
	{
		while (*str)
		{
			while (svg_is_whitespace_or_comma(*str))
				str ++;

			if (svg_is_digit(*str))
			{
				str = svg_lex_number(&number, str);
				args[nargs++] = number;
			}
			else if (*str)
			{
				/* Don't know what this is. Just skip it. */
				fz_warn(ctx, "syntax error in polygon points");
				str++;
			}

			if (nargs == 2)
			{
				if (isfirst)
				{
					fz_moveto(ctx, path, args[0], args[1]);
					isfirst = 0;
				}
				else
				{
					fz_lineto(ctx, path, args[0], args[1]);
				}
				nargs = 0;
			}
		}
	}
	fz_catch(ctx)
	{
		fz_drop_path(ctx, path);
		fz_rethrow(ctx);
	}

	return path;
}

static void
svg_run_polyline(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *node, const svg_state *inherit_state)
{
	svg_state local_state;
	fz_path *path = NULL;

	fz_var(path);

	svg_begin_state(ctx, &local_state, inherit_state);
	fz_try(ctx)
	{
		svg_parse_common(ctx, doc, node, &local_state);

		if (local_state.stroke_is_set)
		{
			path = svg_parse_polygon_imp(ctx, doc, node, 0);
			svg_stroke(ctx, dev, doc, path, &local_state);
		}
	}
	fz_always(ctx)
	{
		fz_drop_path(ctx, path);
		svg_end_state(ctx, &local_state);
	}
	fz_catch(ctx)
		fz_rethrow(ctx);
}

static void
svg_run_polygon(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *node, const svg_state *inherit_state)
{
	svg_state local_state;
	fz_path *path = NULL;

	fz_var(path);

	svg_begin_state(ctx, &local_state, inherit_state);
	fz_try(ctx)
	{
		svg_parse_common(ctx, doc, node, &local_state);

		path = svg_parse_polygon_imp(ctx, doc, node, 1);
			svg_draw_path(ctx, dev, doc, path, &local_state);
	}
	fz_always(ctx)
	{
		fz_drop_path(ctx, path);
		svg_end_state(ctx, &local_state);
	}
	fz_catch(ctx)
		fz_rethrow(ctx);
}

static void
svg_add_arc_segment(fz_context *ctx, fz_path *path, fz_matrix mtx, float th0, float th1, int iscw)
{
	float t, d;
	fz_point p;

	while (th1 < th0)
		th1 += FZ_PI * 2;

	d = FZ_PI / 180; /* 1-degree precision */

	if (iscw)
	{
		for (t = th0 + d; t < th1 - d/2; t += d)
		{
			p = fz_transform_point_xy(cosf(t), sinf(t), mtx);
			fz_lineto(ctx, path, p.x, p.y);
		}
	}
	else
	{
		th0 += FZ_PI * 2;
		for (t = th0 - d; t > th1 + d/2; t -= d)
		{
			p = fz_transform_point_xy(cosf(t), sinf(t), mtx);
			fz_lineto(ctx, path, p.x, p.y);
		}
	}
}

static float
angle_between(const fz_point u, const fz_point v)
{
	float det = u.x * v.y - u.y * v.x;
	float sign = (det < 0 ? -1 : 1);
	float magu = u.x * u.x + u.y * u.y;
	float magv = v.x * v.x + v.y * v.y;
	float udotv = u.x * v.x + u.y * v.y;
	float t = udotv / (magu * magv);
	/* guard against rounding errors when near |1| (where acos will return NaN) */
	if (t < -1) t = -1;
	if (t > 1) t = 1;
	return sign * acosf(t);
}

static void
svg_add_arc(fz_context *ctx, fz_path *path,
	float size_x, float size_y, float rotation_angle,
	int is_large_arc, int is_clockwise,
	float point_x, float point_y)
{
	fz_matrix rotmat, revmat;
	fz_matrix mtx;
	fz_point pt;
	float rx, ry;
	float x1, y1, x2, y2;
	float x1t, y1t;
	float cxt, cyt, cx, cy;
	float t1, t2, t3;
	float sign;
	float th1, dth;

	pt = fz_currentpoint(ctx, path);
	x1 = pt.x;
	y1 = pt.y;
	x2 = point_x;
	y2 = point_y;
	rx = size_x;
	ry = size_y;

	if (is_clockwise != is_large_arc)
		sign = 1;
	else
		sign = -1;

	rotmat = fz_rotate(rotation_angle);
	revmat = fz_rotate(-rotation_angle);

	/* http://www.w3.org/TR/SVG11/implnote.html#ArcImplementationNotes */
	/* Conversion from endpoint to center parameterization */

	/* F.6.6.1 -- ensure radii are positive and non-zero */
	rx = fabsf(rx);
	ry = fabsf(ry);
	if (rx < 0.001f || ry < 0.001f || (x1 == x2 && y1 == y2))
	{
		fz_lineto(ctx, path, x2, y2);
		return;
	}

	/* F.6.5.1 */
	pt.x = (x1 - x2) / 2;
	pt.y = (y1 - y2) / 2;
	pt = fz_transform_vector(pt, revmat);
	x1t = pt.x;
	y1t = pt.y;

	/* F.6.6.2 -- ensure radii are large enough */
	t1 = (x1t * x1t) / (rx * rx) + (y1t * y1t) / (ry * ry);
	if (t1 > 1)
	{
		rx = rx * sqrtf(t1);
		ry = ry * sqrtf(t1);
	}

	/* F.6.5.2 */
	t1 = (rx * rx * ry * ry) - (rx * rx * y1t * y1t) - (ry * ry * x1t * x1t);
	t2 = (rx * rx * y1t * y1t) + (ry * ry * x1t * x1t);
	t3 = t1 / t2;
	/* guard against rounding errors; sqrt of negative numbers is bad for your health */
	if (t3 < 0) t3 = 0;
	t3 = sqrtf(t3);

	cxt = sign * t3 * (rx * y1t) / ry;
	cyt = sign * t3 * -(ry * x1t) / rx;

	/* F.6.5.3 */
	pt.x = cxt;
	pt.y = cyt;
	pt = fz_transform_vector(pt, rotmat);
	cx = pt.x + (x1 + x2) / 2;
	cy = pt.y + (y1 + y2) / 2;

	/* F.6.5.4 */
	{
		fz_point coord1, coord2, coord3, coord4;
		coord1.x = 1;
		coord1.y = 0;
		coord2.x = (x1t - cxt) / rx;
		coord2.y = (y1t - cyt) / ry;
		coord3.x = (x1t - cxt) / rx;
		coord3.y = (y1t - cyt) / ry;
		coord4.x = (-x1t - cxt) / rx;
		coord4.y = (-y1t - cyt) / ry;
		th1 = angle_between(coord1, coord2);
		dth = angle_between(coord3, coord4);
		if (dth < 0 && !is_clockwise)
			dth += ((FZ_PI / 180) * 360);
		if (dth > 0 && is_clockwise)
			dth -= ((FZ_PI / 180) * 360);
	}

	mtx = fz_pre_scale(fz_pre_rotate(fz_translate(cx, cy), rotation_angle), rx, ry);
	svg_add_arc_segment(ctx, path, mtx, th1, th1 + dth, is_clockwise);

	fz_lineto(ctx, path, point_x, point_y);
}

static void
svg_parse_path_data(fz_context *ctx, fz_path *path, const char *str)
{
	fz_point p;
	float x1, y1, x2, y2;

	int cmd;
	float number;
	float args[7];
	int nargs;

	/* saved control point for smooth curves */
	int reset_smooth = 1;
	float smooth_x = 0.0f;
	float smooth_y = 0.0f;

	cmd = 0;
	nargs = 0;

	fz_moveto(ctx, path, 0.0f, 0.0f); /* for the case of opening 'm' */

	while (*str)
	{
		while (svg_is_whitespace_or_comma(*str))
			str ++;

		/* arcto flag arguments are 1-character 0 or 1 */
		if ((cmd == 'a' || cmd == 'A') && (nargs == 3 || nargs == 4) && (*str == '0' || *str == '1'))
		{
			args[nargs++] = *str++ - '0';
		}
		else if (svg_is_digit(*str))
		{
			str = svg_lex_number(&number, str);
			if (nargs == nelem(args))
			{
				fz_warn(ctx, "stack overflow in path data");
				return;
			}
			args[nargs++] = number;
		}
		else if (svg_is_alpha(*str))
		{
			if (nargs != 0)
			{
				fz_warn(ctx, "syntax error in path data (wrong number of parameters to '%c')", cmd);
				return;
			}
			cmd = *str++;
		}
		else if (*str == 0)
		{
			return;
		}
		else
		{
			fz_warn(ctx, "syntax error in path data: '%c'", *str);
			return;
		}

		if (reset_smooth)
		{
			smooth_x = 0.0f;
			smooth_y = 0.0f;
		}

		reset_smooth = 1;

		switch (cmd)
		{
		case 'M':
			if (nargs == 2)
			{
				fz_moveto(ctx, path, args[0], args[1]);
				nargs = 0;
				cmd = 'L'; /* implicit lineto after */
			}
			break;

		case 'm':
			if (nargs == 2)
			{
				p = fz_currentpoint(ctx, path);
				fz_moveto(ctx, path, p.x + args[0], p.y + args[1]);
				nargs = 0;
				cmd = 'l'; /* implicit lineto after */
			}
			break;

		case 'Z':
		case 'z':
			if (nargs == 0)
			{
				fz_closepath(ctx, path);
			}
			break;

		case 'L':
			if (nargs == 2)
			{
				fz_lineto(ctx, path, args[0], args[1]);
				nargs = 0;
			}
			break;

		case 'l':
			if (nargs == 2)
			{
				p = fz_currentpoint(ctx, path);
				fz_lineto(ctx, path, p.x + args[0], p.y + args[1]);
				nargs = 0;
			}
			break;

		case 'H':
			if (nargs == 1)
			{
				p = fz_currentpoint(ctx, path);
				fz_lineto(ctx, path, args[0], p.y);
				nargs = 0;
			}
			break;

		case 'h':
			if (nargs == 1)
			{
				p = fz_currentpoint(ctx, path);
				fz_lineto(ctx, path, p.x + args[0], p.y);
				nargs = 0;
			}
			break;

		case 'V':
			if (nargs == 1)
			{
				p = fz_currentpoint(ctx, path);
				fz_lineto(ctx, path, p.x, args[0]);
				nargs = 0;
			}
			break;

		case 'v':
			if (nargs == 1)
			{
				p = fz_currentpoint(ctx, path);
				fz_lineto(ctx, path, p.x, p.y + args[0]);
				nargs = 0;
			}
			break;

		case 'C':
			reset_smooth = 0;
			if (nargs == 6)
			{
				fz_curveto(ctx, path, args[0], args[1], args[2], args[3], args[4], args[5]);
				smooth_x = args[4] - args[2];
				smooth_y = args[5] - args[3];
				nargs = 0;
			}
			break;

		case 'c':
			reset_smooth = 0;
			if (nargs == 6)
			{
				p = fz_currentpoint(ctx, path);
				fz_curveto(ctx, path,
					p.x + args[0], p.y + args[1],
					p.x + args[2], p.y + args[3],
					p.x + args[4], p.y + args[5]);
				smooth_x = args[4] - args[2];
				smooth_y = args[5] - args[3];
				nargs = 0;
			}
			break;

		case 'S':
			reset_smooth = 0;
			if (nargs == 4)
			{
				p = fz_currentpoint(ctx, path);
				fz_curveto(ctx, path,
					p.x + smooth_x, p.y + smooth_y,
					args[0], args[1],
					args[2], args[3]);
				smooth_x = args[2] - args[0];
				smooth_y = args[3] - args[1];
				nargs = 0;
			}
			break;

		case 's':
			reset_smooth = 0;
			if (nargs == 4)
			{
				p = fz_currentpoint(ctx, path);
				fz_curveto(ctx, path,
					p.x + smooth_x, p.y + smooth_y,
					p.x + args[0], p.y + args[1],
					p.x + args[2], p.y + args[3]);
				smooth_x = args[2] - args[0];
				smooth_y = args[3] - args[1];
				nargs = 0;
			}
			break;

		case 'Q':
			reset_smooth = 0;
			if (nargs == 4)
			{
				p = fz_currentpoint(ctx, path);
				x1 = args[0];
				y1 = args[1];
				x2 = args[2];
				y2 = args[3];
				fz_curveto(ctx, path,
					(p.x + 2 * x1) / 3, (p.y + 2 * y1) / 3,
					(x2 + 2 * x1) / 3, (y2 + 2 * y1) / 3,
					x2, y2);
				smooth_x = x2 - x1;
				smooth_y = y2 - y1;
				nargs = 0;
			}
			break;

		case 'q':
			reset_smooth = 0;
			if (nargs == 4)
			{
				p = fz_currentpoint(ctx, path);
				x1 = args[0] + p.x;
				y1 = args[1] + p.y;
				x2 = args[2] + p.x;
				y2 = args[3] + p.y;
				fz_curveto(ctx, path,
					(p.x + 2 * x1) / 3, (p.y + 2 * y1) / 3,
					(x2 + 2 * x1) / 3, (y2 + 2 * y1) / 3,
					x2, y2);
				smooth_x = x2 - x1;
				smooth_y = y2 - y1;
				nargs = 0;
			}
			break;

		case 'T':
			reset_smooth = 0;
			if (nargs == 2)
			{
				p = fz_currentpoint(ctx, path);
				x1 = p.x + smooth_x;
				y1 = p.y + smooth_y;
				x2 = args[0];
				y2 = args[1];
				fz_curveto(ctx, path,
					(p.x + 2 * x1) / 3, (p.y + 2 * y1) / 3,
					(x2 + 2 * x1) / 3, (y2 + 2 * y1) / 3,
					x2, y2);
				smooth_x = x2 - x1;
				smooth_y = y2 - y1;
				nargs = 0;
			}
			break;

		case 't':
			reset_smooth = 0;
			if (nargs == 2)
			{
				p = fz_currentpoint(ctx, path);
				x1 = p.x + smooth_x;
				y1 = p.y + smooth_y;
				x2 = args[0] + p.x;
				y2 = args[1] + p.y;
				fz_curveto(ctx, path,
					(p.x + 2 * x1) / 3, (p.y + 2 * y1) / 3,
					(x2 + 2 * x1) / 3, (y2 + 2 * y1) / 3,
					x2, y2);
				smooth_x = x2 - x1;
				smooth_y = y2 - y1;
				nargs = 0;
			}
			break;

		case 'A':
			if (nargs == 7)
			{
				svg_add_arc(ctx, path, args[0], args[1], args[2], args[3], args[4], args[5], args[6]);
				nargs = 0;
			}
			break;
		case 'a':
			if (nargs == 7)
			{
				p = fz_currentpoint(ctx, path);
				svg_add_arc(ctx, path, args[0], args[1], args[2], args[3], args[4], args[5] + p.x, args[6] + p.y);
				nargs = 0;
			}
			break;

		case 0:
			if (nargs != 0)
			{
				fz_warn(ctx, "path data must begin with a command");
				return;
			}
			break;

		default:
			fz_warn(ctx, "unrecognized command in path data: '%c'", cmd);
			return;
		}
	}
}

static void
svg_run_path(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *node, const svg_state *inherit_state)
{
	svg_state local_state;
	fz_path *path = NULL;

	const char *d_att = fz_xml_att(node, "d");
	/* unused: char *path_length_att = fz_xml_att(node, "pathLength"); */

	fz_var(path);

	svg_begin_state(ctx, &local_state, inherit_state);
	fz_try(ctx)
	{
		svg_parse_common(ctx, doc, node, &local_state);

		if (d_att)
		{
			path = fz_new_path(ctx);
			svg_parse_path_data(ctx, path, d_att);
			svg_draw_path(ctx, dev, doc, path, &local_state);
		}
	}
	fz_always(ctx)
	{
		fz_drop_path(ctx, path);
		svg_end_state(ctx, &local_state);
	}
	fz_catch(ctx)
		fz_rethrow(ctx);
}

/* svg, symbol, image, foreignObject establish new viewports */
static void
svg_parse_viewport(fz_context *ctx, svg_document *doc, fz_xml *node, svg_state *state)
{
	char *w_att = fz_xml_att(node, "width");
	char *h_att = fz_xml_att(node, "height");

	if (w_att)
		state->viewport_w = svg_parse_length(w_att, state->viewbox_w, state->fontsize);
	if (h_att)
		state->viewport_h = svg_parse_length(h_att, state->viewbox_h, state->fontsize);

}

static void
svg_lex_viewbox(const char *s, float *x, float *y, float *w, float *h)
{
	*x = *y = *w = *h = 0;
	while (svg_is_whitespace_or_comma(*s)) ++s;
	if (svg_is_digit(*s)) s = svg_lex_number(x, s);
	while (svg_is_whitespace_or_comma(*s)) ++s;
	if (svg_is_digit(*s)) s = svg_lex_number(y, s);
	while (svg_is_whitespace_or_comma(*s)) ++s;
	if (svg_is_digit(*s)) s = svg_lex_number(w, s);
	while (svg_is_whitespace_or_comma(*s)) ++s;
	if (svg_is_digit(*s)) s = svg_lex_number(h, s);
}

static int
svg_parse_preserve_aspect_ratio(const char *att, int *x, int *y)
{
	*x = *y = 1;
	if (strstr(att, "none")) return 0;
	if (strstr(att, "xMin")) *x = 0;
	if (strstr(att, "xMid")) *x = 1;
	if (strstr(att, "xMax")) *x = 2;
	if (strstr(att, "YMin")) *y = 0;
	if (strstr(att, "YMid")) *y = 1;
	if (strstr(att, "YMax")) *y = 2;
	return 1;
}

/* svg, symbol, image, foreignObject plus marker, pattern, view can use viewBox to set the transform */
static void
svg_parse_viewbox(fz_context *ctx, svg_document *doc, fz_xml *node, svg_state *state)
{
	char *viewbox_att = fz_xml_att(node, "viewBox");
	char *preserve_att = fz_xml_att(node, "preserveAspectRatio");
	if (viewbox_att)
	{
		/* scale and translate to fit [minx miny minx+w miny+h] to [0 0 viewport.w viewport.h] */
		float min_x, min_y, box_w, box_h, sx, sy;
		int align_x=1, align_y=1, preserve=1;
		float pad_x=0, pad_y=0;

		svg_lex_viewbox(viewbox_att, &min_x, &min_y, &box_w, &box_h);
		sx = state->viewport_w / box_w;
		sy = state->viewport_h / box_h;

		if (preserve_att)
			preserve = svg_parse_preserve_aspect_ratio(preserve_att, &align_x, &align_y);
		if (preserve)
		{
			sx = sy = fz_min(sx, sy);
			if (align_x == 1) pad_x = (box_w * sx - state->viewport_w) / 2;
			if (align_x == 2) pad_x = (box_w * sx - state->viewport_w);
			if (align_y == 1) pad_y = (box_h * sy - state->viewport_h) / 2;
			if (align_y == 2) pad_y = (box_h * sy - state->viewport_h);
			state->transform = fz_concat(fz_translate(-pad_x, -pad_y), state->transform);
		}
		state->transform = fz_concat(fz_scale(sx, sy), state->transform);
		state->transform = fz_concat(fz_translate(-min_x, -min_y), state->transform);
		state->viewbox_w = box_w;
		state->viewbox_h = box_h;
		state->viewbox_size = sqrtf(box_w*box_w + box_h*box_h) / sqrtf(2);
	}
}


/*
	A presentation property of one element. A declaration in the style
	attribute wins over the attribute of the same name, as CSS ranks them.
	NULL when neither sets it, or when the value is "inherit" (the state
	already holds the inherited value).
*/
static const char *
svg_prop(fz_xml *node, const char *style, const char *name, char *buf, int buf_size)
{
	const char *value;
	if (svg_style_lookup(style, name, buf, buf_size))
		value = buf;
	else
		value = fz_xml_att(node, name);
	if (value && !strcmp(value, "inherit"))
		return NULL;
	return value;
}

/* CSS absolute size keywords, in px, as browsers resolve them. */
static const struct { const char *name; float size; } svg_font_size_keywords[] = {
	{ "xx-small", 9 }, { "x-small", 10 }, { "small", 13 }, { "medium", 16 },
	{ "large", 18 }, { "x-large", 24 }, { "xx-large", 32 }, { "xxx-large", 48 },
};

/* Returns 0 when str is not a font size. */
static float
svg_parse_font_size(const char *str, float parent)
{
	char *end;
	size_t i;
	float size;

	for (i = 0; i < nelem(svg_font_size_keywords); ++i)
		if (!strcmp(str, svg_font_size_keywords[i].name))
			return svg_font_size_keywords[i].size;
	if (!strcmp(str, "smaller"))
		return parent / 1.2f;
	if (!strcmp(str, "larger"))
		return parent * 1.2f;

	size = fz_strtof(str, &end);
	if (end == str || size <= 0)
		return 0;
	/* em and % are relative to the parent's size */
	return svg_parse_length(str, parent, parent);
}

/* Returns -1 when str is not a font weight. */
static int
svg_parse_font_weight(const char *str, int parent_is_bold)
{
	char *end;
	float weight;
	if (!strcmp(str, "normal") || !strcmp(str, "lighter"))
		return 0;
	if (!strcmp(str, "bold") || !strcmp(str, "bolder"))
		return 1;
	weight = fz_strtof(str, &end);
	if (end == str || *end || weight < 1 || weight > 1000)
		return -1;
	/* With one regular and one bold face, CSS font matching takes the
	   regular face up to 500 and the bold one from 600. */
	return weight >= 600;
}

static int
svg_is_font_style_keyword(const char *str)
{
	static const char *keywords[] = {
		"normal", "small-caps", "ultra-condensed", "extra-condensed", "condensed",
		"semi-condensed", "semi-expanded", "expanded", "extra-expanded", "ultra-expanded",
	};
	size_t i;
	for (i = 0; i < nelem(keywords); ++i)
		if (!strcmp(str, keywords[i]))
			return 1;
	return 0;
}

/*
	The CSS font shorthand:
	[style] [variant] [weight] [stretch] size[/line-height] family-list,
	which matplotlib writes as `font: 600 10px 'DejaVu Sans', sans-serif`.
	Style and weight it leaves out reset to normal. An invalid shorthand is
	ignored, as CSS ignores an invalid declaration.
*/
static void
svg_parse_font_shorthand(svg_state *state, const char *str)
{
	const char *p = str;
	int italic = 0, bold = 0;
	float size = 0;

	while (*p)
	{
		char token[64];
		int n = 0, weight;
		char *slash;

		while (svg_is_whitespace(*p))
			++p;
		if (!*p || *p == '\'' || *p == '"' || *p == ',')
			return; /* family before size: invalid */
		while (*p && !svg_is_whitespace(*p) && *p != ',' && n < (int)sizeof token - 1)
			token[n++] = *p++;
		token[n] = 0;

		/* the line height may follow the size after spaces too: "10px / 1.2" */
		slash = strchr(token, '/');
		if (slash)
			*slash = 0;

		if (!strcmp(token, "italic") || !strcmp(token, "oblique"))
			italic = 1;
		else if (svg_is_font_style_keyword(token))
			;
		else if ((weight = svg_parse_font_weight(token, 0)) >= 0)
			bold = weight;
		else if ((size = svg_parse_font_size(token, state->fontsize)) > 0)
			break;
		else
			return;
	}
	if (size <= 0)
		return;

	/* skip the line height */
	while (svg_is_whitespace(*p))
		++p;
	if (*p == '/')
	{
		++p;
		while (svg_is_whitespace(*p))
			++p;
		while (*p && !svg_is_whitespace(*p))
			++p;
	}
	while (svg_is_whitespace(*p))
		++p;
	if (!*p)
		return; /* the family is required */

	state->fontsize = size;
	state->is_bold = bold;
	state->is_italic = italic;
	fz_strlcpy(state->font_family, p, sizeof state->font_family);
}

enum { SVG_BASELINE_AUTO, SVG_BASELINE_MIDDLE, SVG_BASELINE_CENTRAL, SVG_BASELINE_HANGING,
	SVG_BASELINE_TOP, SVG_BASELINE_BOTTOM, SVG_BASELINE_MATHEMATICAL };

static void
svg_apply_font_property(svg_state *state, const char *name, const char *value)
{
	float size;
	int weight;

	if (!value || !strcmp(value, "inherit"))
		return;

	if (!strcmp(name, "font"))
		svg_parse_font_shorthand(state, value);
	else if (!strcmp(name, "font-size"))
	{
		size = svg_parse_font_size(value, state->fontsize);
		if (size > 0)
			state->fontsize = size;
	}
	else if (!strcmp(name, "font-family"))
		fz_strlcpy(state->font_family, value, sizeof state->font_family);
	else if (!strcmp(name, "font-weight"))
	{
		weight = svg_parse_font_weight(value, state->is_bold);
		if (weight >= 0)
			state->is_bold = weight;
	}
	else if (!strcmp(name, "font-style"))
		state->is_italic = !strcmp(value, "italic") || !strncmp(value, "oblique", 7);
	else if (!strcmp(name, "text-anchor"))
	{
		if (!strcmp(value, "start")) state->text_anchor = 0;
		if (!strcmp(value, "middle")) state->text_anchor = 1;
		if (!strcmp(value, "end")) state->text_anchor = 2;
	}
	else if (!strcmp(name, "dominant-baseline") || !strcmp(name, "alignment-baseline"))
	{
		if (!strcmp(value, "auto") || !strcmp(value, "alphabetic") || !strcmp(value, "baseline"))
			state->dominant_baseline = SVG_BASELINE_AUTO;
		else if (!strcmp(value, "middle"))
			state->dominant_baseline = SVG_BASELINE_MIDDLE;
		else if (!strcmp(value, "central"))
			state->dominant_baseline = SVG_BASELINE_CENTRAL;
		else if (!strcmp(value, "hanging"))
			state->dominant_baseline = SVG_BASELINE_HANGING;
		else if (!strcmp(value, "text-before-edge") || !strcmp(value, "text-top") || !strcmp(value, "before-edge"))
			state->dominant_baseline = SVG_BASELINE_TOP;
		else if (!strcmp(value, "text-after-edge") || !strcmp(value, "text-bottom") ||
			!strcmp(value, "after-edge") || !strcmp(value, "ideographic"))
			state->dominant_baseline = SVG_BASELINE_BOTTOM;
		else if (!strcmp(value, "mathematical"))
			state->dominant_baseline = SVG_BASELINE_MATHEMATICAL;
	}
}

/*
	Font properties inherit, so every element parses them. Presentation
	attributes first, then the style attribute's declarations, which win; in
	each, the shorthand before the longhands that refine it.
*/
static void
svg_parse_font_attributes(fz_context *ctx, svg_document *doc, fz_xml *node, const char *style, svg_state *state)
{
	static const char *names[] = {
		"font", "font-size", "font-family", "font-weight", "font-style",
		"text-anchor", "dominant-baseline", "alignment-baseline",
	};
	char buf[256];
	size_t i;

	for (i = 0; i < nelem(names); ++i)
		svg_apply_font_property(state, names[i], fz_xml_att(node, names[i]));
	if (style)
		for (i = 0; i < nelem(names); ++i)
			if (svg_style_lookup(style, names[i], buf, sizeof buf))
				svg_apply_font_property(state, names[i], buf);
}

static void
svg_parse_dash_array(fz_context *ctx, const char *str, svg_state *state)
{
	float dashes[32];
	int i, n = 0, nonzero = 0;
	const char *p = str;

	if (strcmp(str, "none"))
	{
		while (*p && n < (int)nelem(dashes) / 2)
		{
			char token[32];
			int k = 0;
			while (svg_is_whitespace_or_comma(*p))
				++p;
			while (*p && !svg_is_whitespace_or_comma(*p) && k < (int)sizeof token - 1)
				token[k++] = *p++;
			token[k] = 0;
			if (!k)
				break;
			dashes[n] = svg_parse_length(token, state->viewbox_size, state->fontsize);
			if (dashes[n] < 0)
				return; /* invalid: ignored */
			nonzero |= dashes[n] > 0;
			++n;
		}
	}
	/* An odd list repeats to make it even; an all-zero list draws solid. */
	if (n & 1)
	{
		for (i = 0; i < n; ++i)
			dashes[n + i] = dashes[i];
		n *= 2;
	}
	if (!nonzero)
		n = 0;

	state->stroke = fz_unshare_stroke_state_with_dash_len(ctx, state->stroke, n);
	for (i = 0; i < n; ++i)
		state->stroke->dash_list[i] = dashes[i];
}

/* parse transform and presentation attributes */
static void
svg_parse_common(fz_context *ctx, svg_document *doc, fz_xml *node, svg_state *state)
{
	fz_stroke_state *stroke;
	char *transform_att = fz_xml_att(node, "transform");
	char *style_att = fz_xml_att(node, "style");
	char buf[256];
	const char *v;

	// TODO: clip-rule, marker, overflow, mask

	if (transform_att)
		state->transform = svg_parse_transform(ctx, doc, transform_att, state->transform);

	/* Fonts first: the lengths below may be in em. */
	svg_parse_font_attributes(ctx, doc, node, style_att, state);

	/* Group opacity, approximated by multiplying into what is drawn. */
	if ((v = svg_prop(node, style_att, "opacity", buf, sizeof buf)))
		state->opacity *= svg_parse_number(v, 0, 1, 1);

	if ((v = svg_prop(node, style_att, "fill", buf, sizeof buf)))
	{
		state->fill_is_set = !!strcmp(v, "none");
		if (state->fill_is_set)
			svg_parse_color(ctx, doc, v, state->fill_color);
	}
	if ((v = svg_prop(node, style_att, "fill-opacity", buf, sizeof buf)))
		state->fill_opacity = svg_parse_number(v, 0, 1, state->fill_opacity);
	if ((v = svg_prop(node, style_att, "fill-rule", buf, sizeof buf)))
	{
		if (!strcmp(v, "nonzero"))
			state->fill_rule = 0;
		if (!strcmp(v, "evenodd"))
			state->fill_rule = 1;
	}

	if ((v = svg_prop(node, style_att, "stroke", buf, sizeof buf)))
	{
		state->stroke_is_set = !!strcmp(v, "none");
		if (state->stroke_is_set)
			svg_parse_color(ctx, doc, v, state->stroke_color);
	}
	if ((v = svg_prop(node, style_att, "stroke-opacity", buf, sizeof buf)))
		state->stroke_opacity = svg_parse_number(v, 0, 1, state->stroke_opacity);

	if ((v = svg_prop(node, style_att, "stroke-dasharray", buf, sizeof buf)))
		svg_parse_dash_array(ctx, v, state);

	stroke = state->stroke = fz_unshare_stroke_state(ctx, state->stroke);

	if ((v = svg_prop(node, style_att, "stroke-dashoffset", buf, sizeof buf)))
		stroke->dash_phase = svg_parse_length(v, state->viewbox_size, state->fontsize);

	if ((v = svg_prop(node, style_att, "stroke-width", buf, sizeof buf)))
		stroke->linewidth = svg_parse_length(v, state->viewbox_size, state->fontsize);

	if ((v = svg_prop(node, style_att, "stroke-linecap", buf, sizeof buf)))
	{
		if (!strcmp(v, "butt"))
			stroke->start_cap = FZ_LINECAP_BUTT;
		if (!strcmp(v, "round"))
			stroke->start_cap = FZ_LINECAP_ROUND;
		if (!strcmp(v, "square"))
			stroke->start_cap = FZ_LINECAP_SQUARE;
	}
	stroke->dash_cap = stroke->start_cap;
	stroke->end_cap = stroke->start_cap;

	if ((v = svg_prop(node, style_att, "stroke-linejoin", buf, sizeof buf)))
	{
		if (!strcmp(v, "miter"))
			stroke->linejoin = FZ_LINEJOIN_MITER;
		if (!strcmp(v, "round"))
			stroke->linejoin = FZ_LINEJOIN_ROUND;
		if (!strcmp(v, "bevel"))
			stroke->linejoin = FZ_LINEJOIN_BEVEL;
	}

	if ((v = svg_prop(node, style_att, "stroke-miterlimit", buf, sizeof buf)))
		stroke->miterlimit = svg_parse_number(v, 1, 1000, stroke->miterlimit);
}

static void
svg_run_svg(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *root, const svg_state *inherit_state)
{
	svg_state local_state;
	fz_xml *node;

	char *w_att = fz_xml_att(root, "width");
	char *h_att = fz_xml_att(root, "height");
	char *viewbox_att = fz_xml_att(root, "viewBox");

	svg_begin_state(ctx, &local_state, inherit_state);
	fz_try(ctx)
	{
		/* get default viewport from viewBox if width and/or height is missing */
		if (viewbox_att && (!w_att || !h_att))
		{
			float x, y;
			svg_lex_viewbox(viewbox_att, &x, &y, &local_state.viewbox_w, &local_state.viewbox_h);
			if (!w_att) local_state.viewport_w = local_state.viewbox_w;
			if (!h_att) local_state.viewport_h = local_state.viewbox_h;
		}

		svg_parse_viewport(ctx, doc, root, &local_state);
		svg_parse_viewbox(ctx, doc, root, &local_state);
		svg_parse_common(ctx, doc, root, &local_state);

		for (node = fz_xml_down(root); node; node = fz_xml_next(node))
			svg_run_element(ctx, dev, doc, node, &local_state);
	}
	fz_always(ctx)
		svg_end_state(ctx, &local_state);
	fz_catch(ctx)
		fz_rethrow(ctx);
}

static void
svg_run_g(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *root, const svg_state *inherit_state)
{
	svg_state local_state;
	fz_xml *node;

	svg_begin_state(ctx, &local_state, inherit_state);
	fz_try(ctx)
	{
		svg_parse_common(ctx, doc, root, &local_state);

		for (node = fz_xml_down(root); node; node = fz_xml_next(node))
			svg_run_element(ctx, dev, doc, node, &local_state);
	}
	fz_always(ctx)
		svg_end_state(ctx, &local_state);
	fz_catch(ctx)
		fz_rethrow(ctx);
}

static void
svg_run_use_symbol(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *use, fz_xml *symbol, const svg_state *inherit_state)
{
	svg_state local_state;
	fz_xml *node;

	svg_begin_state(ctx, &local_state, inherit_state);
	fz_try(ctx)
	{
		svg_parse_viewport(ctx, doc, use, &local_state);
		svg_parse_viewbox(ctx, doc, use, &local_state);

		for (node = fz_xml_down(symbol); node; node = fz_xml_next(node))
			svg_run_element(ctx, dev, doc, node, &local_state);
	}
	fz_always(ctx)
		svg_end_state(ctx, &local_state);
	fz_catch(ctx)
		fz_rethrow(ctx);
}

static void
svg_run_use(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *root, const svg_state *inherit_state)
{
	svg_state local_state;
	svg_cycle_list cycle;

	char *href_att = fz_xml_att_alt(root, "xlink:href", "href");
	char *x_att = fz_xml_att(root, "x");
	char *y_att = fz_xml_att(root, "y");
	fz_xml *linked = NULL;

	float x = 0;
	float y = 0;

	svg_begin_state(ctx, &local_state, inherit_state);
	fz_try(ctx)
	{
		if (++local_state.use_depth > MAX_USE_DEPTH)
		{
			fz_warn(ctx, "svg: too much recursion");
			break;
		}

		svg_parse_common(ctx, doc, root, &local_state);
		if (x_att) x = svg_parse_length(x_att, local_state.viewbox_w, local_state.fontsize);
		if (y_att) y = svg_parse_length(y_att, local_state.viewbox_h, local_state.fontsize);

		local_state.transform = fz_concat(fz_translate(x, y), local_state.transform);

		if (href_att && href_att[0] == '#')
		{
			linked = fz_tree_lookup(ctx, doc->idmap, href_att + 1);
			if (linked)
			{
				if (svg_push_use(ctx, doc, &cycle, linked))
				{
					fz_try(ctx)
					{
				if (fz_xml_is_tag(linked, "symbol"))
					svg_run_use_symbol(ctx, dev, doc, root, linked, &local_state);
				else
					svg_run_element(ctx, dev, doc, linked, &local_state);
			}
					fz_always(ctx)
						svg_pop_use(ctx, doc);
					fz_catch(ctx)
						fz_rethrow(ctx);
				}
				else
				{
					fz_warn(ctx, "svg: mutual recursion in <use> symbol");
				}
			}
			else
			{
				fz_warn(ctx, "svg: cannot find linked symbol");
			}
		}
		else
		{
			fz_warn(ctx, "svg: cannot find linked symbol");
		}

	}
	fz_always(ctx)
		svg_end_state(ctx, &local_state);
	fz_catch(ctx)
		fz_rethrow(ctx);
}

static void
svg_run_image(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *root, const svg_state *inherit_state)
{
	svg_state local_state;
	float x=0, y=0, w=0, h=0;
	const char *data;

	static const char *jpeg_uri = "data:image/jpeg;base64,";
	static const char *png_uri = "data:image/png;base64,";

	char *href_att = fz_xml_att_alt(root, "xlink:href", "href");
	char *x_att = fz_xml_att(root, "x");
	char *y_att = fz_xml_att(root, "y");
	char *w_att = fz_xml_att(root, "width");
	char *h_att = fz_xml_att(root, "height");

	svg_begin_state(ctx, &local_state, inherit_state);
	fz_try(ctx)
	{
		svg_parse_common(ctx, doc, root, &local_state);
		if (x_att) x = svg_parse_length(x_att, local_state.viewbox_w, local_state.fontsize);
		if (y_att) y = svg_parse_length(y_att, local_state.viewbox_h, local_state.fontsize);
		if (w_att) w = svg_parse_length(w_att, local_state.viewbox_w, local_state.fontsize);
		if (h_att) h = svg_parse_length(h_att, local_state.viewbox_h, local_state.fontsize);

		if (w <= 0 || h <= 0)
			break; // out of try-catch

		if (!href_att)
			break; // out of try-catch

		local_state.transform = fz_concat(fz_translate(x, y), local_state.transform);
		local_state.transform = fz_concat(fz_scale(w, h), local_state.transform);

		if (!strncmp(href_att, jpeg_uri, strlen(jpeg_uri)))
			data = href_att + strlen(jpeg_uri);
		else if (!strncmp(href_att, png_uri, strlen(png_uri)))
			data = href_att + strlen(png_uri);
		else
			data = NULL;
		if (data)
		{
			fz_image *img = NULL;
			fz_buffer *buf;

			fz_var(img);

			buf = fz_new_buffer_from_base64(ctx, data, 0);
			fz_try(ctx)
			{
				fz_matrix orient;
				img = fz_new_image_from_buffer(ctx, buf);
				orient = fz_image_orientation_matrix(ctx, img);
				local_state.transform = fz_concat(orient, local_state.transform);
				fz_fill_image(ctx, dev, img, local_state.transform, 1, fz_default_color_params);
			}
			fz_always(ctx)
			{
				fz_drop_buffer(ctx, buf);
				fz_drop_image(ctx, img);
			}
			fz_catch(ctx)
			{
				fz_rethrow_if(ctx, FZ_ERROR_SYSTEM);
				fz_report_error(ctx);
				fz_warn(ctx, "svg: ignoring embedded image '%s'", href_att);
			}
		}
		else if (doc->zip)
		{
			char path[2048];
			fz_buffer *buf = NULL;
			fz_image *img = NULL;

			fz_var(buf);
			fz_var(img);

			fz_strlcpy(path, doc->base_uri, sizeof path);
			fz_strlcat(path, "/", sizeof path);
			fz_strlcat(path, href_att, sizeof path);
			fz_urldecode(path);

			fz_try(ctx)
			{
				fz_matrix orient;
				buf = fz_read_archive_entry(ctx, doc->zip, path);
				img = fz_new_image_from_buffer(ctx, buf);
				orient = fz_image_orientation_matrix(ctx, img);
				local_state.transform = fz_concat(orient, local_state.transform);
				fz_fill_image(ctx, dev, img, local_state.transform, 1, fz_default_color_params);
			}
			fz_always(ctx)
			{
				fz_drop_buffer(ctx, buf);
				fz_drop_image(ctx, img);
			}
			fz_catch(ctx)
			{
				fz_rethrow_if(ctx, FZ_ERROR_SYSTEM);
				fz_report_error(ctx);
				fz_warn(ctx, "svg: ignoring external image '%s'", href_att);
			}
		}
		else
		{
			fz_warn(ctx, "svg: ignoring external image '%s'", href_att);
		}

	}
	fz_always(ctx)
		svg_end_state(ctx, &local_state);
	fz_catch(ctx)
		fz_rethrow(ctx);
}

enum { SVG_FONT_SERIF, SVG_FONT_SANS, SVG_FONT_MONO };

/*
	Which of the built-in faces stands in for a family list. The first family
	we recognise wins, as CSS takes the first installed one: the names that
	plotting libraries, design tools and stylesheets commonly write map to
	the sans (Helvetica-metric), serif or monospace face. Unknown names whose
	words give them away ("Noto Sans CJK", "Fira Mono") follow those words;
	other unknown names are skipped. With nothing recognised the face is
	serif, the CSS default.
*/
static int
svg_font_class(const char *list)
{
	static const char *sans[] = {
		"sans-serif", "sans", "sans serif", "ui-sans-serif", "system-ui", "-apple-system",
		"blinkmacsystemfont", "helvetica", "helvetica neue", "arial", "arial unicode ms",
		"dejavu sans", "bitstream vera sans", "liberation sans", "nimbus sans", "nimbus sans l",
		"freesans", "verdana", "geneva", "tahoma", "trebuchet ms", "segoe ui", "lucida grande",
		"lucida sans", "lucida sans unicode", "lucid", "calibri", "candara", "roboto", "open sans",
		"inter", "ubuntu", "cantarell", "avenir", "avenir next", "futura", "gill sans", "optima",
		"avant garde", "frutiger", "myriad pro", "source sans pro", "sf pro", "sf pro text",
		"sf pro display", "computer modern sans serif", "cmss10",
	};
	static const char *mono[] = {
		"monospace", "ui-monospace", "courier", "courier new", "menlo", "monaco", "consolas",
		"andale mono", "lucida console", "cmtt10", "computer modern typewriter",
	};
	static const char *serif[] = {
		"serif", "ui-serif", "times", "times new roman", "georgia", "palatino", "palatino linotype",
		"book antiqua", "garamond", "cambria", "baskerville", "charter", "bitstream charter",
		"new century schoolbook", "century schoolbook l", "utopia", "cmr10", "computer modern roman",
		"stixgeneral", "stix", "nimbus roman", "liberation serif", "dejavu serif",
	};
	const char *p = list;

	while (p && *p)
	{
		char name[64];
		int n = 0;
		size_t i;
		char quote = 0;

		while (svg_is_whitespace_or_comma(*p))
			++p;
		if (*p == '\'' || *p == '"')
			quote = *p++;
		while (*p && (quote ? *p != quote : *p != ','))
		{
			if (n < (int)sizeof name - 1)
				name[n++] = (*p >= 'A' && *p <= 'Z') ? *p + 32 : *p;
			++p;
		}
		if (quote && *p == quote)
			++p;
		while (n > 0 && svg_is_whitespace(name[n - 1]))
			--n;
		name[n] = 0;
		if (!n)
			continue;

		for (i = 0; i < nelem(mono); ++i)
			if (!strcmp(name, mono[i]))
				return SVG_FONT_MONO;
		for (i = 0; i < nelem(sans); ++i)
			if (!strcmp(name, sans[i]))
				return SVG_FONT_SANS;
		for (i = 0; i < nelem(serif); ++i)
			if (!strcmp(name, serif[i]))
				return SVG_FONT_SERIF;
		if (strstr(name, "mono") || strstr(name, "code") || strstr(name, "courier"))
			return SVG_FONT_MONO;
		if (strstr(name, "sans") || strstr(name, "grotesk") || strstr(name, "gothic"))
			return SVG_FONT_SANS;
		if (strstr(name, "serif") || strstr(name, "roman") || strstr(name, "times"))
			return SVG_FONT_SERIF;
	}
	return SVG_FONT_SERIF;
}

static fz_font *
svg_load_font(fz_context *ctx, const svg_state *state)
{
	static const char *faces[3][4] = {
		{ "Times-Roman", "Times-Italic", "Times-Bold", "Times-BoldItalic" },
		{ "Helvetica", "Helvetica-Oblique", "Helvetica-Bold", "Helvetica-BoldOblique" },
		{ "Courier", "Courier-Oblique", "Courier-Bold", "Courier-BoldOblique" },
	};
	int style = (state->is_bold ? 2 : 0) + (state->is_italic ? 1 : 0);
	return fz_new_base14_font(ctx, faces[svg_font_class(state->font_family)][style]);
}

/*
	How far below the alphabetic baseline the dominant baseline sits, in em,
	from the face's ascent and descent the way browsers derive it.
*/
static float
svg_baseline_shift(fz_context *ctx, fz_font *font, int baseline)
{
	float ascent = fz_font_ascender(ctx, font);
	float descent = fz_font_descender(ctx, font); /* negative */
	switch (baseline)
	{
	default:
	case SVG_BASELINE_AUTO: return 0;
	case SVG_BASELINE_MIDDLE: return 0.26f; /* half the x-height of the stand-in faces */
	case SVG_BASELINE_CENTRAL: return (ascent + descent) / 2;
	case SVG_BASELINE_HANGING: return ascent * 0.8f;
	case SVG_BASELINE_TOP: return ascent;
	case SVG_BASELINE_BOTTOM: return descent;
	case SVG_BASELINE_MATHEMATICAL: return ascent * 0.5f;
	}
}

static fz_matrix
svg_run_text_string(fz_context *ctx, fz_device *dev, fz_matrix trm, const char *s, const svg_state *state)
{
	fz_font *font = NULL;
	fz_text *text = NULL;

	fz_var(font);
	fz_var(text);

	fz_try(ctx)
	{
		float shift;

		font = svg_load_font(ctx, state);
		text = fz_new_text(ctx);

		if (state->text_anchor > 0)
		{
			fz_matrix adv = fz_measure_string(ctx, font, trm, s, 0, 0, FZ_BIDI_LTR, FZ_LANG_UNSET);
			if (state->text_anchor == 1)
				trm.e -= (adv.e - trm.e) / 2;
			else if (state->text_anchor == 2)
				trm.e -= (adv.e - trm.e);
		}

		/* The baseline shift moves these glyphs, not the next string's pen. */
		shift = svg_baseline_shift(ctx, font, state->dominant_baseline) * state->fontsize;
		trm.f += shift;
		trm = fz_show_string(ctx, text, font, trm, s, 0, 0, FZ_BIDI_LTR, FZ_LANG_UNSET);
		trm.f -= shift;

		if (state->fill_is_set)
			fz_fill_text(ctx, dev, text,
				state->transform,
				fz_device_rgb(ctx), state->fill_color,
				state->opacity,
				fz_default_color_params);
		if (state->stroke_is_set)
			fz_stroke_text(ctx, dev, text,
				state->stroke,
				state->transform,
				fz_device_rgb(ctx), state->stroke_color,
				state->opacity,
				fz_default_color_params);
		if (!state->fill_is_set && !state->stroke_is_set)
			fz_ignore_text(ctx, dev, text, state->transform);
	}
	fz_always(ctx)
	{
		fz_drop_text(ctx, text);
		fz_drop_font(ctx, font);
	}
	fz_catch(ctx)
	{
		fz_rethrow(ctx);
	}

	return trm;
}

static void
svg_collapse_whitespace(char *start, int is_first, int is_last)
{
	int c, last_c = (is_first ? ' ' : 0);
	char *s, *p;
	s = p = start;
	while ((c = *s++) != 0)
	{
		if (c == '\n' || c == '\r')
			continue;
		if (c == '\t')
			c = ' ';
		if (c == ' ' && last_c == ' ')
			continue;
		*p++ = last_c = c;
	}
	if (is_last && p > start && p[-1] == ' ')
		--p;
	*p = 0;
}

#define SVG_MAX_GLYPH_POSITIONS 256

/*
	An x or y attribute: one length, or a list that places the element's
	characters one by one (matplotlib's mathtext writes x="0 6.1 12.3").
	Returns how many lengths it holds, at most SVG_MAX_GLYPH_POSITIONS.
*/
static int
svg_parse_position_list(const char *str, float *out, float percent, float font_size)
{
	int n = 0;
	while (str && *str && n < SVG_MAX_GLYPH_POSITIONS)
	{
		char token[64];
		int k = 0;
		while (svg_is_whitespace_or_comma(*str))
			++str;
		while (*str && !svg_is_whitespace_or_comma(*str) && k < (int)sizeof token - 1)
			token[k++] = *str++;
		token[k] = 0;
		if (!k)
			break;
		out[n++] = svg_parse_length(token, percent, font_size);
	}
	return n;
}

static fz_matrix
svg_run_text(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *root, const svg_state *inherit_state,
	float x, float y, int is_first, int is_last)
{
	svg_state local_state;
	fz_xml *node;
	fz_matrix trm;
	int cif, cil;
	char *text;
	float xs[SVG_MAX_GLYPH_POSITIONS], ys[SVG_MAX_GLYPH_POSITIONS];
	int nx = 0, ny = 0, glyph = 0;

	char *x_att = fz_xml_att(root, "x");
	char *y_att = fz_xml_att(root, "y");
	char *dx_att = fz_xml_att(root, "dx");
	char *dy_att = fz_xml_att(root, "dy");

	svg_begin_state(ctx, &local_state, inherit_state);
	fz_try(ctx)
	{
		svg_parse_common(ctx, doc, root, &local_state);

		trm = fz_scale(local_state.fontsize, -local_state.fontsize);
		trm.e = x;
		trm.f = y;

		if (x_att) nx = svg_parse_position_list(x_att, xs, local_state.viewbox_w, local_state.fontsize);
		if (y_att) ny = svg_parse_position_list(y_att, ys, local_state.viewbox_h, local_state.fontsize);
		if (nx > 0) trm.e = xs[0];
		if (ny > 0) trm.f = ys[0];

		if (dx_att) trm.e += svg_parse_length(dx_att, local_state.viewbox_w, local_state.fontsize);
		if (dy_att) trm.f += svg_parse_length(dy_att, local_state.viewbox_h, local_state.fontsize);

		cif = is_first;
		for (node = fz_xml_down(root); node; node = fz_xml_next(node))
		{
			cil = is_last && !fz_xml_next(node);
			text = fz_xml_text(node);
			if (text)
			{
				svg_collapse_whitespace(text, cif, cil);
				/* With a list of positions, each character that has one
				   starts there; the rest follow on from the one before. */
				while (*text && (nx > 1 || ny > 1) && (glyph < nx || glyph < ny))
				{
					char one[8];
					int rune, len = fz_chartorune(&rune, text);
					if (glyph < nx) trm.e = xs[glyph];
					if (glyph < ny) trm.f = ys[glyph];
					if (glyph == 0 && dx_att) trm.e += svg_parse_length(dx_att, local_state.viewbox_w, local_state.fontsize);
					if (glyph == 0 && dy_att) trm.f += svg_parse_length(dy_att, local_state.viewbox_h, local_state.fontsize);
					memcpy(one, text, len);
					one[len] = 0;
					trm = svg_run_text_string(ctx, dev, trm, one, &local_state);
					text += len;
					++glyph;
				}
				if (*text)
					trm = svg_run_text_string(ctx, dev, trm, text, &local_state);
			}
			else if (fz_xml_is_tag(node, "tspan"))
				trm = svg_run_text(ctx, dev, doc, node, &local_state, trm.e, trm.f, cif, cil);
			else if (fz_xml_is_tag(node, "textPath"))
				trm = svg_run_text(ctx, dev, doc, node, &local_state, trm.e, trm.f, cif, cil);
			cif = 0;
		}
	}
	fz_always(ctx)
		svg_end_state(ctx, &local_state);
	fz_catch(ctx)
		fz_rethrow(ctx);

	return trm;
}

/*
	clip-path="url(#id)" naming a <clipPath>: clip to its first shape (a
	path, rect, circle, ellipse or polygon). That covers what plotting
	libraries write -- matplotlib clips each axes' lines and bars to one
	rectangle -- though not a union of several shapes. The shape is in the
	user space of the clipped element, the element's own transform included.
	Returns 1 when a clip was pushed.
*/
static int
svg_push_clip(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *node, const svg_state *state)
{
	char buf[256], id[200];
	const char *style = fz_xml_att(node, "style");
	const char *value = svg_prop(node, style, "clip-path", buf, sizeof buf);
	const char *units, *rule, *end;
	fz_xml *clip, *shape;
	fz_matrix ctm;
	fz_path *path = NULL;
	int even_odd;

	if (!value || strncmp(value, "url(", 4))
		return 0;
	value += 4;
	while (svg_is_whitespace(*value) || *value == '\'' || *value == '"')
		++value;
	if (*value != '#')
		return 0;
	++value;
	end = value;
	while (*end && *end != ')' && *end != '\'' && *end != '"' && !svg_is_whitespace(*end))
		++end;
	if (end == value || end - value >= (int)sizeof id)
		return 0;
	memcpy(id, value, end - value);
	id[end - value] = 0;

	clip = fz_tree_lookup(ctx, doc->idmap, id);
	if (!clip || !fz_xml_is_tag(clip, "clipPath"))
		return 0;
	units = fz_xml_att(clip, "clipPathUnits");
	if (units && !strcmp(units, "objectBoundingBox"))
		return 0; /* would need the element's bounds */

	ctm = state->transform;
	if (fz_xml_att(node, "transform"))
		ctm = svg_parse_transform(ctx, doc, fz_xml_att(node, "transform"), ctm);
	if (fz_xml_att(clip, "transform"))
		ctm = svg_parse_transform(ctx, doc, fz_xml_att(clip, "transform"), ctm);

	for (shape = fz_xml_down(clip); shape; shape = fz_xml_next(shape))
	{
		if (fz_xml_is_tag(shape, "path") && fz_xml_att(shape, "d"))
		{
			path = fz_new_path(ctx);
			fz_try(ctx)
				svg_parse_path_data(ctx, path, fz_xml_att(shape, "d"));
			fz_catch(ctx)
			{
				fz_drop_path(ctx, path);
				fz_rethrow(ctx);
			}
		}
		else if (fz_xml_is_tag(shape, "rect"))
		{
			const char *a;
			float x = 0, y = 0, w = 0, h = 0;
			if ((a = fz_xml_att(shape, "x"))) x = svg_parse_length(a, state->viewbox_w, state->fontsize);
			if ((a = fz_xml_att(shape, "y"))) y = svg_parse_length(a, state->viewbox_h, state->fontsize);
			if ((a = fz_xml_att(shape, "width"))) w = svg_parse_length(a, state->viewbox_w, state->fontsize);
			if ((a = fz_xml_att(shape, "height"))) h = svg_parse_length(a, state->viewbox_h, state->fontsize);
			path = fz_new_path(ctx);
			fz_try(ctx)
				fz_rectto(ctx, path, x, y, x + w, y + h);
			fz_catch(ctx)
			{
				fz_drop_path(ctx, path);
				fz_rethrow(ctx);
			}
		}
		else if (fz_xml_is_tag(shape, "circle") || fz_xml_is_tag(shape, "ellipse"))
		{
			const char *a;
			float cx = 0, cy = 0, rx = 0, ry = 0;
			if ((a = fz_xml_att(shape, "cx"))) cx = svg_parse_length(a, state->viewbox_w, state->fontsize);
			if ((a = fz_xml_att(shape, "cy"))) cy = svg_parse_length(a, state->viewbox_h, state->fontsize);
			if ((a = fz_xml_att(shape, "r"))) rx = ry = svg_parse_length(a, state->viewbox_size, state->fontsize);
			if ((a = fz_xml_att(shape, "rx"))) rx = svg_parse_length(a, state->viewbox_w, state->fontsize);
			if ((a = fz_xml_att(shape, "ry"))) ry = svg_parse_length(a, state->viewbox_h, state->fontsize);
			path = fz_new_path(ctx);
			fz_try(ctx)
				approx_circle(ctx, path, cx, cy, rx, ry);
			fz_catch(ctx)
			{
				fz_drop_path(ctx, path);
				fz_rethrow(ctx);
			}
		}
		else if (fz_xml_is_tag(shape, "polygon"))
			path = svg_parse_polygon_imp(ctx, doc, shape, 1);
		if (path)
			break;
	}
	if (!path)
		return 0;

	rule = fz_xml_att(shape, "clip-rule");
	if (!rule)
		rule = fz_xml_att(clip, "clip-rule");
	even_odd = rule && !strcmp(rule, "evenodd");
	if (fz_xml_att(shape, "transform"))
		ctm = svg_parse_transform(ctx, doc, fz_xml_att(shape, "transform"), ctm);

	fz_try(ctx)
		fz_clip_path(ctx, dev, path, even_odd, ctm, fz_infinite_rect);
	fz_always(ctx)
		fz_drop_path(ctx, path);
	fz_catch(ctx)
		fz_rethrow(ctx);
	return 1;
}

static void
svg_run_element_imp(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *root, const svg_state *state);

static void
svg_run_element(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *root, const svg_state *state)
{
	int clipped = svg_push_clip(ctx, dev, doc, root, state);
	fz_try(ctx)
		svg_run_element_imp(ctx, dev, doc, root, state);
	fz_always(ctx)
		if (clipped)
			fz_pop_clip(ctx, dev);
	fz_catch(ctx)
		fz_rethrow(ctx);
}

static void
svg_run_element_imp(fz_context *ctx, fz_device *dev, svg_document *doc, fz_xml *root, const svg_state *state)
{
	if (fz_xml_is_tag(root, "svg"))
		svg_run_svg(ctx, dev, doc, root, state);

	else if (fz_xml_is_tag(root, "g"))
		svg_run_g(ctx, dev, doc, root, state);

	else if (fz_xml_is_tag(root, "title"))
		;
	else if (fz_xml_is_tag(root, "desc"))
		;

	else if (fz_xml_is_tag(root, "defs"))
		;
	else if (fz_xml_is_tag(root, "symbol"))
		;

	else if (fz_xml_is_tag(root, "use"))
		svg_run_use(ctx, dev, doc, root, state);

	else if (fz_xml_is_tag(root, "path"))
		svg_run_path(ctx, dev, doc, root, state);
	else if (fz_xml_is_tag(root, "rect"))
		svg_run_rect(ctx, dev, doc, root, state);
	else if (fz_xml_is_tag(root, "circle"))
		svg_run_circle(ctx, dev, doc, root, state);
	else if (fz_xml_is_tag(root, "ellipse"))
		svg_run_ellipse(ctx, dev, doc, root, state);
	else if (fz_xml_is_tag(root, "line"))
		svg_run_line(ctx, dev, doc, root, state);
	else if (fz_xml_is_tag(root, "polyline"))
		svg_run_polyline(ctx, dev, doc, root, state);
	else if (fz_xml_is_tag(root, "polygon"))
		svg_run_polygon(ctx, dev, doc, root, state);

	else if (fz_xml_is_tag(root, "image"))
		svg_run_image(ctx, dev, doc, root, state);

	else if (fz_xml_is_tag(root, "text"))
		svg_run_text(ctx, dev, doc, root, state, 0, 0, 1, 1);

	else
	{
		/* ignore unrecognized tags */
	}
}

void
svg_parse_document_bounds(fz_context *ctx, svg_document *doc, fz_xml *root)
{
	char *version_att;
	char *w_att;
	char *h_att;
	char *viewbox_att;
	int version;

	if (!fz_xml_is_tag(root, "svg"))
		fz_throw(ctx, FZ_ERROR_SYNTAX, "expected svg element (found %s)", fz_xml_tag(root));

	version_att = fz_xml_att(root, "version");
	w_att = fz_xml_att(root, "width");
	h_att = fz_xml_att(root, "height");
	viewbox_att = fz_xml_att(root, "viewBox");

	version = 10;
	if (version_att)
		version = fz_atof(version_att) * 10;

	if (version > 12)
		fz_warn(ctx, "svg document version is newer than we support");

	/* If no width or height attributes, then guess from the viewbox */
	if (w_att == NULL && h_att == NULL && viewbox_att != NULL)
	{
		float min_x, min_y, box_w, box_h;
		svg_lex_viewbox(viewbox_att, &min_x, &min_y, &box_w, &box_h);
		doc->width = box_w;
		doc->height = box_h;
	}
	else
	{
		doc->width = DEF_WIDTH;
		if (w_att)
			doc->width = svg_parse_length(w_att, doc->width, DEF_FONTSIZE);

		doc->height = DEF_HEIGHT;
		if (h_att)
			doc->height = svg_parse_length(h_att, doc->height, DEF_FONTSIZE);
	}
}

void
svg_run_document(fz_context *ctx, svg_document *doc, fz_xml *root, fz_device *dev, fz_matrix ctm)
{
	svg_state state;

	svg_parse_document_bounds(ctx, doc, root);

	/* Initial graphics state */
	state.transform = ctm;
	state.stroke = fz_new_stroke_state(ctx);
	state.use_depth = 0;

	state.viewport_w = DEF_WIDTH;
	state.viewport_h = DEF_HEIGHT;

	state.viewbox_w = DEF_WIDTH;
	state.viewbox_h = DEF_HEIGHT;
	state.viewbox_size = sqrtf(DEF_WIDTH*DEF_WIDTH + DEF_HEIGHT*DEF_HEIGHT) / sqrtf(2);

	state.fontsize = 12;

	state.opacity = 1;

	state.fill_rule = 0;

	state.fill_is_set = 1;
	state.fill_color[0] = 0;
	state.fill_color[1] = 0;
	state.fill_color[2] = 0;
	state.fill_opacity = 1;

	state.stroke_is_set = 0;
	state.stroke_color[0] = 0;
	state.stroke_color[1] = 0;
	state.stroke_color[2] = 0;
	state.stroke_opacity = 1;

	fz_strlcpy(state.font_family, "serif", sizeof state.font_family);
	state.is_bold = 0;
	state.is_italic = 0;
	state.text_anchor = 0;
	state.dominant_baseline = 0;

	fz_try(ctx)
	{
		svg_run_svg(ctx, dev, doc, root, &state);
	}
	fz_always(ctx)
	{
		fz_drop_stroke_state(ctx, state.stroke);
	}
	fz_catch(ctx)
	{
		fz_rethrow(ctx);
	}
}
