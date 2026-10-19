#import "SPDFMacStateDirectory.h"
#import "SPDFMacChromeColors.h"
#import "SPDFMacSupport.h"

#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>

NSArray<UTType*>* spdf_document_content_types(void) {
    NSMutableArray<UTType*>* types = [NSMutableArray arrayWithObject:UTTypePDF];
    UTType* markdown = [UTType typeWithIdentifier:@"net.daringfireball.markdown"];
    if (markdown) [types addObject:markdown];
    for (NSString* extension in SPDFReadableDocumentExtensions()) {
        UTType* type = [UTType typeWithFilenameExtension:extension];
        if (type && ![types containsObject:type]) [types addObject:type];
    }
    return types;
}

NSString* spdf_display_label_without_extension(NSString* label) {
    if (!label.length) return @"";
    if (SPDFReadableDocumentPath(label)) return label.stringByDeletingPathExtension;
    if ([label rangeOfString:@"."].location == NSNotFound) return label;
    for (NSString* extension in SPDFReadableDocumentExtensions()) {
        NSString* ext = [@"." stringByAppendingString:extension];
        NSRange range = [label rangeOfString:ext options:NSCaseInsensitiveSearch | NSBackwardsSearch];
        if (range.location == NSNotFound) continue;
        NSUInteger end = range.location + range.length;
        BOOL atEnd = end == label.length;
        BOOL beforeSuffix = !atEnd && ([[NSCharacterSet whitespaceAndNewlineCharacterSet]
                                           characterIsMember:[label characterAtIndex:end]] ||
                                       [label characterAtIndex:end] == '-');
        if (atEnd || beforeSuffix) return [label stringByReplacingCharactersInRange:range withString:@""];
    }
    return label;
}

NSString* spdf_display_name_for_path(NSString* path) {
    NSString* name = path.lastPathComponent;
    return spdf_display_label_without_extension(name);
}

NSString* spdf_display_path_without_extension(NSString* path) {
    if (!path.length) return @"";
    NSString* stem = path.stringByDeletingPathExtension;
    return stem.length && ![stem isEqualToString:path] ? stem : path;
}

static NSArray<NSString*>* spdf_display_components_for_path(NSString* path) {
    if (!path.length) return @[];
    NSMutableArray<NSString*>* components = [NSMutableArray array];
    for (NSString* component in path.stringByStandardizingPath.pathComponents) {
        if (!component.length || [component isEqualToString:@"/"]) continue;
        [components addObject:component];
    }
    if (components.count == 0) return @[];
    NSString* last = spdf_display_label_without_extension(components.lastObject);
    if (last.length) components[components.count - 1] = last;
    return components;
}

static NSString* spdf_display_candidate_for_components(NSArray<NSString*>* components, NSUInteger tailLength,
                                                       NSUInteger leadingCount) {
    if (components.count == 0) return @"";
    tailLength = MIN(tailLength, components.count);
    NSUInteger start = components.count - tailLength;
    NSArray<NSString*>* tail = [components subarrayWithRange:NSMakeRange(start, tailLength)];
    if (tail.count <= 2) return [tail componentsJoinedByString:@"/"];

    NSUInteger visibleLeading = MIN(leadingCount, tail.count - 2);
    NSArray<NSString*>* leading = [tail subarrayWithRange:NSMakeRange(0, visibleLeading)];
    NSString* prefix = [leading componentsJoinedByString:@"/"];
    return [NSString stringWithFormat:@"%@/.../%@", prefix, tail.lastObject];
}

static BOOL spdf_candidates_are_unique(NSArray<NSString*>* candidates) {
    NSMutableSet<NSString*>* seen = [NSMutableSet setWithCapacity:candidates.count];
    for (NSString* candidate in candidates) {
        NSString* key = candidate.lowercaseString ?: @"";
        if ([seen containsObject:key]) return NO;
        [seen addObject:key];
    }
    return YES;
}

static NSArray<NSString*>* spdf_disambiguated_display_names_for_distinct_paths(NSArray<NSString*>* paths);

