// Fuzz target: the session frame parser (SZFriendsDecodeFrame and the field walker under it), which sees every
// decrypted byte a peer sends, the handshake payload parser that shares the walker, and a THUMBNAIL's way from frame
// to cache PNG (SZFriendsPNGFromReceivedThumbnail). Built like szfriends_fuzz_qoi.c (thumbnails.mk).
//
// Invariants beyond "no crash": a frame that decodes re-encodes (decoding enforced every limit the encoder checks)
// and decodes again to the same type and fields, and its typed accessors agree with its raw fields. A violation
// aborts.

#import <Foundation/Foundation.h>

#import "service/session/SZFriendsHandshakePayload.h"
#import "service/session/SZFriendsSession.h"
#import "service/thumbnails/SZFriendsThumbnails.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

static void SZFuzzCheckAccessors(SZFriendsFrame *frame) {
    for (NSNumber *tag in frame.fields) {
        SZFriendsFieldTag field = (SZFriendsFieldTag)tag.unsignedCharValue;
        // Every decoded field passed its rule, so the checked accessor returns exactly the raw value.
        if (![[frame dataForTag:field] isEqualToData:frame.fields[tag]]) abort();
        (void)[frame stringForTag:field];
        uint64_t value = 0;
        if ([frame getUInt64:&value forTag:field]) {
            NSData *again = [SZFriendsFrame fieldWithUInt64:value tag:field];
            if (![again isEqualToData:frame.fields[tag]]) abort();
        }
    }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    @autoreleasepool {
        NSData *plaintext = [NSData dataWithBytesNoCopy:(void *)data length:size freeWhenDone:NO];
        SZFriendsFrame *frame = SZFriendsDecodeFrame(plaintext, NULL);
        if (frame != nil) {
            NSData *encoded = SZFriendsEncodeFrame(frame, NULL);
            SZFriendsFrame *again = encoded ? SZFriendsDecodeFrame(encoded, NULL) : nil;
            if (again == nil || again.type != frame.type || ![again.fields isEqualToDictionary:frame.fields]) abort();
            SZFuzzCheckAccessors(frame);
            uint64_t width = 0, height = 0;
            if (frame.type == SZFriendsFrameTypeThumbnail && [frame getUInt64:&width forTag:SZFriendsFieldWidth] &&
                [frame getUInt64:&height forTag:SZFriendsFieldHeight]) {
                (void)SZFriendsPNGFromReceivedThumbnail([frame dataForTag:SZFriendsFieldData], width, height, NULL);
            }
        }
        // Handshake payloads are the same fields without a type byte: skip the first byte as a cheap second shape.
        (void)[SZFriendsHandshakePayload payloadWithData:plaintext error:NULL];
        if (size > 1) {
            NSData *tail = [plaintext subdataWithRange:NSMakeRange(1, size - 1)];
            SZFriendsHandshakePayload *payload = [SZFriendsHandshakePayload payloadWithData:tail error:NULL];
            if (payload != nil) (void)[payload encodedDataWithError:NULL];
        }
    }
    return 0;
}
