// Shared by the friends-avatars-check test files: a minimal check macro and builders for test images.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#import "avatars/SZFriendsAvatars.h"

NS_ASSUME_NONNULL_BEGIN

// Counts failures and keeps going, so one run reports every broken expectation, not just the first.
extern int SZTestFailures;
extern int SZTestChecks;
#define SZ_CHECK(condition, ...)                                                                                  \
    do {                                                                                                          \
        SZTestChecks++;                                                                                           \
        if (!(condition)) {                                                                                       \
            SZTestFailures++;                                                                                     \
            fprintf(stderr, "%s:%d: check failed: %s: %s\n", __FILE__, __LINE__, #condition,                      \
                    [[NSString stringWithFormat:__VA_ARGS__] UTF8String]);                                        \
        }                                                                                                         \
    } while (0)

// Paths handed to every suite by main().
typedef struct {
    NSString *manifestPath;  // friends/avatars/animals/manifest.json
    NSString *fixturesPath;  // friends/fixtures
    NSString *scratch;       // a fresh temporary directory, removed at exit
} SZTestContext;

void SZRunAnimalSetTests(SZTestContext context);
void SZRunFixtureReferenceTests(SZTestContext context);
void SZRunPictureTests(SZTestContext context);
void SZRunJPEGTests(SZTestContext context);
void SZRunPipelineTests(SZTestContext context);
void SZRunReceivedImageTests(SZTestContext context);
void SZRunIntentTests(SZTestContext context);

// A 64 x 64 lossless WebP of SZTestCreateQuadrants' colors (SZFriendsImageBytesTests.m).
extern const uint8_t SZTestWebP[66];

// The error's PROTOCOL.md code from userInfo, or nil.
NSString *_Nullable SZTestProtocolCode(NSError *_Nullable error);

// A width x height sRGB image filled by `draw` (origin bottom left, as Core Graphics draws).
CGImageRef SZTestCreateImage(size_t width, size_t height, void (^draw)(CGContextRef context)) CF_RETURNS_RETAINED;
// Four quadrants, top left red, top right green, bottom left blue, bottom right yellow, as a person sees them.
CGImageRef SZTestCreateQuadrants(size_t width, size_t height) CF_RETURNS_RETAINED;
// Encodes with ImageIO; `properties` may carry metadata dictionaries and the orientation.
NSData *SZTestEncode(CGImageRef image, NSString *type, NSDictionary *_Nullable properties);
// A valid PNG written byte by byte: `bitDepth`-bit grayscale, every pixel 0. ImageIO cannot write 1-bit PNGs.
NSData *SZTestGrayPNG(uint32_t width, uint32_t height, uint8_t bitDepth);
// The sRGB color at (x, y), origin top left, of a decoded image, as 0-255 components.
BOOL SZTestPixel(NSData *encoded, size_t x, size_t y, int rgb[_Nonnull 3]);
// True when every component is within `tolerance` of the expected value (JPEG is lossy).
BOOL SZTestNear(const int rgb[_Nonnull 3], int r, int g, int b, int tolerance);
// The JPEG's segment markers before the first scan (second byte of each: 0xE0, 0xDB...), walked independently of
// the code under test.
NSArray<NSNumber *> *SZTestJPEGMarkers(NSData *jpeg);
// The JPEG with one extra segment inserted right after SOI: marker byte and payload.
NSData *SZTestInsertSegment(NSData *jpeg, uint8_t marker, NSData *payload);
BOOL SZTestContains(NSData *haystack, NSString *needle);

NS_ASSUME_NONNULL_END