// The same file open in several tabs is one document: it shares one name, and
// it never counts as a second document needing a longer one. Counting it made
// every same-named document fall back to its full path.
NSArray<NSString*>* spdf_disambiguated_display_names_for_paths(NSArray<NSString*>* paths) {
    NSMutableArray<NSString*>* distinct = [NSMutableArray arrayWithCapacity:paths.count];
    NSMutableDictionary<NSString*, NSNumber*>* slots = [NSMutableDictionary dictionaryWithCapacity:paths.count];
    NSMutableArray<NSNumber*>* slotForPath = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSString* path in paths) {
        NSString* key = path.stringByStandardizingPath ?: path ?: @"";
        if (!slots[key]) { slots[key] = @(distinct.count); [distinct addObject:path ?: @""]; }
        [slotForPath addObject:slots[key]];
    }
    NSArray<NSString*>* names = spdf_disambiguated_display_names_for_distinct_paths(distinct);
    NSMutableArray<NSString*>* result = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSNumber* slot in slotForPath) [result addObject:names[slot.unsignedIntegerValue]];
    return result;
}

static NSArray<NSString*>* spdf_disambiguated_display_names_for_distinct_paths(NSArray<NSString*>* paths) {
    if (paths.count == 0) return @[];

    NSMutableArray<NSArray<NSString*>*>* componentsByIndex = [NSMutableArray arrayWithCapacity:paths.count];
    NSMutableArray<NSString*>* result = [NSMutableArray arrayWithCapacity:paths.count];
    NSMutableDictionary<NSString*, NSMutableArray<NSNumber*>*>* groups = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < paths.count; ++i) {
        NSArray<NSString*>* components = spdf_display_components_for_path(paths[i]);
        NSString* base = components.lastObject ?: spdf_display_name_for_path(paths[i]);
        if (!base.length) base = @"";
        [componentsByIndex addObject:components ?: @[]];
        [result addObject:base];
        NSString* key = base.lowercaseString ?: @"";
        if (!groups[key]) groups[key] = [NSMutableArray array];
        [groups[key] addObject:@(i)];
    }

    for (NSString* key in groups) {
        NSArray<NSNumber*>* indexes = groups[key];
        if (indexes.count <= 1) continue;

        NSUInteger maxTail = 1;
        for (NSNumber* number in indexes) {
            maxTail = MAX(maxTail, componentsByIndex[number.unsignedIntegerValue].count);
        }

        BOOL resolved = NO;
        for (NSUInteger tailLength = 2; tailLength <= maxTail && !resolved; ++tailLength) {
            NSUInteger maxLeading = tailLength <= 2 ? 1 : tailLength - 2;
            for (NSUInteger leadingCount = 1; leadingCount <= maxLeading; ++leadingCount) {
                NSMutableArray<NSString*>* candidates = [NSMutableArray arrayWithCapacity:indexes.count];
                for (NSNumber* number in indexes) {
                    NSArray<NSString*>* components = componentsByIndex[number.unsignedIntegerValue];
                    [candidates addObject:spdf_display_candidate_for_components(components, tailLength, leadingCount)];
                }
                if (!spdf_candidates_are_unique(candidates)) continue;
                for (NSUInteger i = 0; i < indexes.count; ++i) {
                    result[indexes[i].unsignedIntegerValue] = candidates[i];
                }
                resolved = YES;
                break;
            }
        }

        if (!resolved) {
            for (NSNumber* number in indexes) {
                NSString* fullPath = spdf_display_path_without_extension(paths[number.unsignedIntegerValue]);
                result[number.unsignedIntegerValue] = fullPath.length ? fullPath : result[number.unsignedIntegerValue];
            }
        }
    }

    return result;
}

