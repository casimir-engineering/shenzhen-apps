// What the thumbnails suite's files share: the check macro, its failure count, and image helpers.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern int SZTFailures;
void SZTFail(const char *file, int line, const char *expression, NSString *detail);
#define SZT_CHECK(condition, ...)                                                                                     \
    do {                                                                                                              \
        if (!(condition)) SZTFail(__FILE__, __LINE__, #condition, [NSString stringWithFormat:@"" __VA_ARGS__]);       \
    } while (0)

// width * height RGBA pixels: random noise, a smooth gradient, or one colour.
NSData *SZTNoise(NSUInteger width, NSUInteger height, BOOL opaque);
NSData *SZTGradient(NSUInteger width, NSUInteger height);
NSData *SZTSolid(NSUInteger width, NSUInteger height, uint32_t rgba);
// Decodes PNG bytes with ImageIO (the test's independent reader) into straight-alpha RGBA; nil when it cannot.
NSData *_Nullable SZTDecodePNG(NSData *png, NSUInteger *width, NSUInteger *height);
// A fresh private directory for one test; SZTRemoveScratch deletes every one made.
NSString *SZTScratchDirectory(void);
void SZTRemoveScratch(void);

void SZTRunCodecTests(void);
void SZTRunThumbnailTests(void);
void SZTRunRenderTests(void);

NS_ASSUME_NONNULL_END
