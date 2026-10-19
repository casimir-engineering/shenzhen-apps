#import "SPDFMacPassword.h"

#include <sys/stat.h>

static void spdf_secure_zero(void* bytes, size_t length) {
    volatile unsigned char* cursor = (volatile unsigned char*)bytes;
    while (length--) *cursor++ = 0;
}

@interface SPDFPasswordCredential () {
    char* _bytes;
    size_t _length;
}
@end

@implementation SPDFPasswordCredential

- (instancetype)initWithPassword:(NSString*)password {
    self = [super init];
    if (!self) return nil;
    NSData* data = [password dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO] ?: [NSData data];
    _length = data.length;
    _bytes = (char*)calloc(_length + 1, 1);
    if (!_bytes) return nil;
    if (_length) memcpy(_bytes, data.bytes, _length);
    return self;
}

- (void)withUTF8Password:(void (^)(const char* password))block {
    if (block) block(_bytes ?: "");
}

- (void)dealloc {
    if (_bytes) {
        spdf_secure_zero(_bytes, _length + 1);
        free(_bytes);
    }
}

@end

@interface SPDFPasswordStoreEntry : NSObject
@property(nonatomic, copy) NSString* identity;
@property(nonatomic, copy) NSString* cacheToken;
@property(nonatomic, strong) SPDFPasswordCredential* credential;
@end

@implementation SPDFPasswordStoreEntry
@end

static NSString* spdf_standardized_password_path(NSString* path) {
    if (!path.length) return @"";
    return path.stringByStandardizingPath ?: path;
}

static NSString* spdf_password_source_identity(NSString* path) {
    NSString* standardized = spdf_standardized_password_path(path);
    if (!standardized.length) return nil;
    struct stat st;
    if (lstat(standardized.fileSystemRepresentation, &st) != 0) return nil;
#if defined(__APPLE__)
    long mtimeNanoseconds = st.st_mtimespec.tv_nsec;
    long long mtimeSeconds = st.st_mtimespec.tv_sec;
#else
    long mtimeNanoseconds = st.st_mtim.tv_nsec;
    long long mtimeSeconds = st.st_mtim.tv_sec;
#endif
    return [NSString stringWithFormat:@"%@:%llu:%llu:%llu:%lld:%ld", standardized,
                                      (unsigned long long)st.st_dev, (unsigned long long)st.st_ino,
                                      (unsigned long long)st.st_size, mtimeSeconds, mtimeNanoseconds];
}

@implementation SPDFPasswordCredentialStore {
    NSLock* _lock;
    NSMutableDictionary<NSString*, SPDFPasswordStoreEntry*>* _entries;
}

+ (instancetype)sharedStore {
    static SPDFPasswordCredentialStore* store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [[SPDFPasswordCredentialStore alloc] initPrivate]; });
    return store;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _entries = [NSMutableDictionary dictionary];
    }
    return self;
}

- (instancetype)init {
    return [SPDFPasswordCredentialStore sharedStore];
}

- (SPDFPasswordCredential*)credentialForSourcePath:(NSString*)sourcePath {
    NSString* path = spdf_standardized_password_path(sourcePath);
    NSString* identity = spdf_password_source_identity(path);
    if (!path.length || !identity.length) {
        if (path.length) [self invalidateCredentialForSourcePath:path];
        return nil;
    }

    [_lock lock];
    SPDFPasswordStoreEntry* entry = _entries[path];
    if (entry && ![entry.identity isEqualToString:identity]) {
        [_entries removeObjectForKey:path];
        entry = nil;
    }
    SPDFPasswordCredential* credential = entry.credential;
    [_lock unlock];
    return credential;
}

- (void)setCredential:(SPDFPasswordCredential*)credential forSourcePath:(NSString*)sourcePath {
    NSString* path = spdf_standardized_password_path(sourcePath);
    NSString* identity = spdf_password_source_identity(path);
    if (!credential || !path.length || !identity.length) return;

    SPDFPasswordStoreEntry* entry = [[SPDFPasswordStoreEntry alloc] init];
    entry.identity = identity;
    entry.cacheToken = [identity stringByAppendingFormat:@":%@", NSUUID.UUID.UUIDString];
    entry.credential = credential;
    [_lock lock];
    _entries[path] = entry;
    [_lock unlock];
}

- (void)invalidateCredentialForSourcePath:(NSString*)sourcePath {
    NSString* path = spdf_standardized_password_path(sourcePath);
    if (!path.length) return;
    [_lock lock];
    [_entries removeObjectForKey:path];
    [_lock unlock];
}

- (NSString*)sourceIdentityTokenForSourcePath:(NSString*)sourcePath {
    return spdf_password_source_identity(sourcePath);
}

- (NSString*)cacheTokenForSourcePath:(NSString*)sourcePath {
    NSString* path = spdf_standardized_password_path(sourcePath);
    NSString* identity = spdf_password_source_identity(path);
    if (!path.length || !identity.length) {
        if (path.length) [self invalidateCredentialForSourcePath:path];
        return [path stringByAppendingString:@":missing"];
    }

    [_lock lock];
    SPDFPasswordStoreEntry* entry = _entries[path];
    if (entry && ![entry.identity isEqualToString:identity]) {
        [_entries removeObjectForKey:path];
        entry = nil;
    }
    NSString* token = entry.cacheToken ?: [identity stringByAppendingString:@":no-credential"];
    [_lock unlock];
    return token;
}

- (void)removeAllCredentials {
    [_lock lock];
    [_entries removeAllObjects];
    [_lock unlock];
}

@end