NSArray<NSDictionary<NSString*, NSString*>*>* spdf_translation_languages(void) {
    static NSArray<NSDictionary<NSString*, NSString*>*>* languages = nil;
    if (languages) return languages;
    languages = @[
        @{@"code" : @"zh", @"name" : @"Chinese (Simplified)"}, @{@"code" : @"en", @"name" : @"English"},
        @{@"code" : @"fr", @"name" : @"French"}, @{@"code" : @"de", @"name" : @"German"},
        @{@"code" : @"es", @"name" : @"Spanish"}, @{@"code" : @"it", @"name" : @"Italian"},
        @{@"code" : @"pt", @"name" : @"Portuguese"}, @{@"code" : @"ru", @"name" : @"Russian"},
        @{@"code" : @"ja", @"name" : @"Japanese"}, @{@"code" : @"ko", @"name" : @"Korean"},
        @{@"code" : @"ar", @"name" : @"Arabic"}, @{@"code" : @"hi", @"name" : @"Hindi"},
        @{@"code" : @"nl", @"name" : @"Dutch"}, @{@"code" : @"pl", @"name" : @"Polish"},
        @{@"code" : @"tr", @"name" : @"Turkish"}, @{@"code" : @"vi", @"name" : @"Vietnamese"},
        @{@"code" : @"id", @"name" : @"Indonesian"}, @{@"code" : @"uk", @"name" : @"Ukrainian"},
        @{@"code" : @"cs", @"name" : @"Czech"}
    ];
    return languages;
}

NSArray<NSDictionary<NSString*, NSString*>*>* spdf_ocr_languages(void) {
    static NSArray<NSDictionary<NSString*, NSString*>*>* languages = nil;
    if (languages) return languages;
    languages = @[
        @{@"code" : @"chi_sim+eng", @"name" : @"Chinese Simplified + English"},
        @{@"code" : @"chi_sim", @"name" : @"Chinese Simplified"},
        @{@"code" : @"chi_tra+eng", @"name" : @"Chinese Traditional + English"},
        @{@"code" : @"chi_tra", @"name" : @"Chinese Traditional"}, @{@"code" : @"eng", @"name" : @"English"},
        // Top 10 most-spoken languages by total speakers (English and Mandarin above).
        @{@"code" : @"hin", @"name" : @"Hindi"}, @{@"code" : @"spa", @"name" : @"Spanish"},
        @{@"code" : @"fra", @"name" : @"French"}, @{@"code" : @"ara", @"name" : @"Arabic"},
        @{@"code" : @"ben", @"name" : @"Bengali"}, @{@"code" : @"por", @"name" : @"Portuguese"},
        @{@"code" : @"rus", @"name" : @"Russian"}, @{@"code" : @"urd", @"name" : @"Urdu"},
        // Large European languages (English, Spanish, French, Portuguese, Russian above).
        @{@"code" : @"deu", @"name" : @"German"}, @{@"code" : @"ita", @"name" : @"Italian"},
        @{@"code" : @"pol", @"name" : @"Polish"}, @{@"code" : @"ukr", @"name" : @"Ukrainian"},
        @{@"code" : @"nld", @"name" : @"Dutch"}, @{@"code" : @"ron", @"name" : @"Romanian"}
    ];
    return languages;
}

NSArray<NSString*>* spdf_ocr_language_components(NSString* language) {
    if (!language.length) return @[];
    NSMutableArray<NSString*>* components = [NSMutableArray array];
    for (NSString* part in [language componentsSeparatedByString:@"+"]) {
        NSString* trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length) [components addObject:trimmed];
    }
    return components;
}

BOOL spdf_ocr_language_uses_extra_traineddata(NSString* language) {
    for (NSString* component in spdf_ocr_language_components(language)) {
        if (![component isEqualToString:@"eng"]) return YES;
    }
    return NO;
}

