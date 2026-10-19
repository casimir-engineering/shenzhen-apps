// The production spawn and signing policy: the Friends client library's connect-or-spawn and
// szfriends_set_signing_policy(). Kept apart from SPDFMacFriendsLaunch.mm so the launch tests link a fake spawn and
// never start a real helper or change the process-wide policy.

#import "SPDFMacFriendsLaunch.h"
#import "SPDFMacFriendsSigning.h"
#include "client/szfriends_client.h"

// Once per process, before the first spawn or connect: the launch spawn's queue and the main thread's attach may both
// ask, and dispatch_once makes the second wait for the first rather than connect without the policy.
static void PrepareSigningOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SPDFMacFriendsApplySigningPolicy(^NSString* { return SPDFMacFriendsOwnTeamIdentifier(); },
                                         ^int(const char* team, SPDFMacFriendsPeerVerifier verifier) {
            return (int)szfriends_set_signing_policy(team, verifier, NULL);
        });
    });
}

SPDFMacFriendsLaunchEnvironment* SPDFMacFriendsDefaultLaunchEnvironment(void) {
    SPDFMacFriendsLaunchEnvironment* environment = [[SPDFMacFriendsLaunchEnvironment alloc]
        initWithSpawn:^int(NSString* helperPath, NSString* stateDirectory, pid_t* pid) {
            return (int)szfriends_spawn_helper(helperPath.fileSystemRepresentation,
                                               stateDirectory.length ? stateDirectory.fileSystemRepresentation : NULL,
                                               pid);
        }];
    environment.prepareSigning = ^{ PrepareSigningOnce(); };
    return environment;
}
