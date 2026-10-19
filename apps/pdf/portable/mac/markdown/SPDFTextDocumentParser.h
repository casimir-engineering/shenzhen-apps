#pragma once
#import "SPDFMarkdownParser.h"
#import "SPDFTextDocumentFormats.h"

NS_ASSUME_NONNULL_BEGIN

// No Markdown parsing, front matter, HTML interpretation, resource loading, or
// fence escaping: source code is one literal code block in the existing AST.
static inline SPDFMarkdownDocumentModel* SPDFSourceDocumentModel(NSString* source, NSURL* URL,
                                                                 NSString* language) {
    SPDFMarkdownInlineRun* run = [[SPDFMarkdownInlineRun alloc]
        initWithText:source traits:SPDFMarkdownInlineTraitNone destination:nil];
    SPDFMarkdownBlock* block = [[SPDFMarkdownBlock alloc] initWithKind:SPDFMarkdownBlockKindCode
        blockIndex:0 level:0 orderedStart:1 taskState:-1 tableAlignment:SPDFMarkdownTableAlignmentDefault
        tableColumnCount:0 runs:@[run] children:@[] codeLanguage:language codeInfo:language
        calloutKind:nil calloutTitle:nil];
    return [[SPDFMarkdownDocumentModel alloc] initWithSourceURL:URL frontMatter:@{}
        rawFrontMatter:nil blocks:@[block]];
}

static inline NSString* _Nullable SPDFDecodeSourceDocument(NSData* data, NSError* _Nullable* _Nullable error) {
    const unsigned char* bytes = (const unsigned char*)data.bytes;
    NSStringEncoding encoding = NSUTF8StringEncoding;
    NSUInteger skip = 0;
    if (data.length >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0xfe && bytes[3] == 0xff) {
        encoding = NSUTF32BigEndianStringEncoding; skip = 4;
    } else if (data.length >= 4 && bytes[0] == 0xff && bytes[1] == 0xfe && bytes[2] == 0 && bytes[3] == 0) {
        encoding = NSUTF32LittleEndianStringEncoding; skip = 4;
    } else if (data.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
        encoding = NSUTF16BigEndianStringEncoding; skip = 2;
    } else if (data.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
        encoding = NSUTF16LittleEndianStringEncoding; skip = 2;
    } else if (data.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) {
        skip = 3;
    }
    NSString* source = [[NSString alloc] initWithBytes:bytes ? (const void*)(bytes + skip) : (const void*)"" length:data.length - skip
        encoding:encoding];
    BOOL binary = NO;
    for (NSUInteger i = 0; i < source.length; ++i) {
        unichar c = [source characterAtIndex:i];
        if ((c < 0x20 && c != '\t' && c != '\n' && c != '\r' && c != '\f') || c == 0x7f) {
            binary = YES; break;
        }
    }
    if (!source || binary) {
        if (error) *error = [NSError errorWithDomain:SPDFMarkdownErrorDomain code:SPDFMarkdownErrorInvalidUTF8
            userInfo:@{NSLocalizedDescriptionKey: binary ? @"This file contains binary data, not readable source text."
                : @"Text documents must use UTF-8, or UTF-16/UTF-32 with a Unicode byte-order mark."}];
        return nil;
    }
    return source;
}

NS_ASSUME_NONNULL_END
