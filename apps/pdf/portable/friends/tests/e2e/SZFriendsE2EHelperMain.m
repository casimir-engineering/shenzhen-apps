// The helper the two-helper harness runs: the production helper objects with this main in place of main.m.
//
// It only translates the harness's variables into SZFriendsHelperTestHooks before handing over to the real
// SZFriendsHelperMain, so everything else (lock, store, identity, IPC, nearby, delivery) is the shipped code. The
// shipped main never sets these hooks. Refuses to start without SZFRIENDS_STATE_DIR, so a stray run of this binary
// can never touch the real Friends state or the Keychain.
//   SZFRIENDS_E2E_WITHHOLD_ACKS=1   commit what arrives but never acknowledge it
//   SZFRIENDS_E2E_CHUNK_RATE=<n>    at most n chunk bytes per second
//   SZFRIENDS_E2E_CLOCK_OFFSET=<s>  seconds added to the clock the outbox expiry reads
//   SZFRIENDS_E2E_BLUETOOTH_DIR=<d> run the scripted slow Bluetooth adapter, meeting other helpers in <d>
//   SZFRIENDS_E2E_IDLE_TIMEOUT=<s>  a stranger's quiet session ends after <s> seconds instead of 60
//   SZFRIENDS_E2E_SESSION_LIFE=<s>  a stranger's session ends <s> seconds after going live instead of 180
//   SZFRIENDS_E2E_FRIENDS_ID=<id>   a first start takes this Friends ID (two holders of one unreserved ID)
//   SZFRIENDS_E2E_NEARBY_SCRIPT=<f> add a network method whose permission and state <f> names
//                                   (SZFriendsE2EScriptedNearby.h), for the Nearby cards
//   SZFRIENDS_E2E_DEVICE_NAME=<n>   this computer's name, in place of the Mac's own
//   SZFRIENDS_E2E_DEVICE_SYSTEM=<s> this computer's system, in place of the Mac's macOS version

#import <Foundation/Foundation.h>

#import "SZFriendsE2EBluetooth.h"
#import "SZFriendsE2EScriptedNearby.h"
#import "service/helper/SZFriendsHelper.h"
#import "service/helper/SZFriendsHelperTesting.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSDictionary<NSString *, NSString *> *env = [NSProcessInfo processInfo].environment;
        if (env[@"SZFRIENDS_STATE_DIR"].length == 0) {
            fprintf(stderr, "szfriends-e2e-helper: SZFRIENDS_STATE_DIR must be set\n");
            return 2;
        }
        SZFriendsHelperTestHooks.withholdAcknowledgements = [env[@"SZFRIENDS_E2E_WITHHOLD_ACKS"] isEqual:@"1"];
        SZFriendsHelperTestHooks.chunkBytesPerSecond = env[@"SZFRIENDS_E2E_CHUNK_RATE"].doubleValue;
        SZFriendsHelperTestHooks.outboxClockOffset = env[@"SZFRIENDS_E2E_CLOCK_OFFSET"].doubleValue;
        SZFriendsHelperTestHooks.strangerIdleTimeout = env[@"SZFRIENDS_E2E_IDLE_TIMEOUT"].doubleValue;
        SZFriendsHelperTestHooks.strangerSessionLife = env[@"SZFRIENDS_E2E_SESSION_LIFE"].doubleValue;
        NSString *friendsID = env[@"SZFRIENDS_E2E_FRIENDS_ID"];
        if (friendsID.length > 0) SZFriendsHelperTestHooks.initialFriendsID = friendsID;
        SZFriendsHelperTestHooks.deviceName = env[@"SZFRIENDS_E2E_DEVICE_NAME"];
        SZFriendsHelperTestHooks.deviceSystem = env[@"SZFRIENDS_E2E_DEVICE_SYSTEM"];
        NSString *bluetooth = env[@"SZFRIENDS_E2E_BLUETOOTH_DIR"];
        NSString *script = env[@"SZFRIENDS_E2E_NEARBY_SCRIPT"];
        if (bluetooth.length > 0 || script.length > 0) {
            SZFriendsHelperTestHooks.extraAdapters = ^NSArray<id<SZFriendsDiscoveryAdapter>> *(dispatch_queue_t queue) {
                NSMutableArray<id<SZFriendsDiscoveryAdapter>> *adapters = [NSMutableArray array];
                if (bluetooth.length > 0) [adapters addObject:SZFriendsE2EMakeScriptedBluetoothAdapter(queue, bluetooth)];
                if (script.length > 0) [adapters addObject:SZFriendsE2EMakeScriptedNearbyAdapter(queue, script)];
                return adapters;
            };
        }
    }
    return SZFriendsHelperMain(argc, argv);
}
