#import "SPDFMacCollectionCompare.h"

@implementation SPDFCollectionPagePair
@end
@implementation SPDFCollectionComparison
@end

NSArray<NSArray<NSNumber*>*>* SPDFCollectionAlignPages(NSArray<NSString*>* oldKeys,
                                                     NSArray<NSString*>* newKeys) {
    NSMutableArray* pairs = [NSMutableArray array];
    NSMutableDictionary<NSString*,NSMutableArray<NSNumber*>*>* positions[2] = {
        [NSMutableDictionary dictionary], [NSMutableDictionary dictionary]};
    for (NSUInteger side = 0; side < 2; side++) {
        NSArray* keys = side ? newKeys : oldKeys;
        for (NSUInteger i = 0; i < keys.count; i++) {
            if (!positions[side][keys[i]]) positions[side][keys[i]] = [NSMutableArray array];
            [positions[side][keys[i]] addObject:@(i)];
        }
    }
    auto nextOccurrence = [](NSArray<NSNumber*>* entries, NSUInteger minimum) {
        NSUInteger lo = 0, hi = entries.count;
        while (lo < hi) {
            NSUInteger mid = lo+(hi-lo)/2;
            if (entries[mid].unsignedIntegerValue < minimum) lo = mid+1; else hi = mid;
        }
        return lo < entries.count ? entries[lo].unsignedIntegerValue : NSNotFound;
    };
    NSUInteger a = 0, b = 0;
    while (a < oldKeys.count || b < newKeys.count) {
        if (a == oldKeys.count) { [pairs addObject:@[@(-1), @(b++)]]; continue; }
        if (b == newKeys.count) { [pairs addObject:@[@(a++), @(-1)]]; continue; }
        if ([oldKeys[a] isEqual:newKeys[b]]) { [pairs addObject:@[@(a++), @(b++)]]; continue; }
        // A bounded anchor search avoids the n*m matrix of an ordinary LCS.
        NSUInteger bestA = NSNotFound, bestB = NSNotFound, distance = NSUIntegerMax;
        NSUInteger nextB = nextOccurrence(positions[1][oldKeys[a]], b);
        NSUInteger nextA = nextOccurrence(positions[0][newKeys[b]], a);
        // Exact indexed anchors can bridge an insertion of any length, not
        // only the 64-page neighborhood used for simultaneously edited pages.
        if (nextB != NSNotFound) { bestA = a; bestB = nextB; distance = nextB-b; }
        if (nextA != NSNotFound && nextA-a < distance) { bestA = nextA; bestB = b; distance = nextA-a; }
        for (NSUInteger x = a; x < MIN(oldKeys.count, a + 64); x++) {
            for (NSUInteger y = b; y < MIN(newKeys.count, b + 64); y++) {
                if (x - a + y - b >= distance) continue;
                if ([oldKeys[x] isEqual:newKeys[y]]) { bestA = x; bestB = y; distance = x-a+y-b; }
            }
        }
        if (bestA != NSNotFound) {
            while (a < bestA && b < bestB) [pairs addObject:@[@(a++), @(b++)]];
            while (a < bestA) [pairs addObject:@[@(a++), @(-1)]];
            while (b < bestB) [pairs addObject:@[@(-1), @(b++)]];
        } else [pairs addObject:@[@(a++), @(b++)]];
    }
    return pairs;
}

