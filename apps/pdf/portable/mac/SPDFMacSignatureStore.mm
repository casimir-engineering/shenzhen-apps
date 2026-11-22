#import "SPDFMacSignatureStore.h"
#import "SPDFMacStateDirectory.h"
#import "SPDFMacSupport.h"

#include <sys/stat.h>

NSBezierPath* SPDFSignatureBezierPath(NSArray<NSString*>* paths) {
    NSBezierPath* path = [NSBezierPath bezierPath];
    path.windingRule = NSWindingRuleNonZero;
    for (NSString* source in paths) {
        NSScanner* scanner = [NSScanner scannerWithString:source];
        scanner.charactersToBeSkipped = [NSCharacterSet characterSetWithCharactersInString:@" ,\n\t"];
        NSCharacterSet* commands = [NSCharacterSet characterSetWithCharactersInString:@"MLCQZ"];
        NSPoint current = NSZeroPoint;
        while (!scanner.isAtEnd) {
            NSString* command = nil;
            if (![scanner scanCharactersFromSet:commands intoString:&command] || command.length == 0) break;
            for (NSUInteger k = 0; k < command.length; ++k) {
                unichar c = [command characterAtIndex:k];
                if (c == 'Z') { [path closePath]; continue; }
                int need = c == 'C' ? 6 : c == 'Q' ? 4 : 2;
                double v[6] = {0};
                for (int i = 0; i < need; ++i)
                    if (![scanner scanDouble:&v[i]]) return path;
                if (c == 'M') [path moveToPoint:NSMakePoint(v[0], v[1])];
                else if (c == 'L') [path lineToPoint:NSMakePoint(v[0], v[1])];
                else if (c == 'C')
                    [path curveToPoint:NSMakePoint(v[4], v[5]) controlPoint1:NSMakePoint(v[0], v[1])
                          controlPoint2:NSMakePoint(v[2], v[3])];
                else {
                    NSPoint q = NSMakePoint(v[0], v[1]), end = NSMakePoint(v[2], v[3]);
                    [path curveToPoint:end
                         controlPoint1:NSMakePoint(current.x + 2.0 / 3.0 * (q.x - current.x),
                                                   current.y + 2.0 / 3.0 * (q.y - current.y))
                         controlPoint2:NSMakePoint(end.x + 2.0 / 3.0 * (q.x - end.x), end.y + 2.0 / 3.0 * (q.y - end.y))];
                }
                current = c == 'C' ? NSMakePoint(v[4], v[5]) : c == 'Q' ? NSMakePoint(v[2], v[3]) : NSMakePoint(v[0], v[1]);
            }
        }
    }
    return path;
}

@implementation SPDFMacSignature
- (void)getRGB:(float[3])rgb {
    if (self.ink == 1) { rgb[0] = 0.08f; rgb[1] = 0.22f; rgb[2] = 0.62f; }
    else { rgb[0] = 0.0f; rgb[1] = 0.0f; rgb[2] = 0.0f; }
}
- (NSColor*)inkColor {
    float rgb[3];
    [self getRGB:rgb];
    return [NSColor colorWithSRGBRed:rgb[0] green:rgb[1] blue:rgb[2] alpha:1];
}
- (void)drawInRect:(NSRect)rect flipped:(BOOL)flipped alpha:(CGFloat)alpha {
    if (NSIsEmptyRect(rect) || self.aspect <= 0) return;
    if (self.png.length) {
        NSImage* image = [[NSImage alloc] initWithData:self.png];
        [image drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:alpha
           respectFlipped:YES hints:nil];
        return;
    }
    NSBezierPath* path = [SPDFSignatureBezierPath(self.paths) copy];
    CGFloat scale = NSHeight(rect);
    NSAffineTransform* t = [NSAffineTransform transform];
    if (flipped) {
        [t translateXBy:NSMinX(rect) yBy:NSMinY(rect)];
        [t scaleXBy:NSWidth(rect) / MAX(0.01, self.aspect) yBy:scale];
    } else {
        [t translateXBy:NSMinX(rect) yBy:NSMaxY(rect)];
        [t scaleXBy:NSWidth(rect) / MAX(0.01, self.aspect) yBy:-scale];
    }
    [path transformUsingAffineTransform:t];
    [[self.inkColor colorWithAlphaComponent:alpha] setFill];
    [path fill];
}
- (NSImage*)thumbnailWithHeight:(CGFloat)height {
    CGFloat width = MIN(height * 6.0, MAX(height, height * self.aspect));
    NSSize size = NSMakeSize(ceil(width), ceil(height));
    return [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect bounds) {
      CGFloat h = MIN(NSHeight(bounds), NSWidth(bounds) / MAX(0.01, self.aspect));
      NSRect fit = NSMakeRect(0, (NSHeight(bounds) - h) / 2, h * self.aspect, h);
      [self drawInRect:fit flipped:NO alpha:1];
      return YES;
    }];
}
@end

