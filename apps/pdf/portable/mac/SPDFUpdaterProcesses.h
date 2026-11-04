#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Running instances of the app `bundleID` other than this process.
NSUInteger spdf_running_instance_count(NSString* bundleID);

/// Run by the post-update helper just before it moves the old bundle aside. The Friends helper embedded in that bundle
/// keeps running after the app quits (it serves the other Shenzhen apps too), and once its bundle is gone the new app
/// cannot check the helper's signature. So it is asked to leave first: on SIGTERM it saves transfer progress, says
/// goodbye to the apps still connected and exits, and the new app then starts its own. Only this user's process
/// running exactly <targetBundlePath>/Contents/Helpers/Shenzhen Friends.app; waits 5 s at most.
void spdf_helper_stop_embedded_friends(NSString* targetBundlePath);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
