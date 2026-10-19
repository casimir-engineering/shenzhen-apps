#pragma once
#import <Cocoa/Cocoa.h>
#import "markdown/SPDFTextDocumentFormats.h"

// The decoders linked by portable/Makefile, not every format advertised by an
// arbitrary MuPDF build. JPEG XR needs HAVE_JPEGXR; RAR needs HAVE_LIBARCHIVE.
// Neither is linked here. Do not claim generic image/data UTIs (HEIC/WebP etc.).
static inline NSArray<NSString*>* SPDFNativeDocumentExtensions(void) {
    static NSArray<NSString*>* extensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        extensions = @[@"pdf", @"md", @"markdown", @"mdown", @"xps", @"oxps", @"epub", @"mobi", @"prc", @"pdb",
            @"fb2", @"docx", @"xlsx", @"pptx", @"hwpx", @"cbz", @"cbt", @"zip", @"tar", @"svg", @"svgz",
            @"png", @"jpg", @"jpeg", @"jpe", @"jfif-tbnl", @"jfif", @"bmp", @"gif", @"tif", @"tiff",
            @"jp2", @"jpx", @"j2k", @"jb2", @"jbig2", @"pnm", @"pam", @"pbm", @"pgm", @"ppm", @"pfm", @"psd"];
    });
    return extensions;
}

// Only the Open panel needs the complete extension catalog. Ordinary path/title
// and drop checks must not build source-language collections on the launch path.
static inline NSArray<NSString*>* SPDFReadableDocumentExtensions(void) {
    static NSArray<NSString*>* extensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableOrderedSet* all = [NSMutableOrderedSet orderedSetWithArray:SPDFNativeDocumentExtensions()];
        [all addObjectsFromArray:SPDFSourceDocumentExtensions()];
        extensions = all.array;
    });
    return extensions;
}

static inline BOOL SPDFReadableDocumentPath(NSString* path) {
    return path.length && ([SPDFNativeDocumentExtensions() containsObject:path.pathExtension.lowercaseString] ||
                           SPDFIsSourceDocumentPath(path));
}

// URL-only and regular-file-only: directory names ending in .pdf are not documents.
// Shared by drop validation and opening, without decoding or starting Collection.
static inline NSArray<NSString*>* SPDFDocumentPathsFromPasteboard(NSPasteboard* pasteboard) {
    NSArray<NSURL*>* urls = [pasteboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    NSMutableOrderedSet<NSString*>* paths = [NSMutableOrderedSet orderedSet];
    for (NSURL* url in urls) {
        NSNumber* regular = nil;
        if (url.isFileURL && SPDFReadableDocumentPath(url.path) &&
            [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil] && regular.boolValue)
            [paths addObject:url.path];
    }
    return paths.array;
}
