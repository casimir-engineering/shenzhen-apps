// Schema model and validator for the ```schema blocks in portable/friends/PROTOCOL.md.
//
// Test-only; used by SZFriendsProtocolTests.m. Split from it so the validator and the fixture walk each stay a
// readable size. The grammar is documented in PROTOCOL.md § Schemas.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SZFRule : NSObject
@property(nonatomic, copy) NSArray<NSString *> *segments; // "rows[]" marks fan-out over an array
@property(nonatomic) BOOL optional;
@property(nonatomic, copy) NSArray<NSString *> *types;
@property(nonatomic, copy, nullable) NSString *whenPath;
@property(nonatomic, copy, nullable) NSSet<NSString *> *whenValues;
@property(nonatomic, copy) NSString *source;
@end

typedef NSDictionary<NSString *, NSArray<SZFRule *> *> SZFSchemas;

// Failure count and reporting shared by the validator and the test driver. While `SZFQuiet` is set (the self-test
// provoking failures on purpose) failures are counted but not printed.
extern int SZFFailures;
extern BOOL SZFQuiet;
void SZFFail(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
// While set, every `type.*` block an object matched during validation is added here, so a caller can tell which
// shared objects its inputs exercised.
extern NSMutableSet<NSString *> *_Nullable SZFTypesMatched;

// Parses every ```schema <id> block; reports unparsable rules, unknown types and undefined @references.
SZFSchemas *SZFParseSchemas(NSString *markdown, NSString *label);

// Applies the rules of every schema in `schemaIDs` to `object` (a reply fixture uses frame.reply and
// result.<intent> together), then reports fields that none of them declares. Typed objects (@name) are checked
// against their own block the same way.
void SZFValidate(NSDictionary *object, NSArray<NSString *> *schemaIDs, SZFSchemas *schemas, NSString *where,
                 NSMutableArray<NSString *> *errors);

NS_ASSUME_NONNULL_END
