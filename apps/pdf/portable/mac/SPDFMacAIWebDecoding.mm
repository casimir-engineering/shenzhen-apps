#import "SPDFMacAIWebDecoding.h"
#import "SPDFMacAIWebAddress.h"
#include <compression.h>

// libcompression is not on the app's link line (portable/Makefile globs mac/*.mm), so this object names it itself, as
// SPDFMacAIWebConnection.mm does for Network and Security.
__asm__(".linker_option \"-lcompression\"");

static const size_t kChunk = 64 * 1024;

typedef NS_ENUM(NSInteger, SPDFWebInflate) { SPDFWebInflateEnd, SPDFWebInflateFull, SPDFWebInflateShort,
                                             SPDFWebInflateBroken };

// Decodes one raw stream from `bytes` onto `output` until it ends, the output reaches `limit`, or the input runs out.
// *used is how much input the stream took.
static SPDFWebInflate Inflate(compression_algorithm algorithm, const uint8_t* bytes, size_t length, NSUInteger limit,
                              NSMutableData* output, size_t* used) {
    compression_stream stream;
    *used = 0;
    if (compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) != COMPRESSION_STATUS_OK)
        return SPDFWebInflateBroken;
    uint8_t* chunk = (uint8_t*)malloc(kChunk);
    stream.src_ptr = bytes;
    stream.src_size = length;
    SPDFWebInflate outcome = SPDFWebInflateShort;
    while (chunk) {
        stream.dst_ptr = chunk;
        stream.dst_size = kChunk;
        size_t before = stream.src_size;
        compression_status status = compression_stream_process(&stream, COMPRESSION_STREAM_FINALIZE);
        size_t produced = kChunk - stream.dst_size;
        NSUInteger room = limit > output.length ? limit - output.length : 0;
        [output appendBytes:chunk length:MIN(room, produced)];
        if (produced > room) { outcome = SPDFWebInflateFull; break; }
        if (status == COMPRESSION_STATUS_END) {
            outcome = SPDFWebInflateEnd;
            break;
        }
        if (status == COMPRESSION_STATUS_ERROR) { outcome = SPDFWebInflateBroken; break; }
        if (!produced && stream.src_size == before) break; // the input ended inside the stream: a prefix
        if (output.length >= limit && stream.src_size) { outcome = SPDFWebInflateFull; break; }
    }
    *used = length - stream.src_size;
    free(chunk);
    compression_stream_destroy(&stream);
    return outcome;
}

// Where a gzip member's deflate data starts (RFC 1952 § 2.3), or 0 when `bytes` is not one.
static size_t GzipHeader(const uint8_t* bytes, size_t length) {
    if (length < 10 || bytes[0] != 0x1f || bytes[1] != 0x8b || bytes[2] != 8) return 0;
    uint8_t flags = bytes[3];
    size_t at = 10;
    if (flags & 0x04) {
        if (at + 2 > length) return 0;
        at += 2 + (size_t)(bytes[at] | (bytes[at + 1] << 8));
    }
    const uint8_t fields[] = {0x08, 0x10}; // file name, then comment: each ends at a NUL
    for (uint8_t field : fields) {
        if (!(flags & field)) continue;
        while (at < length && bytes[at]) at++;
        at++;
    }
    if (flags & 0x02) at += 2;
    return at <= length ? at : 0;
}

NSData* SPDFMacAIWebDecodeBody(NSData* body, NSString* encoding, NSUInteger limit, BOOL* truncated, NSError** error) {
    if (truncated) *truncated = NO;
    if (error) *error = nil;
    const uint8_t* bytes = (const uint8_t*)body.bytes;
    size_t length = body.length, used = 0;
    NSMutableData* output = [NSMutableData data];
    SPDFWebInflate outcome = SPDFWebInflateBroken;
    if ([encoding isEqual:@"br"]) {
        outcome = Inflate(COMPRESSION_BROTLI, bytes, length, limit, output, &used);
    } else if ([encoding isEqual:@"deflate"]) {
        // HTTP's deflate is zlib-wrapped (RFC 9110 § 8.4.1.2), yet servers that send it raw are common enough that
        // browsers read both. A zlib header is two bytes: method 8, a window that fits, a check that divides by 31,
        // and no preset dictionary.
        BOOL wrapped = length >= 2 && (bytes[0] & 0x0F) == 8 && (bytes[0] >> 4) <= 7 &&
            ((bytes[0] << 8) | bytes[1]) % 31 == 0 && !(bytes[1] & 0x20);
        outcome = Inflate(COMPRESSION_ZLIB, bytes + (wrapped ? 2 : 0), length - (wrapped ? 2 : 0), limit, output,
                          &used);
    } else if ([encoding isEqual:@"gzip"]) {
        // Members one after another, each with its 8-byte trailer, as gzip itself reads a concatenated file.
        size_t at = 0;
        do {
            size_t start = GzipHeader(bytes + at, length - at);
            if (!start) { outcome = output.length ? SPDFWebInflateEnd : SPDFWebInflateBroken; break; }
            outcome = Inflate(COMPRESSION_ZLIB, bytes + at + start, length - at - start, limit, output, &used);
            at += start + used + 8;
        } while (outcome == SPDFWebInflateEnd && at + 10 <= length);
    }
    if (outcome == SPDFWebInflateBroken && !output.length) {
        if (error) *error = SPDFMacAIWebMakeError(SPDFMacAIWebErrorBadResponse, [NSString stringWithFormat:
            @"The site's %@-compressed answer could not be decoded.", encoding]);
        return nil;
    }
    if (truncated) *truncated = outcome != SPDFWebInflateEnd;
    return output;
}
