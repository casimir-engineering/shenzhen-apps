#import "SPDFMarkdownDiagramInternal.h"

// Vector emitters for mermaid `pie` (circle slices plus a side legend with
// percentages) and `gantt` (day-scaled horizontal bars in section rows with
// date ticks).

SPDFMarkdownDiagramLayout* SPDFMarkdownDiagramLayOutPie(SPDFMarkdownDiagramPie* pie, NSSize contentBox,
                                                        CGFloat fontScale) {
    CGFloat scale = fontScale > 0 ? fontScale : 1;
    NSFont* labelFont = [NSFont systemFontOfSize:11 * scale];
    NSFont* titleFont = [NSFont systemFontOfSize:13 * scale weight:NSFontWeightSemibold];
    CGFloat lineHeight = SPDFMarkdownDiagramLineHeight(labelFont);
    double total = 0;
    for (SPDFMarkdownDiagramPieSlice* slice in pie.slices) total += slice.value;
    if (total <= 0) return nil;

    CGFloat radius = 78 * scale;
    CGFloat margin = 16 * scale;
    CGFloat swatch = 10 * scale;
    CGFloat legendRowHeight = MAX(lineHeight, swatch) + 6 * scale;
    CGFloat legendWidth = 0;
    NSMutableArray<NSString*>* legendTexts = [NSMutableArray arrayWithCapacity:pie.slices.count];
    for (SPDFMarkdownDiagramPieSlice* slice in pie.slices) {
        NSString* text = [NSString stringWithFormat:@"%@ — %.1f%%", slice.label, slice.value / total * 100];
        [legendTexts addObject:text];
        legendWidth = MAX(legendWidth, SPDFMarkdownDiagramMeasureText(text, labelFont, 260 * scale).width);
    }
    legendWidth += swatch + 8 * scale;
    CGFloat titleHeight = pie.title.length
        ? SPDFMarkdownDiagramMeasureText(pie.title, titleFont, 400 * scale).height + 10 * scale
        : 0;
    CGFloat legendHeight = pie.slices.count * legendRowHeight;
    CGFloat bodyHeight = MAX(2 * radius, legendHeight);
    NSSize naturalSize = NSMakeSize(margin * 3 + 2 * radius + legendWidth, margin * 2 + titleHeight + bodyHeight);

    SPDFMarkdownDiagramCanvas* canvas = [SPDFMarkdownDiagramCanvas new];
    if (pie.title.length) {
        [canvas addText:pie.title
                 inRect:NSMakeRect(0, margin * 0.6, naturalSize.width, titleHeight)
                   font:titleFont
                   role:SPDFMarkdownDiagramRoleText
              alignment:NSTextAlignmentCenter];
    }
    NSPoint center = NSMakePoint(margin + radius, margin + titleHeight + bodyHeight / 2);
    // Slices start at 12 o'clock (-90 degrees in the y-down space, where 0 is
    // three o'clock) and sweep clockwise on screen.
    CGFloat startAngle = -90;
    for (NSUInteger index = 0; index < pie.slices.count; ++index) {
        SPDFMarkdownDiagramPieSlice* slice = pie.slices[index];
        CGFloat sweep = (CGFloat)(slice.value / total * 360.0);
        SPDFMarkdownDiagramShape* wedge = [canvas addPieSliceAt:center
                                                         radius:radius
                                                     startAngle:startAngle
                                                          sweep:sweep
                                                           fill:SPDFMarkdownDiagramRampRole(index)
                                                         stroke:SPDFMarkdownDiagramRolePaper
                                                          width:1.5];
        (void)wedge;
        startAngle += sweep;
    }
    CGFloat legendX = margin * 2 + 2 * radius;
    CGFloat legendY = margin + titleHeight + (bodyHeight - legendHeight) / 2;
    for (NSUInteger index = 0; index < pie.slices.count; ++index) {
        [canvas addRect:NSMakeRect(legendX, legendY + (legendRowHeight - swatch) / 2, swatch, swatch)
                 radius:2
                   fill:SPDFMarkdownDiagramRampRole(index)
                 stroke:SPDFMarkdownDiagramRoleNone
                  width:0];
        [canvas addText:legendTexts[index]
                 inRect:NSMakeRect(legendX + swatch + 8 * scale, legendY + (legendRowHeight - lineHeight) / 2,
                                   legendWidth, lineHeight)
                   font:labelFont
                   role:SPDFMarkdownDiagramRoleText
              alignment:NSTextAlignmentLeft];
        legendY += legendRowHeight;
    }
    return SPDFMarkdownDiagramFinishLayout(canvas, naturalSize, contentBox);
}

