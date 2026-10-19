// Shenzhen Friends pictures: the bundled cartoon animal set and the pipeline for people's own photos.
//
// Foundation only, so both the helper (validates and re-encodes pictures) and the AppKit views (draw an animal
// from the app's own copy) include it. GTK views read the same set from avatars/animals/manifest.json and
// draw the SVGs directly; this header is the Objective-C side of that manifest.
//
// An animal travels between friends as (set version, index), never as pixels, so every app draws it crisply
// from its own copy and a friend's picture costs nothing to send. An index this copy does not know falls
// back to a placeholder (initials on a colored circle) instead of failing (brief § Product contract).
//
// avatars/animals/manifest.json, read by this class and directly by GTK views:
//   {"set": 1, "count": N, "animals": [{"index": 0, "name": "Goose", "color": "#5a4a7a",
//                                       "svg": "svg/00-goose.svg", "pdf": "pdf/00-goose.pdf"}, ...]}
// Paths are relative to the manifest. A PROTOCOL.md avatar of kind "animal" carries that animal's "color", so
// set 1 must keep the colors the golden fixtures use: index 0 #5a4a7a, 1 #2f6474, 3 #7a3f4f, 4 #4a6a2f,
// 5 #7a5a34, 7 #3f6b4f, 9 #4f4f86, 10 #5a5a66, 11 #6a4a6a. The PDFs are generated from the SVGs by
// avatars/tools/regenerate-pdfs.sh; the build never needs the converter. Each PDF is one 64 x 64 pt page.
//
// Where an app keeps its copy (bundledSet): <bundle>/Contents/Resources/Friends/animals/manifest.json with svg/
// and pdf/ beside it. A helper app nested in Contents/Helpers/ of a host app reads the host app's copy, so the set
// ships once per app.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SZFriendsPictureKind) {
    SZFriendsPictureKindPlaceholder = 0, // initials on a colored circle; also the fallback for unknown animals
    SZFriendsPictureKindAnimal = 1,      // (animalSet, animalIndex) into the bundled set
    SZFriendsPictureKindImage = 2,       // a re-encoded photo stored by the helper
};

@class SZFriendsAnimalSet;

// A person's picture as stored, exchanged and rendered. Immutable value; shared by store, session and
// presentation so the three never disagree on what a picture is. Equal pictures compare equal with isEqual:.
@interface SZFriendsPicture : NSObject <NSCopying, NSSecureCoding>
@property(nonatomic, readonly) SZFriendsPictureKind kind;
@property(nonatomic, readonly) NSInteger animalSet;   // >= 1 for animals, 0 otherwise
@property(nonatomic, readonly) NSInteger animalIndex; // >= 0 for animals, -1 otherwise
// Absolute path of the helper's re-encoded copy for images, named by its content hash so a changed photo
// never reuses a cached file. Nil for animals and placeholders.
@property(nonatomic, readonly, nullable) NSString *imagePath;
@property(nonatomic, readonly, nullable) NSData *imageSHA256;

+ (instancetype)placeholder;
// Stores whatever a friend sent, even an index this copy lacks: it renders as a placeholder until an update
// brings that animal. Values below the ranges above (set < 1, index < 0) give the placeholder instead.
+ (instancetype)animalWithSet:(NSInteger)set index:(NSInteger)index;
+ (instancetype)imageAtPath:(NSString *)path sha256:(NSData *)sha256;

// PROTOCOL.md avatar object fields that come from the picture: kind, set, index, path, and for a known animal its
// color from the set. The presentation layer adds initials, and SZFriendsPlaceholderColor(conversation id) as
// the color of placeholders and images. Unknown animals (validated against `set`) come out as "placeholder",
// and so does every animal when `set` is nil (a damaged bundle).
- (NSDictionary<NSString *, id> *)protocolFieldsValidatedAgainst:(nullable SZFriendsAnimalSet *)set;
@end

// One version of the bundled animal set. Versions only grow: an animal keeps its index forever, so a friend
// on an older app still draws the same animal or, for indexes it lacks, a placeholder.
@interface SZFriendsAnimalSet : NSObject
// The newest set bundled in this app, loaded lazily from its manifest (location above) and cached. Nil when the
// bundle is damaged. SZFRIENDS_AVATARS_MANIFEST, an absolute path, replaces the bundle lookup for helpers run
// outside an app bundle (the two-helper harness, probes).
+ (nullable instancetype)bundledSet;
// For tests and probes: a set loaded from a manifest file (avatars/animals/manifest.json). Rejects a manifest
// whose count, indexes, colors or paths are malformed; paths must stay inside the manifest's directory.
+ (nullable instancetype)setWithManifestAtPath:(NSString *)path error:(NSError **)error;

@property(nonatomic, readonly) NSInteger version;
@property(nonatomic, readonly) NSInteger count;
- (BOOL)containsIndex:(NSInteger)index;
// English name ("Goose"), for accessibility descriptions on the profile page's picker only.
- (nullable NSString *)nameAtIndex:(NSInteger)index;
// Background circle color as "#rrggbb" sRGB, chosen to read in light and dark appearances.
- (nullable NSString *)colorAtIndex:(NSInteger)index;
// Vector source (SVG, for GTK) and generated PDF (for AppKit), crisp from 28 pt to 64 pt at 1x and 2x.
// Absolute paths; nil for an index outside the set.
- (nullable NSString *)svgPathAtIndex:(NSInteger)index;
- (nullable NSString *)pdfPathAtIndex:(NSInteger)index;
// The default picture at first launch. `randomValue` is injected so tests are deterministic.
- (NSInteger)indexForRandomValue:(uint32_t)randomValue;
// The helper's first-launch picture: a uniformly random animal of this set.
- (SZFriendsPicture *)randomDefaultPicture;
@end

