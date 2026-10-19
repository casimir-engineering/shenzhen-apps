#import "SPDFMacMarkdownRouting.h"

#include <limits.h>
#include <stdlib.h>
#include <sys/stat.h>

@interface SPDFMacMarkdownLinkResolution ()
@property(nonatomic) SPDFMacMarkdownLinkKind kind;
@property(nonatomic, copy, nullable) NSURL* URL;
@property(nonatomic, copy, nullable) NSString* anchor;
@end

@implementation SPDFMacMarkdownLinkResolution
@end

static SPDFMacMarkdownLinkResolution* SPDFMarkdownResolution(SPDFMacMarkdownLinkKind kind,
                                                             NSURL* URL,
                                                             NSString* anchor) {
    SPDFMacMarkdownLinkResolution* result = [SPDFMacMarkdownLinkResolution new];
    result.kind = kind;
    result.URL = URL;
    result.anchor = anchor;
    return result;
}

BOOL spdf_mac_path_is_markdown(NSString* path) {
    return [path.pathExtension caseInsensitiveCompare:@"md"] == NSOrderedSame ||
           [path.pathExtension caseInsensitiveCompare:@"markdown"] == NSOrderedSame ||
           [path.pathExtension caseInsensitiveCompare:@"mdown"] == NSOrderedSame;
}

BOOL spdf_mac_type_is_markdown(UTType* type) {
    if (!type) return NO;
    UTType* markdown = [UTType typeWithIdentifier:@"net.daringfireball.markdown"];
    return [type.identifier isEqualToString:markdown.identifier] ||
           [type.identifier isEqualToString:@"public.markdown"] ||
           [type conformsToType:markdown];
}

NSString* spdf_mac_markdown_heading_slug(NSString* heading) {
    NSString* folded = [[heading ?: @"" lowercaseString]
        stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:NSLocale.currentLocale];
    NSMutableString* slug = [NSMutableString string];
    BOOL pendingDash = NO;
    NSCharacterSet* alphanumeric = NSCharacterSet.alphanumericCharacterSet;
    for (NSUInteger i = 0; i < folded.length; ++i) {
        unichar c = [folded characterAtIndex:i];
        if ([alphanumeric characterIsMember:c]) {
            if (pendingDash && slug.length) [slug appendString:@"-"];
            [slug appendFormat:@"%C", c];
            pendingDash = NO;
        } else if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c] || c == '-' || c == '_') {
            pendingDash = slug.length > 0;
        }
    }
    return slug;
}

static BOOL SPDFPathIsInsideRoot(NSString* path, NSString* root) {
    if (!path.length || !root.length) return NO;
    NSString* prefix = [root hasSuffix:@"/"] ? root : [root stringByAppendingString:@"/"];
    return [path isEqualToString:root] || [path hasPrefix:prefix];
}

static NSString* SPDFRealPath(NSString* path) {
    char resolved[PATH_MAX];
    if (!realpath(path.fileSystemRepresentation, resolved)) return nil;
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:resolved length:strlen(resolved)];
}

static NSString* SPDFDecodedTarget(NSString* rawTarget, BOOL wikiLink) {
    NSString* target = [rawTarget ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (wikiLink) {
        NSRange alias = [target rangeOfString:@"|"];
        if (alias.location != NSNotFound) target = [target substringToIndex:alias.location];
        if (target.length && !target.pathExtension.length && ![target hasPrefix:@"#"])
            target = [target stringByAppendingPathExtension:@"md"];
    }
    return target.stringByRemovingPercentEncoding ?: target;
}

SPDFMacMarkdownLinkResolution* spdf_mac_resolve_markdown_link(NSString* rawTarget,
                                                              NSURL* documentURL,
                                                              BOOL wikiLink) {
    if (!documentURL.isFileURL) return SPDFMarkdownResolution(SPDFMacMarkdownLinkRejected, nil, nil);
    NSString* target = SPDFDecodedTarget(rawTarget, wikiLink);
    if (!target.length) return SPDFMarkdownResolution(SPDFMacMarkdownLinkRejected, nil, nil);

    NSURL* parsed = [NSURL URLWithString:target];
    NSString* scheme = parsed.scheme.lowercaseString;
    if (scheme.length) {
        if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] ||
            [scheme isEqualToString:@"mailto"])
            return SPDFMarkdownResolution(SPDFMacMarkdownLinkExternal, parsed, nil);
        return SPDFMarkdownResolution(SPDFMacMarkdownLinkRejected, nil, nil);
    }

    NSRange hash = [target rangeOfString:@"#"];
    NSString* pathPart = hash.location == NSNotFound ? target : [target substringToIndex:hash.location];
    NSString* anchor = hash.location == NSNotFound ? nil : [target substringFromIndex:hash.location + 1];
    anchor = spdf_mac_markdown_heading_slug(anchor.stringByRemovingPercentEncoding ?: anchor);
    if (!pathPart.length)
        return anchor.length ? SPDFMarkdownResolution(SPDFMacMarkdownLinkAnchor, documentURL, anchor)
                             : SPDFMarkdownResolution(SPDFMacMarkdownLinkRejected, nil, nil);
    if ([pathPart hasPrefix:@"/"] || [pathPart hasPrefix:@"~"])
        return SPDFMarkdownResolution(SPDFMacMarkdownLinkRejected, nil, nil);

    NSString* root = SPDFRealPath(documentURL.URLByDeletingLastPathComponent.path);
    NSString* candidate = [documentURL.URLByDeletingLastPathComponent.path stringByAppendingPathComponent:pathPart];
    NSString* resolved = SPDFRealPath(candidate.stringByStandardizingPath);
    struct stat st;
    if (!root || !resolved || !SPDFPathIsInsideRoot(resolved, root) ||
        lstat(resolved.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode) ||
        !spdf_mac_path_is_markdown(resolved))
        return SPDFMarkdownResolution(SPDFMacMarkdownLinkRejected, nil, nil);
    return SPDFMarkdownResolution(SPDFMacMarkdownLinkDocument, [NSURL fileURLWithPath:resolved], anchor);
}
