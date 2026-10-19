#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Internal numeric parser shared by updater decisions and install recovery.
/// Malformed input returns nil; separators are period, space, and hyphen.
NSArray<NSNumber*>* _Nullable spdf_version_components(NSString* _Nullable version);

NS_ASSUME_NONNULL_END
