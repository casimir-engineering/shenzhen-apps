#import "SPDFMarkdownResources.h"

#import "SPDFMarkdownParser.h"

#import <ImageIO/ImageIO.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

static const NSUInteger SPDFMarkdownMaximumSingleResourceBytes = 64 * 1024 * 1024;

static BOOL SPDFContainsNullCharacter(NSString* value) {
    unichar nullCharacter = 0;
    NSString* needle = [NSString stringWithCharacters:&nullCharacter length:1];
    return [value rangeOfString:needle].location != NSNotFound;
}

NSString* SPDFMarkdownRemoteImageKeyForTarget(NSString* target) {
    if (!target.length || SPDFContainsNullCharacter(target)) return nil;
    NSURL* URL = [NSURL URLWithString:target];
    if (!URL || ![URL.scheme.lowercaseString isEqualToString:@"https"] || !URL.host.length) return nil;
    return URL.absoluteString;
}

static NSArray<NSString*>* SPDFLocalPathComponents(NSString* target) {
    NSString* decoded = [target stringByRemovingPercentEncoding] ?: target;
    NSURLComponents* URLParts = [NSURLComponents componentsWithString:decoded];
    if (!URLParts || URLParts.scheme.length || URLParts.host.length || URLParts.user.length ||
        URLParts.password.length || [decoded hasPrefix:@"//"] || [decoded hasPrefix:@"data:"]) {
        return nil;
    }
    NSString* path = [[decoded componentsSeparatedByString:@"#"] firstObject];
    if (path.length == 0 || [path hasPrefix:@"/"] || [path hasPrefix:@"~"] || [path containsString:@"?"]) {
        return nil;
    }
    NSMutableArray<NSString*>* components = [NSMutableArray array];
    for (NSString* component in path.pathComponents) {
        if ([component isEqualToString:@"."] || component.length == 0) continue;
        if ([component isEqualToString:@".."] || [component isEqualToString:@"~"] ||
            [component containsString:@"/"] || SPDFContainsNullCharacter(component)) {
            return nil;
        }
        [components addObject:component];
    }
    return components.count ? components : nil;
}

static BOOL SPDFSameFile(struct stat left, struct stat right) {
    return left.st_dev == right.st_dev && left.st_ino == right.st_ino;
}

