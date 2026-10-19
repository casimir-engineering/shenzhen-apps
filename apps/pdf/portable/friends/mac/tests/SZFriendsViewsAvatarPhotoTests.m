// Shenzhen Friends views tests: avatar photos under the rule both apps share (PROTOCOL.md § Shared objects, Avatar).
// A photo loads only directly from the helper's pictures/ directory, opened without following a link and without
// waiting on a FIFO, as a regular file of at most 256 KiB, a JPEG or PNG declaring at most 1024 px a side and decoding
// to exactly that size; and it is decoded off the main thread, initials showing meanwhile.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsHelperFiles.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "client/szfriends_client.h"

static NSData *SZFImageData(NSInteger width, NSInteger height, NSBitmapImageFileType type) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:3
                        hasAlpha:NO isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    memset(rep.bitmapData, 0x5a, (size_t)(rep.bytesPerRow * height));
    return [rep representationUsingType:type properties:@{}];
}

static BOOL SZFLoads(NSString *path) {
    CGImageRef image = SZFriendsCopyAvatarPhoto(path);
    if (image) CGImageRelease(image);
    return image != NULL;
}

// PNG's chunk checksum (ISO 3309 CRC-32), so a rewritten header can be made to look intact.
static uint32_t SZFCRC32(const uint8_t *bytes, size_t length) {
    uint32_t crc = 0xffffffffu;
    for (size_t i = 0; i < length; i++) {
        crc ^= bytes[i];
        for (int bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1)));
    }
    return ~crc;
}

// A PNG whose IHDR is rewritten to declare `width` × `height`, with its checksum made to match or left wrong.
static NSData *SZFRewrittenPNG(NSData *png, uint16_t width, uint16_t height, BOOL fixChecksum) {
    NSMutableData *data = [png mutableCopy];
    uint8_t *bytes = data.mutableBytes;
    bytes[16] = bytes[17] = bytes[20] = bytes[21] = 0;
    bytes[18] = width >> 8, bytes[19] = width & 0xff, bytes[22] = height >> 8, bytes[23] = height & 0xff;
    if (fixChecksum) {
        uint32_t crc = SZFCRC32(bytes + 12, 17);
        bytes[29] = crc >> 24, bytes[30] = (crc >> 16) & 0xff, bytes[31] = (crc >> 8) & 0xff, bytes[32] = crc & 0xff;
    }
    return data;
}

static void SZFTestWhatLoads(NSString *state, NSString *pictures) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *photo = [pictures stringByAppendingPathComponent:@"c0ffee.jpg"];
    NSData *jpeg = SZFImageData(256, 256, NSBitmapImageFileTypeJPEG);
    [jpeg writeToFile:photo atomically:YES];
    SZFExpect(SZFLoads(photo), @"the helper's 256 px JPEG loads");
    NSString *png = [pictures stringByAppendingPathComponent:@"square.png"];
    NSData *pngData = SZFImageData(64, 64, NSBitmapImageFileTypePNG);
    [pngData writeToFile:png atomically:YES];
    SZFExpect(SZFLoads(png), @"a PNG loads too");
    NSString *hard = [pictures stringByAppendingPathComponent:@"hard.jpg"];
    link(photo.fileSystemRepresentation, hard.fileSystemRepresentation);
    SZFExpect(SZFLoads(hard), @"a hard link inside pictures/ is a regular file there");

    // Where it lies: only directly inside pictures/, spelled plainly.
    NSString *outside = [state stringByAppendingPathComponent:@"outside.jpg"];
    [jpeg writeToFile:outside atomically:YES];
    NSString *sibling = [state stringByAppendingPathComponent:@"picturesX"];
    [files createDirectoryAtPath:sibling withIntermediateDirectories:YES attributes:nil error:nil];
    [jpeg writeToFile:[sibling stringByAppendingPathComponent:@"c0ffee.jpg"] atomically:YES];
    NSString *nested = [pictures stringByAppendingPathComponent:@"nested"];
    [files createDirectoryAtPath:nested withIntermediateDirectories:YES attributes:nil error:nil];
    [jpeg writeToFile:[nested stringByAppendingPathComponent:@"c0ffee.jpg"] atomically:YES];
    NSArray *elsewhere = @[
        outside, [pictures stringByAppendingString:@"/../outside.jpg"],
         [pictures stringByAppendingString:@"/./c0ffee.jpg"],
        [pictures stringByAppendingString:@"//c0ffee.jpg"], [sibling stringByAppendingPathComponent:@"c0ffee.jpg"],
        [nested stringByAppendingPathComponent:@"c0ffee.jpg"], @"pictures/c0ffee.jpg", pictures, @""
    ];
    for (NSString *path in elsewhere) SZFExpect(!SZFLoads(path), @"not loaded from %@", path);

    // What it is: no link followed, no FIFO waited on, nothing but a regular file of a photo's size.
    NSString *inside = [pictures stringByAppendingPathComponent:@"link-inside.jpg"];
    symlink(photo.fileSystemRepresentation, inside.fileSystemRepresentation);
    NSString *out = [pictures stringByAppendingPathComponent:@"link-outside.jpg"];
    symlink(outside.fileSystemRepresentation, out.fileSystemRepresentation);
    SZFExpect(!SZFLoads(inside) && !SZFLoads(out), @"symbolic links are not followed, inside or out");
    NSString *fifo = [pictures stringByAppendingPathComponent:@"fifo.jpg"];
    mkfifo(fifo.fileSystemRepresentation, 0600);
    NSDate *start = [NSDate date];
    SZFExpect(!SZFLoads(fifo) && -start.timeIntervalSinceNow < 1, @"a FIFO is refused without waiting");
    NSString *folder = [pictures stringByAppendingPathComponent:@"folder.jpg"];
    mkdir(folder.fileSystemRepresentation, 0700);
    SZFExpect(!SZFLoads(folder), @"a folder is refused");
    NSString *large = [pictures stringByAppendingPathComponent:@"large.jpg"];
    NSMutableData *padded = [jpeg mutableCopy];
    padded.length = 300 * 1024; // a real header, then zeros: over 256 KiB
    [padded writeToFile:large atomically:YES];
    SZFExpect(!SZFLoads(large), @"a file over 256 KiB is not read");
    NSString *sparse = [pictures stringByAppendingPathComponent:@"sparse.jpg"];
    int fd = open(sparse.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) {
        write(fd, jpeg.bytes, jpeg.length);
        ftruncate(fd, 8LL << 30);
        close(fd);
    }
    start = [NSDate date];
    SZFExpect(!SZFLoads(sparse) && -start.timeIntervalSinceNow < 1, @"an 8 GiB sparse file is refused at once");

    // What its header says, and whether that is true.
    NSString *wide = [pictures stringByAppendingPathComponent:@"wide.png"];
    [SZFImageData(4096, 2, NSBitmapImageFileTypePNG) writeToFile:wide atomically:YES];
    SZFExpect(!SZFLoads(wide), @"a PNG declaring 4096 px is not decoded");
    NSString *svg = [pictures stringByAppendingPathComponent:@"drawing.png"];
    [@"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\"/>" writeToFile:svg atomically:YES
                                                                                  encoding:NSUTF8StringEncoding
                                                                                     error:nil];
    SZFExpect(!SZFLoads(svg), @"an SVG named .png is not a photo");
    NSString *lying = [pictures stringByAppendingPathComponent:@"lying.png"];
    [SZFRewrittenPNG(pngData, 9000, 64, YES) writeToFile:lying atomically:YES];
    SZFExpect(!SZFLoads(lying), @"a header rewritten to 9000 px is refused before decoding");
    NSString *tampered = [pictures stringByAppendingPathComponent:@"tampered.png"];
    [SZFRewrittenPNG(pngData, 32, 64, NO) writeToFile:tampered atomically:YES];
    SZFExpect(!SZFLoads(tampered), @"a header changed without its checksum is refused");
    NSString *truncated = [pictures stringByAppendingPathComponent:@"truncated.jpg"];
    [[jpeg subdataWithRange:NSMakeRange(0, 20)] writeToFile:truncated atomically:YES];
    SZFExpect(!SZFLoads(truncated), @"a JPEG cut off before its frame header is refused");
    for (NSString *path in @[ sparse, large ]) unlink(path.fileSystemRepresentation);
}