// --- gantt ------------------------------------------------------------------

static NSString* SPDFGanttTickLabel(NSDate* epoch, NSInteger day) {
    static NSDateFormatter* formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      formatter = [NSDateFormatter new];
      formatter.dateFormat = @"MM-dd";
      formatter.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
      formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [formatter stringFromDate:[epoch dateByAddingTimeInterval:(NSTimeInterval)day * 86400.0]];
}

SPDFMarkdownDiagramLayout* SPDFMarkdownDiagramLayOutGantt(SPDFMarkdownDiagramGantt* gantt, NSSize contentBox,
                                                          CGFloat fontScale) {
    CGFloat scale = fontScale > 0 ? fontScale : 1;
    NSFont* labelFont = [NSFont systemFontOfSize:11 * scale];
    NSFont* smallFont = [NSFont systemFontOfSize:9.5 * scale];
    NSFont* sectionFont = [NSFont systemFontOfSize:11 * scale weight:NSFontWeightSemibold];
    NSFont* titleFont = [NSFont systemFontOfSize:13 * scale weight:NSFontWeightSemibold];
    CGFloat lineHeight = SPDFMarkdownDiagramLineHeight(labelFont);
    if (!gantt.taskCount || !gantt.epoch) return nil;

    NSInteger minimumDay = NSIntegerMax;
    NSInteger maximumDay = NSIntegerMin;
    CGFloat nameWidth = 0;
    for (SPDFMarkdownDiagramGanttSection* section in gantt.sections) {
        nameWidth = MAX(nameWidth, SPDFMarkdownDiagramMeasureText(section.name, sectionFont, 220 * scale).width);
        for (SPDFMarkdownDiagramGanttTask* task in section.tasks) {
            minimumDay = MIN(minimumDay, task.startDay);
            maximumDay = MAX(maximumDay, task.endDay);
            nameWidth = MAX(nameWidth, SPDFMarkdownDiagramMeasureText(task.name, labelFont, 220 * scale).width);
        }
    }
    NSInteger spanDays = MAX(1, maximumDay - minimumDay);
    if (spanDays > 3660) return nil;
    CGFloat margin = 14 * scale;
    CGFloat labelColumn = MIN(230 * scale, nameWidth + 16 * scale);
    // The chart column takes the width the page actually offers rather than a
    // fixed ceiling. A 60-day gantt wants 1560pt at its natural 26pt/day; the
    // old MIN(520pt) pinned it there, and the fit factor only ever shrinks a
    // diagram, never grows one -- so on a landscape sheet the chart kept its
    // portrait size and left the rest of the page empty. Bounded by what the
    // data needs (a one-week chart stretched across a wide sheet is a sparse
    // ribbon, not a better chart) and by the dimension budget, which would drop
    // the figure entirely. The tick cadence below adapts to the wider day.
    CGFloat naturalChart = (CGFloat)spanDays * 26 * scale;
    CGFloat roomForChart = contentBox.width > 0 ? contentBox.width - margin * 2 - labelColumn : 520 * scale;
    CGFloat chartCeiling = SPDFMarkdownDiagramMaximumDimension - margin * 2 - labelColumn;
    CGFloat chartWidth = MAX(180 * scale, MIN(naturalChart, MIN(roomForChart, chartCeiling)));
    CGFloat dayWidth = chartWidth / (CGFloat)spanDays;
    CGFloat rowHeight = lineHeight + 10 * scale;
    CGFloat titleHeight = gantt.title.length
        ? SPDFMarkdownDiagramMeasureText(gantt.title, titleFont, 400 * scale).height + 10 * scale
        : 0;
    NSUInteger rows = gantt.taskCount + gantt.sections.count;
    CGFloat axisHeight = lineHeight + 8 * scale;
    NSSize naturalSize = NSMakeSize(margin * 2 + labelColumn + chartWidth,
                                    margin * 2 + titleHeight + rows * rowHeight + axisHeight);
    // Tick cadence: the smallest of 1/2/7/14/30/90/365 days spacing >= 46pt.
    NSInteger tickStep = 365;
    for (NSNumber* candidate in @[ @1, @2, @7, @14, @30, @90 ]) {
        if (dayWidth * candidate.integerValue >= 46 * scale) {
            tickStep = candidate.integerValue;
            break;
        }
    }

    SPDFMarkdownDiagramCanvas* canvas = [SPDFMarkdownDiagramCanvas new];
    if (gantt.title.length) {
        [canvas addText:gantt.title
                 inRect:NSMakeRect(0, margin * 0.6, naturalSize.width, titleHeight)
                   font:titleFont
                   role:SPDFMarkdownDiagramRoleText
              alignment:NSTextAlignmentCenter];
    }
    CGFloat chartX = margin + labelColumn;
    CGFloat topY = margin + titleHeight;
    CGFloat chartBottom = topY + rows * rowHeight;
    // Day grid + tick labels.
    for (NSInteger day = 0; day <= spanDays; day += tickStep) {
        CGFloat x = chartX + day * dayWidth;
        SPDFMarkdownDiagramShape* tick = [canvas addLineFrom:NSMakePoint(x, topY)
                                                          to:NSMakePoint(x, chartBottom)
                                                      stroke:SPDFMarkdownDiagramRoleNodeStroke
                                                       width:1
                                                        dash:0];
        tick.strokeAlpha = 0.6;
        [canvas addText:SPDFGanttTickLabel(gantt.epoch, minimumDay + day)
                 inRect:NSMakeRect(x - 30 * scale, chartBottom + 4 * scale, 60 * scale, lineHeight)
                   font:smallFont
                   role:SPDFMarkdownDiagramRoleSecondary
              alignment:NSTextAlignmentCenter];
    }
    CGFloat y = topY;
    for (SPDFMarkdownDiagramGanttSection* section in gantt.sections) {
        // Section band across the full row for orientation.
        SPDFMarkdownDiagramShape* band =
            [canvas addRect:NSMakeRect(margin, y, naturalSize.width - 2 * margin, rowHeight)
                     radius:0
                       fill:SPDFMarkdownDiagramRoleNodeFill
                     stroke:SPDFMarkdownDiagramRoleNone
                      width:0];
        band.fillAlpha = 0.7;
        [canvas addText:section.name.length ? section.name : @"Tasks"
                 inRect:NSMakeRect(margin + 2 * scale, y + 5 * scale, labelColumn, lineHeight)
                   font:sectionFont
                   role:SPDFMarkdownDiagramRoleText
              alignment:NSTextAlignmentLeft];
        y += rowHeight;
        for (SPDFMarkdownDiagramGanttTask* task in section.tasks) {
            [canvas addText:task.name
                     inRect:NSMakeRect(margin + 8 * scale, y + 5 * scale, MAX(1, labelColumn - 10 * scale),
                                       lineHeight)
                       font:labelFont
                       role:task.done ? SPDFMarkdownDiagramRoleSecondary : SPDFMarkdownDiagramRoleText
                  alignment:NSTextAlignmentLeft];
            CGFloat barX = chartX + (task.startDay - minimumDay) * dayWidth;
            CGFloat barWidth = MAX(4 * scale, (task.endDay - task.startDay) * dayWidth);
            SPDFMarkdownDiagramRole role = task.critical ? SPDFMarkdownDiagramRoleCritical
                : task.done                              ? SPDFMarkdownDiagramRoleSecondary
                : task.active                            ? SPDFMarkdownDiagramRoleRamp1
                                                         : SPDFMarkdownDiagramRoleAccent;
            SPDFMarkdownDiagramShape* bar =
                [canvas addRect:NSMakeRect(barX, y + 3 * scale, barWidth, rowHeight - 6 * scale)
                         radius:3 * scale
                           fill:role
                         stroke:role
                          width:1];
            bar.fillAlpha = task.done ? 0.45 : 0.85;
            y += rowHeight;
        }
    }
    return SPDFMarkdownDiagramFinishLayout(canvas, naturalSize, contentBox);
}