// Prefix/suffix trimming makes common edits cheap. The remaining LCS has a
// strict cell budget; large unrelated pages fall back to occurrence matching.
static NSString* bodyText(PDFPage* page) {
    NSString* text = page.string ?: @"";
    NSRegularExpression* footer = [NSRegularExpression regularExpressionWithPattern:@"Page [0-9]+ of [0-9]+\\s*$"
                                                                           options:0 error:nil];
    NSTextCheckingResult* match = [footer firstMatchInString:text options:0 range:NSMakeRange(0,text.length)];
    // Generated page counters change on insertion; they are not document edits.
    return match ? [text substringToIndex:match.range.location] : text;
}
static NSArray<NSValue*>* unmatchedWords(PDFPage* page, PDFPage* other) {
    NSString* text = bodyText(page);
    NSString* otherText = bodyText(other);
    NSRegularExpression* words = [NSRegularExpression regularExpressionWithPattern:@"\\S+" options:0 error:nil];
    NSArray<NSTextCheckingResult*>* matches = [words matchesInString:text options:0 range:NSMakeRange(0,text.length)];
    NSArray<NSTextCheckingResult*>* others = [words matchesInString:otherText options:0 range:NSMakeRange(0,otherText.length)];
    NSMutableArray<NSString*>* a = [NSMutableArray array];
    NSMutableArray<NSString*>* b = [NSMutableArray array];
    for (NSTextCheckingResult* match in matches) [a addObject:[text substringWithRange:match.range]];
    for (NSTextCheckingResult* match in others) [b addObject:[otherText substringWithRange:match.range]];
    NSUInteger prefix = 0, suffix = 0;
    while (prefix < MIN(a.count,b.count) && [a[prefix] isEqual:b[prefix]]) prefix++;
    while (suffix < MIN(a.count,b.count)-prefix && [a[a.count-suffix-1] isEqual:b[b.count-suffix-1]]) suffix++;
    NSUInteger n = a.count-prefix-suffix, m = b.count-prefix-suffix;
    NSMutableIndexSet* removed = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(prefix,n)];
    if (n && m && (n+1) <= 2000000/(m+1)) {
        NSMutableData* cells = [NSMutableData dataWithLength:(n+1)*(m+1)*sizeof(uint32_t)];
        uint32_t* dp = (uint32_t*)cells.mutableBytes;
        for (NSUInteger i = n; i-- > 0;) for (NSUInteger j = m; j-- > 0;)
            dp[i*(m+1)+j] = [a[prefix+i] isEqual:b[prefix+j]] ? dp[(i+1)*(m+1)+j+1]+1
                : MAX(dp[(i+1)*(m+1)+j],dp[i*(m+1)+j+1]);
        NSUInteger i = 0, j = 0;
        while (i < n && j < m) {
            if ([a[prefix+i] isEqual:b[prefix+j]]) { [removed removeIndex:prefix+i]; i++; j++; }
            else if (dp[(i+1)*(m+1)+j] >= dp[i*(m+1)+j+1]) i++; else j++;
        }
    } else if (n && m) {
        NSMutableDictionary<NSString*,NSNumber*>* counts = [NSMutableDictionary dictionary];
        for (NSUInteger j = prefix; j < b.count-suffix; j++) counts[b[j]] = @([counts[b[j]] unsignedIntegerValue]+1);
        for (NSUInteger i = prefix; i < a.count-suffix; i++) {
            NSUInteger count = [counts[a[i]] unsignedIntegerValue];
            if (count) { counts[a[i]] = @(count-1); [removed removeIndex:i]; }
        }
    }
    NSMutableArray* rects = [NSMutableArray array];
    [removed enumerateIndexesUsingBlock:^(NSUInteger index, BOOL* stop) {
        for (PDFSelection* line in [[page selectionForRange:matches[index].range] selectionsByLine]) {
            NSRect rect = [line boundsForPage:page];
            if (!NSIsEmptyRect(rect)) [rects addObject:[NSValue valueWithRect:rect]];
        }
        if (rects.count >= 10000) *stop = YES;
    }];
    return rects;
}

// Exported for the loader without exposing raster internals in the public facade.
NSData* SPDFCollectionPagePixels(PDFPage* page) {
    const size_t edge = 384;
    NSMutableData* pixels = [NSMutableData dataWithLength:edge * edge * 4];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, edge, edge, 8, edge * 4, space,
                                                kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, edge, edge));
    CGRect box = [page boundsForBox:kPDFDisplayBoxMediaBox];
    CGContextScaleCTM(context, edge / MAX(1, box.size.width), edge / MAX(1, box.size.height));
    CGContextTranslateCTM(context, -box.origin.x, -box.origin.y);
    [page drawWithBox:kPDFDisplayBoxMediaBox toContext:context];
    CGContextRelease(context);
    return pixels;
}