// Pins the document's identity at store creation: an O_RDONLY descriptor on
// the document file itself (covered by the open-file grant the app already
// holds — never TCC-gated the way its parent directory is) plus its dev/ino.
static int SPDFOpenPinnedDocumentDescriptor(NSURL* documentURL, struct stat* documentInfo) {
    if (!documentURL.isFileURL) return -1;
    int document = open(documentURL.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (document < 0) return -1;
    if (fstat(document, documentInfo) != 0 || !S_ISREG(documentInfo->st_mode)) {
        close(document);
        return -1;
    }
    return document;
}

// Opens (and verifies) the directory that currently contains the pinned
// document descriptor's file. The descriptor tracks the ORIGINAL file across
// renames, so a pathname replacement between parse and this open can never
// redirect resource loads: F_GETPATH names where that very file lives now,
// and the openat + dev/ino comparison proves the directory really holds it.
static int SPDFOpenVerifiedRootOfDocument(int document, struct stat documentInfo, NSString** rootPath) {
    char canonicalPath[PATH_MAX] = {};
    if (document < 0 || fcntl(document, F_GETPATH, canonicalPath) != 0) return -1;

    NSString* canonical = [NSFileManager.defaultManager stringWithFileSystemRepresentation:canonicalPath
                                                                                     length:strlen(canonicalPath)];
    NSString* directoryPath = canonical.stringByDeletingLastPathComponent;
    NSString* fileName = canonical.lastPathComponent;
    int directory = open(directoryPath.fileSystemRepresentation,
                         O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    int verified = directory >= 0
        ? openat(directory, fileName.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        : -1;
    struct stat verifiedInfo = {};
    BOOL matches = verified >= 0 && fstat(verified, &verifiedInfo) == 0 &&
                   SPDFSameFile(documentInfo, verifiedInfo);
    if (verified >= 0) close(verified);
    if (!matches) {
        if (directory >= 0) close(directory);
        return -1;
    }
    if (rootPath) *rootPath = directoryPath;
    return directory;
}

static NSData* SPDFReadDescriptor(int fileDescriptor, NSUInteger maximumBytes) {
    struct stat info = {};
    NSUInteger limit = MIN(maximumBytes, SPDFMarkdownMaximumSingleResourceBytes);
    if (fstat(fileDescriptor, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 ||
        (uint64_t)info.st_size > limit) {
        return nil;
    }
    NSMutableData* data = [NSMutableData dataWithCapacity:(NSUInteger)info.st_size];
    unsigned char buffer[64 * 1024];
    for (;;) {
        ssize_t count = read(fileDescriptor, buffer, sizeof(buffer));
        if (count == 0) return data;
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 || data.length + (NSUInteger)count > limit) return nil;
        [data appendBytes:buffer length:(NSUInteger)count];
    }
}

@interface SPDFMarkdownCachedResource : NSObject
@property(nonatomic, nullable) NSData* data;
@property(nonatomic, nullable) NSImage* image;
@property(nonatomic, nullable) NSURL* resolvedURL;
@property(nonatomic) BOOL imageLoaded;
@end
@implementation SPDFMarkdownCachedResource
@end

@interface SPDFMarkdownResourceStore ()
- (instancetype)initWithRootDescriptor:(int)rootDescriptor
                               rootPath:(NSString*)rootPath
                   maximumResourceBytes:(NSUInteger)maximumResourceBytes
              maximumDecodedImagePixels:(NSUInteger)maximumDecodedImagePixels NS_DESIGNATED_INITIALIZER;
@end

@implementation SPDFMarkdownResourceStore {
    int _rootDescriptor;
    NSString* _rootPath;
    // Lazy root: the verified directory open is deferred to the first LOCAL
    // resource lookup. Opening the document's parent directory is TCC-gated
    // for protected folders (Downloads, Desktop, Documents), so an eager open
    // during the initial parse could block the launch render pipeline
    // indefinitely behind a consent prompt — a document that references no
    // local resources must never touch its directory at all. The document
    // descriptor pinned at creation keeps the pathname-replacement guarantee
    // across the deferral (see SPDFOpenVerifiedRootOfDocument); it is closed
    // once the root open has been attempted.
    int _documentDescriptor;
    struct stat _documentInfo;
    BOOL _rootOpenAttempted;
    NSUInteger _maximumResourceBytes;
    NSUInteger _maximumDecodedImagePixels;
    NSMutableDictionary<NSString*, SPDFMarkdownCachedResource*>* _cache;
}

- (instancetype)initWithRootDescriptor:(int)rootDescriptor
                               rootPath:(NSString*)rootPath
                   maximumResourceBytes:(NSUInteger)maximumResourceBytes
              maximumDecodedImagePixels:(NSUInteger)maximumDecodedImagePixels {
    self = [super init];
    if (!self) {
        close(rootDescriptor);
        return nil;
    }
    _rootDescriptor = rootDescriptor;
    _rootPath = [rootPath copy];
    _documentDescriptor = -1;
    _maximumResourceBytes = maximumResourceBytes;
    _maximumDecodedImagePixels = maximumDecodedImagePixels;
    _cache = [NSMutableDictionary dictionary];
    return self;
}

- (instancetype)initWithDocumentURL:(NSURL*)documentURL {
    return [self initWithDocumentURL:documentURL
                maximumResourceBytes:64 * 1024 * 1024
           maximumDecodedImagePixels:32 * 1024 * 1024];
}

+ (instancetype)remoteOnlyStoreWithMaximumResourceBytes:(NSUInteger)maximumResourceBytes
                              maximumDecodedImagePixels:(NSUInteger)maximumDecodedImagePixels {
    return [[self alloc] initWithRootDescriptor:-1
                                       rootPath:@""
                           maximumResourceBytes:maximumResourceBytes
                      maximumDecodedImagePixels:maximumDecodedImagePixels];
}

- (instancetype)initWithDocumentURL:(NSURL*)documentURL
                maximumResourceBytes:(NSUInteger)maximumResourceBytes
           maximumDecodedImagePixels:(NSUInteger)maximumDecodedImagePixels {
    struct stat documentInfo = {};
    int document = SPDFOpenPinnedDocumentDescriptor(documentURL, &documentInfo);
    if (document < 0) return nil;
    self = [self initWithRootDescriptor:-1
                               rootPath:@""
                   maximumResourceBytes:maximumResourceBytes
              maximumDecodedImagePixels:maximumDecodedImagePixels];
    if (!self) {
        close(document);
        return nil;
    }
    _documentDescriptor = document;
    _documentInfo = documentInfo;
    return self;
}

// The lazily opened (and verified) document-root descriptor; see the ivar
// comments. One attempt per store: a failed open (missing directory, denied
// consent) caches the failure so a render never re-prompts per target.
- (int)verifiedRootDescriptor {
    if (_rootDescriptor < 0 && !_rootOpenAttempted && _documentDescriptor >= 0) {
        _rootOpenAttempted = YES;
        NSString* rootPath = nil;
        _rootDescriptor = SPDFOpenVerifiedRootOfDocument(_documentDescriptor, _documentInfo, &rootPath);
        if (_rootDescriptor >= 0) _rootPath = [rootPath copy];
        close(_documentDescriptor);
        _documentDescriptor = -1;
    }
    return _rootDescriptor;
}

- (void)dealloc {
    if (_rootDescriptor >= 0) close(_rootDescriptor);
    if (_documentDescriptor >= 0) close(_documentDescriptor);
}

- (NSUInteger)cachedResourceCount { return _cache.count; }

- (SPDFMarkdownResourceStore*)storeWithMaximumResourceBytes:(NSUInteger)maximumResourceBytes
                                  maximumDecodedImagePixels:(NSUInteger)maximumDecodedImagePixels {
    int descriptor = -1;
    int document = -1;
    if (_rootDescriptor >= 0) {
        descriptor = dup(_rootDescriptor);
        if (descriptor < 0) return nil;
    } else if (_documentDescriptor >= 0) {
        // Keep the lazy root AND the pinned document identity: the child
        // opens the verified directory itself on its first local lookup.
        document = dup(_documentDescriptor);
        if (document < 0) return nil;
    }
    SPDFMarkdownResourceStore* store =
        [[SPDFMarkdownResourceStore alloc] initWithRootDescriptor:descriptor
                                                         rootPath:_rootPath
                                             maximumResourceBytes:maximumResourceBytes
                                        maximumDecodedImagePixels:maximumDecodedImagePixels];
    if (!store) {
        if (document >= 0) close(document);
        return nil;
    }
    if (document >= 0) {
        store->_documentDescriptor = document;
        store->_documentInfo = _documentInfo;
    }
    return store;
}

- (NSString*)currentRootPath {
    char path[PATH_MAX] = {};
    if (fcntl(_rootDescriptor, F_GETPATH, path) != 0) return _rootPath;
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:path length:strlen(path)];
}

// Remote https images resolve exclusively against the preloaded byte map —
// never the network — under the same aggregate byte budget as local files.
// A key without bytes (not fetched yet, fetch failed, over budget) caches the
// miss so every reference in the render agrees.
- (SPDFMarkdownCachedResource*)loadRemoteTarget:(NSString*)key {
    SPDFMarkdownCachedResource* cached = _cache[key];
    if (cached) return cached;
    cached = [SPDFMarkdownCachedResource new];
    _cache[key] = cached;
    NSData* data = _remoteImageData[key];
    NSUInteger remaining = _loadedResourceBytes < _maximumResourceBytes
        ? _maximumResourceBytes - _loadedResourceBytes : 0;
    if (!data.length || data.length > MIN(remaining, SPDFMarkdownMaximumSingleResourceBytes)) return cached;
    cached.data = data;
    _loadedResourceBytes += data.length;
    cached.resolvedURL = [NSURL URLWithString:key];
    return cached;
}

- (SPDFMarkdownCachedResource*)loadTarget:(NSString*)target {
    NSString* remoteKey = SPDFMarkdownRemoteImageKeyForTarget(target);
    if (remoteKey) return [self loadRemoteTarget:remoteKey];
    NSArray<NSString*>* components = SPDFLocalPathComponents(target);
    if (!components.count) return nil;
    NSString* key = [components componentsJoinedByString:@"/"];
    SPDFMarkdownCachedResource* cached = _cache[key];
    if (cached) return cached;

    cached = [SPDFMarkdownCachedResource new];
    _cache[key] = cached;  // Failed resources are cached too.
    int descriptor = dup([self verifiedRootDescriptor]);
    if (descriptor < 0) return cached;
    for (NSUInteger index = 0; index < components.count; ++index) {
        BOOL final = index + 1 == components.count;
        int flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (final ? O_NONBLOCK : O_DIRECTORY);
        int next = openat(descriptor, components[index].fileSystemRepresentation, flags);
        close(descriptor);
        descriptor = next;
        if (descriptor < 0) return cached;
    }
    NSUInteger remaining = _loadedResourceBytes < _maximumResourceBytes
        ? _maximumResourceBytes - _loadedResourceBytes : 0;
    NSData* data = SPDFReadDescriptor(descriptor, remaining);
    close(descriptor);
    if (!data) return cached;
    cached.data = data;
    _loadedResourceBytes += data.length;
    NSURL* URL = [NSURL fileURLWithPath:self.currentRootPath isDirectory:YES];
    for (NSString* component in components) URL = [URL URLByAppendingPathComponent:component];
    cached.resolvedURL = URL;
    return cached;
}

- (NSData*)dataForTarget:(NSString*)target resolvedURL:(NSURL**)resolvedURL {
    if (resolvedURL) *resolvedURL = nil;
    SPDFMarkdownCachedResource* resource = [self loadTarget:target];
    if (resolvedURL) *resolvedURL = resource.resolvedURL;
    return resource.data;
}

- (NSImage*)imageForTarget:(NSString*)target resolvedURL:(NSURL**)resolvedURL {
    if (resolvedURL) *resolvedURL = nil;
    SPDFMarkdownCachedResource* resource = [self loadTarget:target];
    if (resolvedURL) *resolvedURL = resource.resolvedURL;
    if (!resource || resource.imageLoaded) return resource.image;
    resource.imageLoaded = YES;
    if (!resource.data) return nil;

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)resource.data, NULL);
    CFDictionaryRef rawProperties = source ? CGImageSourceCopyPropertiesAtIndex(source, 0, NULL) : NULL;
    NSDictionary* properties = CFBridgingRelease(rawProperties);
    uint64_t width = [properties[(NSString*)kCGImagePropertyPixelWidth] unsignedLongLongValue];
    uint64_t height = [properties[(NSString*)kCGImagePropertyPixelHeight] unsignedLongLongValue];
    uint64_t pixels = width && height <= UINT64_MAX / width ? width * height : UINT64_MAX;
    NSUInteger remaining = _decodedImagePixels < _maximumDecodedImagePixels
        ? _maximumDecodedImagePixels - _decodedImagePixels : 0;
    if (!source || !width || !height) {
        if (source) CFRelease(source);
        // ImageIO cannot identify this data — notably SVG (shields.io badges).
        // Try NSImage, which rasterizes SVG data on modern macOS; where that
        // fails too, the caller keeps the stable text placeholder. The decoded
        // size counts against the same pixel budget.
        NSImage* fallback = [[NSImage alloc] initWithData:resource.data];
        NSSize fallbackSize = fallback.size;
        uint64_t fallbackPixels = fallbackSize.width >= 1 && fallbackSize.height >= 1
            ? (uint64_t)ceil(fallbackSize.width) * (uint64_t)ceil(fallbackSize.height) : 0;
        if (fallbackPixels > 0 && fallbackPixels <= remaining) {
            resource.image = fallback;
            _decodedImagePixels += (NSUInteger)fallbackPixels;
        }
        resource.data = nil;
        return resource.image;
    }
    if (pixels > remaining) {
        CFRelease(source);
        resource.data = nil;
        return nil;
    }
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (image) {
        resource.image = [[NSImage alloc] initWithCGImage:image size:NSMakeSize(width, height)];
        CGImageRelease(image);
        _decodedImagePixels += (NSUInteger)pixels;
    }
    resource.data = nil;
    return resource.image;
}

@end

@implementation SPDFMarkdownParser (Resources)
+ (NSData*)localResourceDataForTarget:(NSString*)target
                relativeToDocumentURL:(NSURL*)documentURL
                             resolvedURL:(NSURL**)resolvedURL {
    SPDFMarkdownResourceStore* store = [[SPDFMarkdownResourceStore alloc] initWithDocumentURL:documentURL];
    return [store dataForTarget:target resolvedURL:resolvedURL];
}
@end
