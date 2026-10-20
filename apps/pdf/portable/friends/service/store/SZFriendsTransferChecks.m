// Pure transfer rules: the state machine, the file name sanitizer, collision-free destinations, offer validation and
// the automatic acceptance decision. No store, no clock, so each is tested exhaustively on its own.

#import <sys/stat.h>

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

const uint64_t SZFriendsTransferMaxFileSize = 9007199254740991ULL; // 2^53 - 1
const NSUInteger SZFriendsTransferMaxNameBytes = 1024;
const NSUInteger SZFriendsTransferMaxPendingOffers = 200;
const uint64_t SZFriendsTransferDefaultReserveBytes = 1ULL << 30;
NSString *const SZFriendsTransferFailureDigestMismatch = @"digest_mismatch";
NSString *const SZFriendsTransferFailureSourceMissing = @"source_missing";

// APFS allows 255 bytes per name; 200 leaves room for " 9999" when names collide and for tools that append.
static const NSUInteger SZFriendsSanitizedMaxBytes = 200;
// Longer "extensions" are part of the name ("notes.from the meeting with Mei"), not a type to preserve.
static const NSUInteger SZFriendsMaxExtensionLength = 16;

SZFriendsTransferState SZFriendsTransferNextState(BOOL outgoing, SZFriendsTransferState state,
                                                  SZFriendsTransferEvent event) {
    BOOL unanswered = outgoing ? (state == SZFriendsTransferStateQueued || state == SZFriendsTransferStateOffered)
                               : state == SZFriendsTransferStateWaitingForYou;
    SZFriendsTransferState moving = outgoing ? SZFriendsTransferStateSending : SZFriendsTransferStateReceiving;
    switch (event) {
        case SZFriendsTransferEventOfferDelivered:
            return outgoing && state == SZFriendsTransferStateQueued ? SZFriendsTransferStateOffered : state;
        case SZFriendsTransferEventAccepted:
            return unanswered ? moving : state;
        case SZFriendsTransferEventDeclined:
            return unanswered ? SZFriendsTransferStateDeclined : state;
        case SZFriendsTransferEventCancelled:
            // What already arrived cannot be retracted (brief § Transfers), so a finished transfer stays finished.
            return unanswered || state == moving ? SZFriendsTransferStateCancelled : state;
        case SZFriendsTransferEventVerified:
            if (state != moving) return state;
            return outgoing ? SZFriendsTransferStateDelivered : SZFriendsTransferStateReceived;
        case SZFriendsTransferEventFailed:
            // An incoming offer nobody accepted has nothing that can fail; the sender withdraws it with CANCEL.
            return (outgoing ? unanswered : NO) || state == moving ? SZFriendsTransferStateFailed : state;
        case SZFriendsTransferEventRetry:
            // Incoming transfers fail only while receiving, i.e. after acceptance, so retrying resumes that.
            if (state != SZFriendsTransferStateFailed) return state;
            return outgoing ? SZFriendsTransferStateQueued : SZFriendsTransferStateReceiving;
    }
    return state;
}

// Characters that hide or reorder what Finder shows: controls, bidi overrides and isolates ("invoice<U+202E>fdp.exe"
// displays as "invoiceexe.pdf"), invisible separators and the byte-order mark.
static BOOL SZFriendsIsStrippedCharacter(UTF32Char c) {
    if (c < 0x20 || (c >= 0x7f && c <= 0x9f)) return YES;
    if ((c >= 0x202A && c <= 0x202E) || (c >= 0x2066 && c <= 0x2069) || (c >= 0xFFF9 && c <= 0xFFFB)) return YES;
    switch (c) {
        case 0x061C: case 0x200B: case 0x200E: case 0x200F: case 0x2028: case 0x2029: case 0x2060: case 0xFEFF:
            return YES;
        default:
            return NO;
    }
}

static NSUInteger SZFriendsUTF8Length(NSString *text) { return [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]; }

// Drops whole composed characters from the end until the UTF-8 form fits, so no character is cut in half.
static NSString *SZFriendsTruncatedToBytes(NSString *text, NSUInteger maxBytes) {
    NSString *result = text;
    while (result.length && SZFriendsUTF8Length(result) > maxBytes) {
        NSRange last = [result rangeOfComposedCharacterSequenceAtIndex:result.length - 1];
        result = [result substringToIndex:last.location];
    }
    return result;
}

static NSString *SZFriendsTrimmed(NSString *text) {
    NSCharacterSet *spaces = NSCharacterSet.whitespaceCharacterSet;
    NSUInteger start = 0, end = text.length;
    // Leading dots would hide the file in Finder and spell "." or ".."; leading spaces hide the real start.
    while (start < end) {
        unichar c = [text characterAtIndex:start];
        if (c != '.' && ![spaces characterIsMember:c]) break;
        start++;
    }
    while (end > start && [spaces characterIsMember:[text characterAtIndex:end - 1]]) end--;
    return [text substringWithRange:NSMakeRange(start, end - start)];
}