NSImage* spdf_translate_toolbar_image(void) {
    static NSImage* image = nil;
    if (image) return image;

    if (@available(macOS 11.0, *)) {
        image = [NSImage imageWithSystemSymbolName:@"translate" accessibilityDescription:@"Translate"];
        if (image) {
            [image setTemplate:YES];
            return image;
        }
    }

    image = [NSImage imageWithSize:NSMakeSize(18.0,18.0) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        (void)rect;
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, 0.0, 18.0);
        CGContextScaleCTM(ctx, 18.0 / 24.0, -18.0 / 24.0);
        CGContextSetLineWidth(ctx, 1.9);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        CGContextSetStrokeColorWithColor(ctx, NSColor.blackColor.CGColor);

        CGContextSetLineWidth(ctx, 2.1);
        CGContextBeginPath(ctx);
        CGContextMoveToPoint(ctx, 5.2, 17.8);
        CGContextAddLineToPoint(ctx, 8.0, 7.2);
        CGContextAddLineToPoint(ctx, 10.8, 17.8);
        CGContextMoveToPoint(ctx, 6.2, 14.0);
        CGContextAddLineToPoint(ctx, 9.8, 14.0);
        CGContextStrokePath(ctx);

        CGContextBeginPath(ctx);
        CGContextMoveToPoint(ctx, 13.5, 5.3);
        CGContextAddLineToPoint(ctx, 21.2, 5.3);
        CGContextMoveToPoint(ctx, 17.4, 3.0);
        CGContextAddLineToPoint(ctx, 17.4, 5.3);
        CGContextMoveToPoint(ctx, 15.1, 7.0);
        CGContextAddQuadCurveToPoint(ctx, 17.4, 10.7, 20.0, 7.0);
        CGContextMoveToPoint(ctx, 16.5, 8.8);
        CGContextAddLineToPoint(ctx, 19.8, 12.2);
        CGContextStrokePath(ctx);

        CGContextSetLineWidth(ctx, 1.7);
        CGContextBeginPath(ctx);
        CGContextMoveToPoint(ctx, 14.7, 15.8);
        CGContextAddLineToPoint(ctx, 18.7, 15.8);
        CGContextAddLineToPoint(ctx, 17.0, 14.1);
        CGContextMoveToPoint(ctx, 18.7, 15.8);
        CGContextAddLineToPoint(ctx, 17.0, 17.5);
        CGContextMoveToPoint(ctx, 9.3, 8.1);
        CGContextAddLineToPoint(ctx, 5.3, 8.1);
        CGContextAddLineToPoint(ctx, 7.0, 6.4);
        CGContextMoveToPoint(ctx, 5.3, 8.1);
        CGContextAddLineToPoint(ctx, 7.0, 9.8);
        CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);

        return YES;
    }];
    image.cacheMode=NSImageCacheNever;
    [image setTemplate:YES];
    return image;
}

NSImage* spdf_ocr_toolbar_image(void) {
    static NSImage* image = nil;
    if (image) return image;

    if (@available(macOS 11.0, *)) {
        image = [NSImage imageWithSystemSymbolName:@"doc.text.viewfinder" accessibilityDescription:@"OCR"];
        if (!image) image = [NSImage imageWithSystemSymbolName:@"text.viewfinder" accessibilityDescription:@"OCR"];
        if (image) {
            [image setTemplate:YES];
            return image;
        }
    }

    image = [NSImage imageWithSize:NSMakeSize(18.0,18.0) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        (void)rect;
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        CGContextSetLineWidth(ctx, 1.8);
        CGContextSetStrokeColorWithColor(ctx, NSColor.blackColor.CGColor);
        CGContextStrokeRect(ctx, CGRectMake(2.5, 3.0, 13.0, 12.0));
        CGContextMoveToPoint(ctx, 5.0, 7.0);
        CGContextAddLineToPoint(ctx, 13.0, 7.0);
        CGContextMoveToPoint(ctx, 5.0, 10.0);
        CGContextAddLineToPoint(ctx, 13.0, 10.0);
        CGContextStrokePath(ctx);
        return YES;
    }];
    image.cacheMode=NSImageCacheNever;
    [image setTemplate:YES];
    return image;
}

NSImage* spdf_markdown_font_size_toolbar_image(BOOL larger) {
    static NSImage* images[2] = {nil, nil};
    NSImage* image = images[larger ? 1 : 0];
    if (image) return image;

    // Rendered text instead of the textformat.size.* SF Symbols: those glyphs
    // show only a bare letter, so the pair reads as two mystery "A" buttons.
    // "A−" / "A＋" with a size hierarchy on the letter keeps both the subject
    // and the direction visible in each segment.
    NSString* description = larger ? @"Increase Text Size" : @"Decrease Text Size";
    NSFont* letterFont = [NSFont systemFontOfSize:larger ? 15.0 : 11.0 weight:NSFontWeightMedium];
    NSFont* signFont = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    NSMutableAttributedString* glyphs = [[NSMutableAttributedString alloc]
        initWithString:@"A"
            attributes:@{NSFontAttributeName : letterFont, NSForegroundColorAttributeName : NSColor.blackColor}];
    [glyphs appendAttributedString:[[NSAttributedString alloc]
                                       initWithString:larger ? @"+" : @"−"
                                           attributes:@{
                                               NSFontAttributeName : signFont,
                                               NSForegroundColorAttributeName : NSColor.blackColor
                                           }]];
    NSSize textSize = glyphs.size;
    NSSize imageSize = NSMakeSize(ceil(textSize.width) + 2.0, ceil(textSize.height));
    image = [NSImage imageWithSize:imageSize
                           flipped:NO
                    drawingHandler:^BOOL(NSRect dstRect) {
                      (void)dstRect;
                      [glyphs drawAtPoint:NSMakePoint(1.0, 0.0)];
                      return YES;
                    }];
    [image setTemplate:YES];
    image.accessibilityDescription = description;
    images[larger ? 1 : 0] = image;
    return image;
}

