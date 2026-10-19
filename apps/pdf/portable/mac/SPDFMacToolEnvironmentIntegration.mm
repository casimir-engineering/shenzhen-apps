#import "SPDFMacToolEnvironment.h"

// The app-facing half of SPDFMacToolEnvironment.h: the environment every
// external tool is launched with. Split from the pure builders so those can be
// linked, and tested, without the whole app delegate.

@implementation ShenzhenMacDelegate (SPDFMacToolEnvironment)

- (NSDictionary<NSString*, NSString*>*)taskEnvironmentWithToolPaths:(NSArray<NSString*>*)toolPaths {
    return [self taskEnvironmentWithToolPaths:toolPaths extra:nil];
}

- (NSDictionary<NSString*, NSString*>*)taskEnvironmentWithToolPaths:(NSArray<NSString*>*)toolPaths
                                                              extra:(NSDictionary<NSString*, NSString*>*)extra {
    return spdf_mac_tool_environment(NSProcessInfo.processInfo.environment, toolPaths, extra);
}

@end
