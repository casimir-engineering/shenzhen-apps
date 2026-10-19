#import "SPDFMacTabLifecycle.h"

@interface SPDFMacTabLifecycle ()
@property(nonatomic, strong) NSMutableArray* activationHistory;
@property(nonatomic, strong, nullable) id selectedIdentifier;
@end

static NSInteger spdf_index_of_identical_identifier(NSArray* identifiers, id identifier) {
    if (!identifier) return NSNotFound;
    for (NSUInteger index = 0; index < identifiers.count; ++index) {
        if (identifiers[index] == identifier) return (NSInteger)index;
    }
    return NSNotFound;
}

static BOOL spdf_contains_identical_identifier(NSArray* identifiers, id identifier) {
    return spdf_index_of_identical_identifier(identifiers, identifier) != NSNotFound;
}

@protocol SPDFTabViewing <NSObject>
- (void)setLastViewedAt:(NSTimeInterval)time;
@end

@implementation SPDFMacTabLifecycle

- (instancetype)init {
    self = [super init];
    if (self) _activationHistory = [NSMutableArray array];
    return self;
}

- (void)reset {
    [_activationHistory removeAllObjects];
    _selectedIdentifier = nil;
}

- (void)recordActivationOfIdentifier:(id)identifier {
    if ([identifier respondsToSelector:@selector(setLastViewedAt:)])
        [(id<SPDFTabViewing>)identifier setLastViewedAt:NSDate.timeIntervalSinceReferenceDate];
    if (!identifier) return;
    NSInteger existingIndex = spdf_index_of_identical_identifier(_activationHistory, identifier);
    if (existingIndex != NSNotFound) [_activationHistory removeObjectAtIndex:(NSUInteger)existingIndex];
    [_activationHistory insertObject:identifier atIndex:0];
    _selectedIdentifier = identifier;
}

- (id)removeIdentifier:(id)identifier
         fromOrderedIdentifiers:(NSArray*)orderedIdentifiers
         preferMostRecentActive:(BOOL)preferMostRecentActive {
    if (!identifier) return nil;
    BOOL removingSelected = _selectedIdentifier == identifier;

    for (NSInteger index = (NSInteger)_activationHistory.count - 1; index >= 0; --index) {
        id candidate = _activationHistory[(NSUInteger)index];
        if (candidate == identifier || !spdf_contains_identical_identifier(orderedIdentifiers, candidate))
            [_activationHistory removeObjectAtIndex:(NSUInteger)index];
    }
    if (!removingSelected) return nil;

    _selectedIdentifier = nil;
    id replacement = nil;
    if (preferMostRecentActive) replacement = _activationHistory.firstObject;

    if (!replacement) {
        NSInteger removedIndex = spdf_index_of_identical_identifier(orderedIdentifiers, identifier);
        if (removedIndex != NSNotFound) {
            NSInteger adjacentIndex = removedIndex + 1 < (NSInteger)orderedIdentifiers.count ? removedIndex + 1
                                                                                              : removedIndex - 1;
            if (adjacentIndex >= 0 && adjacentIndex < (NSInteger)orderedIdentifiers.count)
                replacement = orderedIdentifiers[(NSUInteger)adjacentIndex];
        }
    }

    if (replacement) [self recordActivationOfIdentifier:replacement];
    return replacement;
}

@end

BOOL spdf_mac_tab_close_action_enabled(NSInteger tabCount, NSInteger selectedIndex, BOOL hasOpenDocument) {
    return hasOpenDocument || (selectedIndex >= 0 && selectedIndex < tabCount);
}
