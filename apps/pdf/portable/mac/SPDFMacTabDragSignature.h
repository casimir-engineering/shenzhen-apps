#pragma once
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonHMAC.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#import "SPDFMacStateDirectory.h"

// A reader tab dragged out of the tab strip carries an HMAC beside its JSON, under a per-user random key that only
// ShenzhenPDF processes read, so a drop target can tell the strip's drag from another app's.
//
// Why: any app, a sandboxed one included, can write the strip's pasteboard type. Shenzhen Friends sends a dropped
// tab's file at once, and the security review showed a forged payload sending any file the reader can read (a secret
// key, say) under the name holiday.jpg.
// The key is 32 bytes from arc4random_buf in the reader's state directory, mode 0600, created once with O_EXCL and
// link() so concurrent windows (separate processes) agree on it. A signature also binds the time it was made, so a
// payload copied off the drag pasteboard stops verifying after SPDFMacTabDragSignatureLifetime.
//
// Header-only because the strip's drag code is compiled into several tab-strip test binaries with fixed source lists.

static NSPasteboardType const SPDFMacTabDragSignatureType = @"com.intuition.shenzhenpdf.tab.signature";
static NSPasteboardType const SPDFMacTabDragPayloadType = @"com.intuition.shenzhenpdf.tab";
static NSString* const SPDFMacTabDragKeyFileName = @"tab-drag.key";
static const NSTimeInterval SPDFMacTabDragSignatureLifetime = 15 * 60;
enum { SPDFMacTabDragKeyLength = 32 };

static inline NSData* SPDFMacTabDragReadKey(NSString* path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat st = {};
    unsigned char bytes[SPDFMacTabDragKeyLength];
    // Only a private regular file of ours, of exactly the key's size: a key another user could read or replace
    // would let them sign payloads.
    BOOL ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == getuid() && !(st.st_mode & 077) &&
        st.st_size == SPDFMacTabDragKeyLength && read(fd, bytes, sizeof bytes) == (ssize_t)sizeof bytes;
    close(fd);
    NSData* key = ok ? [NSData dataWithBytes:bytes length:sizeof bytes] : nil;
    memset(bytes, 0, sizeof bytes);
    return key;
}

// The key in `directory`, created on first use; nil when it cannot be read or made (then nothing is signed, and a
// drop that requires a signature refuses the tab).
static inline NSData* SPDFMacTabDragKeyInDirectory(NSString* directory) {
    if (!directory.length) return nil;
    NSString* path = [directory stringByAppendingPathComponent:SPDFMacTabDragKeyFileName];
    NSData* key = SPDFMacTabDragReadKey(path);
    struct stat st = {};
    // A key file that exists but fails the checks is left alone rather than replaced.
    if (key || lstat(path.fileSystemRepresentation, &st) == 0 || errno != ENOENT) return key;
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil
                                                  error:nil];
    NSString* temporary = [path stringByAppendingFormat:@".%d.%@", getpid(), NSUUID.UUID.UUIDString];
    int fd = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return nil;
    unsigned char bytes[SPDFMacTabDragKeyLength];
    arc4random_buf(bytes, sizeof bytes);
    BOOL written = write(fd, bytes, sizeof bytes) == (ssize_t)sizeof bytes && fsync(fd) == 0;
    memset(bytes, 0, sizeof bytes);
    close(fd);
    // link() never replaces an existing key: when another window made one first, both use that one.
    if (written) link(temporary.fileSystemRepresentation, path.fileSystemRepresentation);
    unlink(temporary.fileSystemRepresentation);
    return SPDFMacTabDragReadKey(path);
}

// This process's key, from the reader's state directory (SPDF_STATE_DIR when set), read once.
static inline NSData* SPDFMacTabDragKey(void) {
    static NSData* key;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ key = SPDFMacTabDragKeyInDirectory(SPDFMacStateDirectoryPath()); });
    return key;
}

static inline NSString* SPDFMacTabDragMAC(NSString* payload, long long signedAt, NSData* key) {
    NSData* message = [[NSString stringWithFormat:@"v1\n%lld\n%@", signedAt, payload ?: @""]
        dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, message.bytes, message.length, mac);
    NSMutableString* hex = [NSMutableString stringWithCapacity:sizeof mac * 2];
    for (size_t i = 0; i < sizeof mac; i++) [hex appendFormat:@"%02x", mac[i]];
    return hex;
}

// "v1.<unix seconds>.<hex HMAC-SHA256 of "v1\n<seconds>\n<payload>">", or nil without a key.
static inline NSString* SPDFMacTabDragSignature(NSString* payload, NSDate* signedAt, NSData* key) {
    if (key.length != SPDFMacTabDragKeyLength || !payload) return nil;
    long long seconds = (long long)floor(signedAt.timeIntervalSince1970);
    return [NSString stringWithFormat:@"v1.%lld.%@", seconds, SPDFMacTabDragMAC(payload, seconds, key)];
}

static inline BOOL SPDFMacTabDragSignatureValid(NSString* payload, NSString* signature, NSData* key, NSDate* now) {
    if (key.length != SPDFMacTabDragKeyLength || ![payload isKindOfClass:NSString.class] ||
        ![signature isKindOfClass:NSString.class])
        return NO;
    NSArray<NSString*>* parts = [signature componentsSeparatedByString:@"."];
    if (parts.count != 3 || ![parts[0] isEqual:@"v1"] || parts[2].length != CC_SHA256_DIGEST_LENGTH * 2) return NO;
    NSScanner* scanner = [NSScanner scannerWithString:parts[1]];
    long long seconds = 0;
    if (![scanner scanLongLong:&seconds] || !scanner.atEnd) return NO;
    double age = now.timeIntervalSince1970 - (double)seconds;
    // A minute of tolerance the other way covers clocks read in two processes a moment apart.
    if (age > SPDFMacTabDragSignatureLifetime || age < -60) return NO;
    NSData* expected = [SPDFMacTabDragMAC(payload, seconds, key) dataUsingEncoding:NSASCIIStringEncoding];
    NSData* given = [parts[2] dataUsingEncoding:NSASCIIStringEncoding];
    return expected.length == given.length && timingsafe_bcmp(expected.bytes, given.bytes, expected.length) == 0;
}

// What the tab strip puts on the drag pasteboard: the tab JSON and, when this process has a key, its signature.
static inline NSPasteboardItem* SPDFMacTabDragPasteboardItem(NSString* payload, NSData* key, NSDate* now) {
    NSPasteboardItem* item = [[NSPasteboardItem alloc] init];
    [item setString:payload forType:SPDFMacTabDragPayloadType];
    NSString* signature = SPDFMacTabDragSignature(payload, now, key);
    if (signature) [item setString:signature forType:SPDFMacTabDragSignatureType];
    return item;
}

// The item's tab JSON when its signature verifies under `key`; nil for an unsigned, altered or expired payload.
static inline NSString* SPDFMacTabDragVerifiedPayload(NSPasteboardItem* item, NSData* key, NSDate* now) {
    NSString* payload = [item stringForType:SPDFMacTabDragPayloadType];
    NSString* signature = [item stringForType:SPDFMacTabDragSignatureType];
    return SPDFMacTabDragSignatureValid(payload, signature, key, now) ? payload : nil;
}
