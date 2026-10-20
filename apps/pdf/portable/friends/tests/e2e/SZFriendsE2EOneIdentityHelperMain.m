// The helper friends-one-identity-check embeds in its test apps and runs for its computers: the production helper
// objects with this main in place of main.m, the online e2e helper's test hooks (SZFriendsE2EOnlineHelperMain.m:
// loopback peer connections, the online-block-direct file, SIGUSR1 as a network change), and no per-address admission
// rates, since every helper here shares 127.0.0.1.
//
// The apps start it as they start the shipped helper, with no SZFRIENDS_STATE_DIR: it then finds its Friends home under
// $HOME with the shipped helper's own rule (SZFriendsStatePaths). So that a stray run can never reach the person's
// real Friends home or the Keychain, it starts that way only in a test home: SZFRIENDS_E2E_TEST_HOME must name $HOME,
// $HOME must not be the account's home directory, and the key store must be the file one. It then names that home in
// SZFRIENDS_STATE_DIR for the rest of the helper, which is what makes the helper a test one: loopback Bonjour of the
// test type only, never a Wi-Fi browser or a Bluetooth manager, which would ask the person for access
// (SZFriendsHelperMakeAdapters). With SZFRIENDS_STATE_DIR already set (the harness's own helpers) it starts as the
// online e2e helper does.

#import <Foundation/Foundation.h>

#import <pwd.h>
#import <signal.h>
#import <unistd.h>

#import "service/helper/SZFriendsHelper.h"
#import "service/helper/SZFriendsHelperInternal.h"
#import "service/helper/SZFriendsHelperTesting.h"
#import "service/helper/nearby/SZFriendsNearbyLimits.h"
#import "service/online/driver/SZFriendsOnlineDriver.h"

static dispatch_source_t SZFE2EOneIDNetworkSignal;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSDictionary<NSString *, NSString *> *env = [NSProcessInfo processInfo].environment;
        NSString *state = env[@"SZFRIENDS_STATE_DIR"];
        if (state.length == 0) {
            NSString *home = env[@"HOME"].stringByStandardizingPath;
            struct passwd *account = getpwuid(getuid());
            NSString *real = account && account->pw_dir ? @(account->pw_dir).stringByStandardizingPath : nil;
            NSString *declared = env[@"SZFRIENDS_E2E_TEST_HOME"].stringByStandardizingPath;
            BOOL testHome = home.length > 1 && [declared isEqual:home] && ![home isEqual:real] &&
                            [env[@"SZFRIENDS_KEY_STORE"] isEqual:@"file"];
            if (!testHome) {
                fprintf(stderr, "szfriends-e2e-oneid-helper: no SZFRIENDS_STATE_DIR and no test home\n");
                return 2;
            }
            state = [SZFriendsStatePaths defaultStateDirectoryWithEnvironment:env];
            setenv("SZFRIENDS_STATE_DIR", state.fileSystemRepresentation, 1);
        }
        // Every helper of the scenario dials from 127.0.0.1: the per-address rates, which tell computers apart by their
        // addresses, would count Ana's two computers, Ben and Cara as one (SZFriendsNearbyLimits.m). The per-listener
        // rates stay.
        SZFriendsAdmissionLimits *limits = [SZFriendsNearbyAdmissionLimits() copy];
        limits.xxPerMinutePerAddress = 0;
        limits.nnPerMinutePerAddress = 0;
        SZFriendsHelperTestHooks.admissionLimits = limits;
        SZFriendsOnlineDriverTestHooks.loopbackOnly = YES;
        NSString *block = [state stringByAppendingPathComponent:@"online-block-direct"];
        SZFriendsOnlineDriverTestHooks.directPathsBlocked = ^BOOL {
            return [[NSFileManager defaultManager] fileExistsAtPath:block];
        };
        signal(SIGUSR1, SIG_IGN);
        SZFE2EOneIDNetworkSignal =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(SZFE2EOneIDNetworkSignal, ^{
            [SZFriendsOnlineDriverTestHooks simulateNetworkChange];
        });
        dispatch_resume(SZFE2EOneIDNetworkSignal);
    }
    return SZFriendsHelperMain(argc, argv);
}