void SPDFCollectionComparePair(SPDFCollectionPagePair* pair, PDFPage* oldPage, PDFPage* newPage) {
    if (!oldPage || !newPage) {
        pair.removedRects = oldPage ? @[[NSValue valueWithRect:[oldPage boundsForBox:kPDFDisplayBoxMediaBox]]] : @[];
        pair.addedRects = newPage ? @[[NSValue valueWithRect:[newPage boundsForBox:kPDFDisplayBoxMediaBox]]] : @[];
        return;
    }
    NSMutableArray* removed = [unmatchedWords(oldPage, newPage) mutableCopy];
    NSMutableArray* added = [unmatchedWords(newPage, oldPage) mutableCopy];
    NSData* oldPixels = SPDFCollectionPagePixels(oldPage);
    NSData* newPixels = SPDFCollectionPagePixels(newPage);
    if (oldPixels.length && newPixels.length == oldPixels.length) {
        const unsigned char* a = (const unsigned char*)oldPixels.bytes;
        const unsigned char* b = (const unsigned char*)newPixels.bytes;
        // Suppress text pixels in the visual pass: reflow must not turn every
        // unchanged word into a visual deletion/addition. Text has its own LCS.
        BOOL sameText = [bodyText(oldPage) isEqual:bodyText(newPage)];
        NSMutableData* mask = [NSMutableData dataWithLength:384*384];
        unsigned char* ignored = (unsigned char*)mask.mutableBytes;
        for (PDFPage* page in @[oldPage,newPage]) {
            NSRect box = [page boundsForBox:kPDFDisplayBoxMediaBox];
            PDFSelection* selection = [page selectionForRange:NSMakeRange(0,page.string.length)];
            for (PDFSelection* line in selection.selectionsByLine) {
                NSRect rect = [line boundsForPage:page];
                BOOL footerOnly = [line.string rangeOfString:@"Page " options:NSAnchoredSearch].location != NSNotFound &&
                    [line.string containsString:@" of "];
                if (sameText && !footerOnly) continue;
                int left = MAX(0,(int)floor((NSMinX(rect)-NSMinX(box))/MAX(1,box.size.width)*384)-2);
                int right = MIN(384,(int)ceil((NSMaxX(rect)-NSMinX(box))/MAX(1,box.size.width)*384)+2);
                int top = MAX(0,(int)floor((1-(NSMaxY(rect)-NSMinY(box))/MAX(1,box.size.height))*384)-2);
                int bottom = MIN(384,(int)ceil((1-(NSMinY(rect)-NSMinY(box))/MAX(1,box.size.height))*384)+2);
                for (int y = top; y < bottom; y++) for (int x = left; x < right; x++) ignored[y*384+x] = 1;
            }
        }
        BOOL changes[2][32][32] = {};
        for (int row = 0; row < 32; row++) for (int col = 0; col < 32; col++) {
            int counts[2] = {};
            for (int y = row*12; y < (row+1)*12; y++) for (int x = col*12; x < (col+1)*12; x++) {
                if (ignored[y*384+x]) continue;
                int i = (y*384+x)*4;
                if (abs(a[i]-b[i])+abs(a[i+1]-b[i+1])+abs(a[i+2]-b[i+2]) <= 80) continue;
                if (MIN(a[i],MIN(a[i+1],a[i+2])) < 245) counts[0]++;
                if (MIN(b[i],MIN(b[i+1],b[i+2])) < 245) counts[1]++;
            }
            changes[0][row][col] = counts[0] >= 3;
            changes[1][row][col] = counts[1] >= 3;
        }
        // Coalesce tiles into strips; memory is bounded independently of image
        // resolution. Bitmap rows run downward; PDF page coordinates run up.
        for (NSUInteger side = 0; side < 2; side++) for (int row = 0; row < 32; row++) {
            int start = -1;
            for (int col = 0; col <= 32; col++) {
                BOOL differs = col < 32 && changes[side][row][col];
                if (differs && start < 0) start = col;
                if (!differs && start >= 0) {
                    NSRect fraction = NSMakeRect(start/32.0,1-(row+1)/32.0,(col-start)/32.0,1/32.0);
                    PDFPage* page = side ? newPage : oldPage;
                    NSRect box = [page boundsForBox:kPDFDisplayBoxMediaBox];
                    NSRect rect = NSMakeRect(box.origin.x+fraction.origin.x*box.size.width,
                        box.origin.y+fraction.origin.y*box.size.height,
                        fraction.size.width*box.size.width,fraction.size.height*box.size.height);
                    NSMutableArray* destination = side ? added : removed;
                    NSRect previous = [destination.lastObject rectValue];
                    if (destination.count && fabs(previous.origin.x-rect.origin.x) < .01 &&
                        fabs(previous.size.width-rect.size.width) < .01 && fabs(NSMinY(previous)-NSMaxY(rect)) < .01)
                        destination[destination.count-1] = [NSValue valueWithRect:NSUnionRect(previous,rect)];
                    else [destination addObject:[NSValue valueWithRect:rect]];
                    start = -1;
                }
            }
        }
    }
    pair.removedRects = removed;
    pair.addedRects = added;
}