NSString *SZFriendsSanitizedFileName(NSString *proposedName) {
    NSString *name = proposedName.precomposedStringWithCanonicalMapping ?: @"";
    NSData *utf32 = [name dataUsingEncoding:NSUTF32LittleEndianStringEncoding] ?: [NSData data];
    const UTF32Char *chars = utf32.bytes;
    NSUInteger count = utf32.length / sizeof(UTF32Char);
    NSMutableString *clean = [NSMutableString stringWithCapacity:name.length];
    for (NSUInteger i = 0; i < count; i++) {
        UTF32Char c = CFSwapInt32LittleToHost(chars[i]);
        if (SZFriendsIsStrippedCharacter(c)) continue;
        // "/" separates paths; ":" is how Finder stores "/" on disk; "\" separates paths on Windows senders.
        if (c == '/' || c == ':' || c == '\\') c = '-';
        UTF32Char little = CFSwapInt32HostToLittle(c);
        NSString *piece = [[NSString alloc] initWithBytes:&little length:sizeof little
                                                 encoding:NSUTF32LittleEndianStringEncoding];
        if (piece) [clean appendString:piece];
    }
    NSString *result = SZFriendsTrimmed(clean);
    if (SZFriendsUTF8Length(result) > SZFriendsSanitizedMaxBytes) {
        NSString *extension = result.pathExtension;
        NSString *base = result.stringByDeletingPathExtension;
        if (extension.length && extension.length <= SZFriendsMaxExtensionLength && base.length) {
            NSUInteger room = SZFriendsSanitizedMaxBytes - SZFriendsUTF8Length(extension) - 1;
            base = SZFriendsTrimmed(SZFriendsTruncatedToBytes(base, room));
            result = base.length ? [NSString stringWithFormat:@"%@.%@", base, extension] : extension;
        } else {
            result = SZFriendsTrimmed(SZFriendsTruncatedToBytes(result, SZFriendsSanitizedMaxBytes));
        }
    }
    return result.length ? result : @"Untitled";
}

// lstat, so a dangling symlink or a symlink to elsewhere counts as taken and is never followed or replaced.
static BOOL SZFriendsPathTaken(NSString *path) {
    struct stat info;
    return lstat(path.fileSystemRepresentation, &info) == 0 || errno != ENOENT;
}

NSString *SZFriendsUniqueDestination(NSString *directory, NSString *name) {
    // Sanitizing again makes the directory boundary hold whatever the caller passed: no separator survives.
    NSString *safe = SZFriendsSanitizedFileName(name);
    NSString *candidate = [directory stringByAppendingPathComponent:safe];
    if (!SZFriendsPathTaken(candidate)) return candidate;
    NSString *extension = safe.pathExtension;
    BOOL keepExtension = extension.length && extension.length <= SZFriendsMaxExtensionLength &&
                         safe.stringByDeletingPathExtension.length;
    NSString *base = keepExtension ? safe.stringByDeletingPathExtension : safe;
    for (NSUInteger n = 2; n < 10000; n++) {
        NSString *numbered = [NSString stringWithFormat:@"%@ (%lu)", base, (unsigned long)n];
        if (keepExtension) numbered = [numbered stringByAppendingPathExtension:extension];
        candidate = [directory stringByAppendingPathComponent:numbered];
        if (!SZFriendsPathTaken(candidate)) return candidate;
    }
    NSString *unique = [NSString stringWithFormat:@"%@ %@", base, SZFriendsNewIdentifier()];
    if (keepExtension) unique = [unique stringByAppendingPathExtension:extension];
    return [directory stringByAppendingPathComponent:unique];
}

BOOL SZFriendsValidateOffer(NSString *name, uint64_t declaredSize, NSData *contentDigest,
                            NSUInteger pendingOffersFromSender, NSString *_Nullable *_Nullable reason) {
    NSString *why = nil;
    if (name.length == 0) why = @"empty file name";
    else if (SZFriendsUTF8Length(name) > SZFriendsTransferMaxNameBytes) why = @"file name too long";
    else if (declaredSize > SZFriendsTransferMaxFileSize) why = @"declared size too large";
    else if (contentDigest.length != 32) why = @"content digest is not 32 bytes";
    else if (pendingOffersFromSender >= SZFriendsTransferMaxPendingOffers) why = @"too many unanswered offers";
    if (reason) *reason = why;
    return why == nil;
}

SZFriendsAutoAcceptDecision SZFriendsAutoAcceptDecide(BOOL autoAcceptOn, BOOL keyChangePending, BOOL blocked,
                                                      uint64_t fileSize, uint64_t freeBytes, uint64_t reserveBytes) {
    if (!autoAcceptOn || keyChangePending || blocked) return SZFriendsAutoAcceptAsk;
    // Written as subtraction so a huge declared size cannot overflow into "fits".
    if (fileSize > freeBytes || freeBytes - fileSize < reserveBytes) return SZFriendsAutoAcceptAskLowDisk;
    return SZFriendsAutoAcceptDownload;
}

NS_ASSUME_NONNULL_END