// The views never read or decode on the main thread: the first draw shows initials, the photo arrives later.
static void SZFTestLoadedOffTheMainThread(NSString *pictures) {
    NSString *photo = [pictures stringByAppendingPathComponent:@"c0ffee.jpg"];
    NSString *inside = [pictures stringByAppendingPathComponent:@"link-inside.jpg"];
    SZFriendsForgetAvatarPhotos();
    SZFriendsAvatarView *view = [[SZFriendsAvatarView alloc] initWithFrame:NSMakeRect(0, 0, 64, 64)];
    NSWindow *window = SZFTestHostWindow(view, NSMakeSize(64, 64), NSAppearanceNameAqua);
    view.avatar = @{@"kind" : @"image", @"path" : photo, @"initials" : @"MC", @"color" : @"#5a4a7a"};
    SZFExpect([view.drawnKind isEqualToString:@"placeholder"], @"initials while the photo loads off the main thread");
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return [view.drawnKind isEqualToString:@"image"]; }), @"then the photo");
    view.avatar = @{@"kind" : @"image", @"path" : inside, @"initials" : @"MC", @"color" : @"#5a4a7a"};
    SZFTestSpin(0.3);
    SZFExpect([view.drawnKind isEqualToString:@"placeholder"], @"a link inside pictures/ draws initials");
    view.avatar = @{@"kind" : @"image", @"path" : @"/System/Library/Desktop Pictures/x.jpg", @"initials" : @"MC",
                    @"color" : @"#5a4a7a"};
    SZFExpect(SZFriendsAvatarPhoto(view.avatar[@"path"], view) == nil &&
                  [view.drawnKind isEqualToString:@"placeholder"],
              @"a path outside pictures/ is never read");
    (void)window;
}

void SZFTestAvatarPhotos(void) {
    char state[SZFRIENDS_PATH_CAP];
    SZFExpect(szfriends_default_state_dir(state, sizeof state) == SZFRIENDS_OK, @"a test state directory");
    NSString *stateDirectory = @(state);
    NSString *pictures = [stateDirectory stringByAppendingPathComponent:@"pictures"];
    [NSFileManager.defaultManager removeItemAtPath:pictures error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:pictures withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions : @0700} error:nil];
    SZFTestWhatLoads(stateDirectory, pictures);
    SZFTestLoadedOffTheMainThread(pictures);
    SZFriendsForgetAvatarPhotos();
    [NSFileManager.defaultManager removeItemAtPath:pictures error:nil];
    [NSFileManager.defaultManager removeItemAtPath:[stateDirectory stringByAppendingPathComponent:@"picturesX"]
                                             error:nil];
    unlink([stateDirectory stringByAppendingPathComponent:@"outside.jpg"].fileSystemRepresentation);
}