@implementation SPDFMacSignatureStore {
    NSMutableArray<SPDFMacSignature*>* _signatures;
    NSMutableDictionary* _detailsFile;
    NSTimeInterval _indexStamp;
    NSTimeInterval _detailsStamp;
}

+ (instancetype)sharedStore {
    static SPDFMacSignatureStore* store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [SPDFMacSignatureStore new]; });
    return store;
}

- (NSString*)directory {
    spdf_mac_support_directory();  // creates the state folder itself
    NSString* folder = [SPDFMacStateDirectoryPath() stringByAppendingPathComponent:@"FillSign"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions : @0700} error:nil];
    chmod(folder.fileSystemRepresentation, 0700);
    return folder;
}

- (NSString*)pathFor:(NSString*)name {
    return [[self directory] stringByAppendingPathComponent:name];
}

static NSTimeInterval SPDFFileStamp(NSString* path) {
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) return 0;
    return (NSTimeInterval)st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec / 1e9 + (NSTimeInterval)st.st_size * 1e-12;
}

static BOOL SPDFWritePrivate(NSData* data, NSString* path, NSError** error) {
    NSString* temp = [path stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
    if (![data writeToFile:temp options:0 error:error]) return NO;
    chmod(temp.fileSystemRepresentation, 0600);
    if (rename(temp.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        unlink(temp.fileSystemRepresentation);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    return YES;
}

static id SPDFReadJSON(NSString* path) {
    NSData* data = [NSData dataWithContentsOfFile:path];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
}

- (void)reloadIfChanged {
    NSString* index = [self pathFor:@"index.json"];
    NSTimeInterval stamp = SPDFFileStamp(index);
    if (_signatures && stamp == _indexStamp) return;
    _indexStamp = stamp;
    _signatures = [NSMutableArray array];
    NSArray* entries = SPDFReadJSON(index);
    if (![entries isKindOfClass:NSArray.class]) return;
    for (NSDictionary* entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString* identifier = entry[@"id"];
        if (![identifier isKindOfClass:NSString.class] || !identifier.length || [identifier containsString:@"-"])
            continue;
        SPDFMacSignature* signature = [SPDFMacSignature new];
        signature.identifier = identifier;
        signature.initials = [entry[@"kind"] isEqual:@"initials"];
        signature.source = [entry[@"source"] isKindOfClass:NSString.class] ? entry[@"source"] : @"drawn";
        signature.ink = [entry[@"ink"] isEqual:@"blue"] ? 1 : 0;
        signature.aspect = [entry[@"aspect"] doubleValue];
        signature.created = [NSDate dateWithTimeIntervalSince1970:[entry[@"created"] doubleValue]];
        signature.lastUsed = [NSDate dateWithTimeIntervalSince1970:[entry[@"lastUsed"] doubleValue]];
        if ([signature.source isEqual:@"picture"]) {
            signature.png = [NSData dataWithContentsOfFile:[self pathFor:[identifier stringByAppendingPathExtension:@"png"]]];
            if (!signature.png.length) continue;
        } else {
            NSArray* paths = SPDFReadJSON([self pathFor:[identifier stringByAppendingPathExtension:@"json"]]);
            if (![paths isKindOfClass:NSArray.class] || !paths.count) continue;
            signature.paths = paths;
        }
        if (signature.aspect > 0.01) [_signatures addObject:signature];
    }
}

- (void)writeIndex {
    NSMutableArray* entries = [NSMutableArray array];
    for (SPDFMacSignature* s in _signatures)
        [entries addObject:@{
            @"id" : s.identifier,
            @"kind" : s.initials ? @"initials" : @"signature",
            @"source" : s.source ?: @"drawn",
            @"ink" : s.ink == 1 ? @"blue" : @"black",
            @"aspect" : @(s.aspect),
            @"created" : @(s.created.timeIntervalSince1970),
            @"lastUsed" : @(s.lastUsed.timeIntervalSince1970)
        }];
    NSData* data = [NSJSONSerialization dataWithJSONObject:entries options:NSJSONWritingPrettyPrinted error:nil];
    NSString* index = [self pathFor:@"index.json"];
    if (data && SPDFWritePrivate(data, index, NULL)) _indexStamp = SPDFFileStamp(index);
}

- (NSArray<SPDFMacSignature*>*)signaturesForInitials:(BOOL)initials {
    [self reloadIfChanged];
    NSMutableArray* found = [NSMutableArray array];
    for (SPDFMacSignature* s in _signatures)
        if (s.initials == initials) [found addObject:s];
    [found sortUsingComparator:^NSComparisonResult(SPDFMacSignature* a, SPDFMacSignature* b) {
      return [b.lastUsed compare:a.lastUsed];
    }];
    return found;
}

- (SPDFMacSignature*)lastUsedForInitials:(BOOL)initials {
    return [self signaturesForInitials:initials].firstObject;
}

- (SPDFMacSignature*)signatureWithIdentifier:(NSString*)identifier {
    [self reloadIfChanged];
    for (SPDFMacSignature* s in _signatures)
        if ([s.identifier isEqual:identifier]) return s;
    return nil;
}

- (BOOL)saveSignature:(SPDFMacSignature*)signature error:(NSError**)error {
    [self reloadIfChanged];
    NSData* body = signature.png.length
                       ? signature.png
                       : [NSJSONSerialization dataWithJSONObject:signature.paths ?: @[] options:0 error:error];
    NSString* file = [signature.identifier stringByAppendingPathExtension:signature.png.length ? @"png" : @"json"];
    if (!body || !SPDFWritePrivate(body, [self pathFor:file], error)) return NO;
    if (!signature.created) signature.created = NSDate.date;
    if (!signature.lastUsed) signature.lastUsed = NSDate.date;
    [_signatures removeObject:[self signatureWithIdentifier:signature.identifier] ?: signature];
    [_signatures addObject:signature];
    [self writeIndex];
    return YES;
}

- (void)removeSignature:(SPDFMacSignature*)signature {
    [self reloadIfChanged];
    SPDFMacSignature* stored = [self signatureWithIdentifier:signature.identifier];
    if (!stored) return;
    [_signatures removeObject:stored];
    [self writeIndex];
    for (NSString* ext in @[ @"json", @"png" ])
        unlink([self pathFor:[stored.identifier stringByAppendingPathExtension:ext]].fileSystemRepresentation);
}

- (void)markUsed:(SPDFMacSignature*)signature {
    SPDFMacSignature* stored = [self signatureWithIdentifier:signature.identifier];
    if (!stored) return;
    stored.lastUsed = NSDate.date;
    signature.lastUsed = stored.lastUsed;
    [self writeIndex];
}

#pragma mark - My Details

- (NSMutableDictionary*)detailsFile {
    NSString* path = [self pathFor:@"details.json"];
    NSTimeInterval stamp = SPDFFileStamp(path);
    if (_detailsFile && stamp == _detailsStamp) return _detailsFile;
    _detailsStamp = stamp;
    NSMutableDictionary* file = SPDFReadJSON(path);
    _detailsFile = [file isKindOfClass:NSDictionary.class] ? file : [NSMutableDictionary dictionary];
    return _detailsFile;
}

- (void)writeDetailsFile {
    NSData* data = [NSJSONSerialization dataWithJSONObject:_detailsFile ?: @{} options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    NSString* path = [self pathFor:@"details.json"];
    if (data && SPDFWritePrivate(data, path, NULL)) _detailsStamp = SPDFFileStamp(path);
}

- (NSDictionary<NSString*, NSString*>*)details {
    NSDictionary* details = [self detailsFile][@"details"];
    return [details isKindOfClass:NSDictionary.class] ? details : @{};
}

- (void)setDetails:(NSDictionary<NSString*, NSString*>*)details {
    [self detailsFile][@"details"] = details ?: @{};
    [self writeDetailsFile];
}

- (NSArray<NSString*>*)savedTexts {
    NSArray* texts = [self detailsFile][@"savedTexts"];
    return [texts isKindOfClass:NSArray.class] ? texts : @[];
}

- (void)addSavedText:(NSString*)text {
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) return;
    NSMutableArray* texts = [[self savedTexts] mutableCopy];
    [texts removeObject:text];
    [texts insertObject:text atIndex:0];
    while (texts.count > 20) [texts removeLastObject];
    [self detailsFile][@"savedTexts"] = texts;
    [self writeDetailsFile];
}

- (BOOL)formHintSeen {
    return [[self detailsFile][@"formHintSeen"] boolValue];
}

- (void)setFormHintSeen:(BOOL)seen {
    [self detailsFile][@"formHintSeen"] = @(seen);
    [self writeDetailsFile];
}
@end