// Limits a picked or dropped photo must pass before the helper decodes it. Checked before decoding so a
// hostile file costs no memory (brief § Transfers: strict size and dimension limits).
extern const NSUInteger SZFriendsPictureMaxInputBytes;   // 5 MiB
extern const NSUInteger SZFriendsPictureMaxInputPixels;  // 8192 on the longer side
extern const NSUInteger SZFriendsPictureOutputPixels;    // 256 x 256, the only size ever stored or sent
// 48 KiB (49,152 bytes) after re-encoding: a picture travels in one PROFILE session frame, whose plaintext is
// capped at 65,519 bytes (ADR 0001); the encoder lowers JPEG quality until the result fits.
extern const NSUInteger SZFriendsPictureMaxOutputBytes;

// Errors from the pipeline and from set_picture parsing. userInfo carries the PROTOCOL.md error code under
// SZFriendsPictureErrorCodeKey ("invalid_field", "picture_invalid", "file_missing" or "internal"), the field
// under SZFriendsPictureErrorFieldKey for invalid_field ("picture.crop"), and NSFilePathErrorKey for
// file_missing, so the helper builds its reply (error.details) without mapping codes. localizedDescription is
// display-ready for the person choosing their own picture.
extern NSErrorDomain const SZFriendsPictureErrorDomain;
extern NSString *const SZFriendsPictureErrorCodeKey;
extern NSString *const SZFriendsPictureErrorFieldKey;
typedef NS_ERROR_ENUM(SZFriendsPictureErrorDomain, SZFriendsPictureError) {
    SZFriendsPictureErrorInvalidField = 1, // invalid_field: malformed intent, unavailable animal, crop off the image
    SZFriendsPictureErrorTooLarge = 2,     // picture_invalid: over the byte or pixel limits, or a decompression bomb
    SZFriendsPictureErrorUnreadable = 3,   // picture_invalid: not a complete image in an accepted format
    SZFriendsPictureErrorFileMissing = 4,  // file_missing: `path` does not exist or cannot be read
    SZFriendsPictureErrorInternal = 5,     // internal: encoding or writing failed
};

// Helper-side pipeline: ImageIO decode, square crop, resize, re-encode. Runs only in the helper, never in an
// app, so a malformed image can at worst stop the helper's own work, never a reader window. Output is a baseline
// sRGB JPEG with no metadata segment at all (no EXIF, GPS, camera, color profile or comment; an untagged JPEG is
// sRGB), the same bytes for the same pixels, so a photo's location or camera never reaches a friend.
@interface SZFriendsPicturePipeline : NSObject
// Accepted inputs: JPEG, PNG, HEIC/HEIF and WebP (the first image of a sequence). `crop` is a square in
// the picture's displayed pixels (after its EXIF orientation), origin at the top left, as the crop view shows
// it; NSZeroRect means the centered largest square. Returns JPEG data of SZFriendsPictureOutputPixels square
// and at most SZFriendsPictureMaxOutputBytes, or nil with an error whose localizedDescription is display-ready.
+ (nullable NSData *)normalizedImageFromData:(NSData *)data crop:(NSRect)crop error:(NSError **)error;
// Validates a picture received from a friend: dimensions, size and decodability. Never trusts the sender:
// only a whole baseline JPEG of exactly 256 x 256 and at most 48 KiB passes, checked from its markers before
// ImageIO parses anything, then decoded.
+ (BOOL)validateReceivedImage:(NSData *)data error:(NSError **)error;
// Validates as above, then re-encodes it the way own pictures are, so the views (in reader processes) only ever
// decode JPEGs this helper wrote, and nothing the sender embedded survives.
+ (nullable NSData *)normalizedReceivedImage:(NSData *)data error:(NSError **)error;

// Writes normalized JPEG data into `directory` (created 0700 if missing) as <sha256 hex>.jpg, atomically and
// mode 0600, and returns the image picture for it. An identical existing file is reused.
+ (nullable SZFriendsPicture *)storeImage:(NSData *)jpeg inDirectory:(NSString *)directory error:(NSError **)error;
// A set_picture intent's `picture` object (PROTOCOL.md), end to end: an animal must be in `set` (the person can
// only choose an animal this app offers); a photo is read from `data_base64` or `path` (a regular file the
// app's file picker returned), normalized with its optional `crop` ({x, y, side} in displayed pixels) and stored
// in `directory`.
+ (nullable SZFriendsPicture *)pictureFromIntentPicture:(id)picture
                                              animalSet:(nullable SZFriendsAnimalSet *)set
                                      picturesDirectory:(NSString *)directory
                                                  error:(NSError **)error;
@end

// Initials for a placeholder: first letters of the first two words, uppercased ("Lena Weber" -> "LW", "Raph" ->
// "R"); a Friends ID gives the first letter of each of its first two words ("orchid-summit" -> "OS"). A "letter"
// is a whole character as people see it (é, 王, an emoji), and leading punctuation is skipped.
NSString *SZFriendsInitials(NSString *nameOrFriendsID);

// Stable placeholder circle color for a seed (conversation id), "#rrggbb", from a fixed palette that keeps
// white initials above 4.5:1 contrast.
NSString *SZFriendsPlaceholderColor(NSString *seed);

NS_ASSUME_NONNULL_END