BOOL spdf_is_allowed_external_url(NSURL* url) {
    NSString* scheme = url.scheme.lowercaseString;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] ||
           [scheme isEqualToString:@"mailto"] || [scheme isEqualToString:@"file"];
}

BOOL spdf_zoom_profile_enabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ enabled = getenv("SPDF_ZOOM_PROFILE") != NULL; });
    return enabled;
}

double spdf_zoom_profile_now_ms(void) {
    return CFAbsoluteTimeGetCurrent() * 1000.0;
}

void spdf_zoom_profile_log(NSString* format, ...) {
    if (!spdf_zoom_profile_enabled()) return;
    va_list args;
    va_start(args, format);
    NSString* message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "[zoomprof %.3f] %s\n", CFAbsoluteTimeGetCurrent() * 1000.0, message.UTF8String);
}

// Captured as early as the runtime allows (static initializer at image load)
// so launch-profile timestamps approximate "process entry". Recording one
// double costs nothing, so this runs unconditionally.
static double gSPDFProcessStartMs;
__attribute__((constructor)) static void spdf_launch_profile_capture_process_start(void) {
    gSPDFProcessStartMs = CFAbsoluteTimeGetCurrent() * 1000.0;
}

BOOL spdf_launch_profile_enabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ enabled = getenv("SPDF_LAUNCH_PROFILE") != NULL; });
    return enabled;
}

void spdf_launch_profile_log(NSString* format, ...) {
    if (!spdf_launch_profile_enabled()) return;
    va_list args;
    va_start(args, format);
    NSString* message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    // The absolute timestamp (@...) lets an external harness that recorded
    // the spawn time attribute the pre-constructor segment (dyld page-in,
    // code-signature validation) that the relative timeline cannot see.
    double nowMs = CFAbsoluteTimeGetCurrent() * 1000.0;
    fprintf(stderr, "[launchprof +%.1f @%.1f] %s\n", nowMs - gSPDFProcessStartMs, nowMs, message.UTF8String);
}

// True kernel spawn time (CFAbsoluteTime ms). Unlike the image-load
// constructor timestamp above, this predates dyld page-in and code-signature
// validation, so a launch whose pre-main segment was slow (cold binary
// pages, fresh Gatekeeper assessment) is visible in-process. Falls back to
// the constructor timestamp if the sysctl fails.
double spdf_process_spawn_time_ms(void) {
    static double spawnMs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      struct kinfo_proc info;
      size_t size = sizeof(info);
      int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
      if (sysctl(mib, 4, &info, &size, NULL, 0) == 0 && size >= sizeof(info) &&
          info.kp_proc.p_starttime.tv_sec > 0) {
          double unixMs =
              (double)info.kp_proc.p_starttime.tv_sec * 1000.0 + (double)info.kp_proc.p_starttime.tv_usec / 1000.0;
          spawnMs = unixMs - kCFAbsoluteTimeIntervalSince1970 * 1000.0;
      } else {
          spawnMs = gSPDFProcessStartMs;
      }
    });
    return spawnMs;
}

// Single source of truth for the state directory. SPDF_STATE_DIR redirects it
// (measurement / test launches), so nothing in the app may recompute
// "Application Support/ShenzhenPDF" on its own.
NSString* spdf_mac_support_directory(void) {
    NSString* dir = SPDFMacStateDirectoryPath();
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

BOOL spdf_launch_activation_suppressed(void) {
    static BOOL suppressed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ suppressed = getenv("SPDF_NO_ACTIVATE") != NULL; });
    return suppressed;
}
