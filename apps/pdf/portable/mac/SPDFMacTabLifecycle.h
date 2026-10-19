#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Pure tab identity/history policy. Identifiers are compared by object identity,
// so callers can reorder tabs or change their paths without corrupting history.
@interface SPDFMacTabLifecycle : NSObject

- (void)reset;
- (void)recordActivationOfIdentifier:(id)identifier;

// orderedIdentifiers is the pre-removal tab order. Removing the active tab
// returns its replacement; removing an inactive tab returns nil. MRU restoration
// falls back to the deterministic adjacent policy when history has no survivor.
- (nullable id)removeIdentifier:(id)identifier
         fromOrderedIdentifiers:(NSArray*)orderedIdentifiers
         preferMostRecentActive:(BOOL)preferMostRecentActive;

@end

BOOL spdf_mac_tab_close_action_enabled(NSInteger tabCount, NSInteger selectedIndex, BOOL hasOpenDocument);

NS_ASSUME_NONNULL_END
