// Shared by the identity area's test executables: checks that count failures instead of stopping at the first,
// and private temporary directories. Each test prints "<Name> passed" and exits 0 only when nothing failed.

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>

static int SZFTestFailures = 0;

#define SZFExpect(condition, ...)                                                                                  \
    do {                                                                                                           \
        if (!(condition)) {                                                                                        \
            SZFTestFailures++;                                                                                     \
            fprintf(stderr, "%s:%d: expected %s: %s\n", __FILE__, __LINE__, #condition,                            \
                    [[NSString stringWithFormat:__VA_ARGS__] UTF8String]);                                         \
        }                                                                                                          \
    } while (0)

// Expects `block` to raise an Objective-C exception named `name`.
static inline BOOL SZFRaises(NSString *name, void (^block)(void)) {
    @try {
        block();
    } @catch (NSException *exception) {
        return [exception.name isEqualToString:name];
    }
    return NO;
}

// A fresh 0700 directory under $TMPDIR, removed by SZFRemoveTemporaryDirectory.
static inline NSString *SZFMakeTemporaryDirectory(NSString *label) {
    NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"szfriends-identity-%@.XXXXXX", label]];
    char *path = strdup(pattern.fileSystemRepresentation);
    char *made = mkdtemp(path);
    NSString *result = made != NULL ? [[NSFileManager defaultManager] stringWithFileSystemRepresentation:made
                                                                                                   length:strlen(made)]
                                    : nil;
    free(path);
    if (result == nil) {
        fprintf(stderr, "cannot create a temporary directory\n");
        exit(1);
    }
    return result;
}

static inline void SZFRemoveTemporaryDirectory(NSString *path) {
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static inline NSData *SZFHex(NSString *hex) {
    NSMutableData *data = [NSMutableData dataWithCapacity:hex.length / 2];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned value = 0;
        [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&value];
        uint8_t byte = (uint8_t)value;
        [data appendBytes:&byte length:1];
    }
    return data;
}

static inline int SZFFinish(const char *name) {
    if (SZFTestFailures != 0) {
        fprintf(stderr, "%s failed: %d check(s)\n", name, SZFTestFailures);
        return 1;
    }
    printf("%s passed\n", name);
    return 0;
}
