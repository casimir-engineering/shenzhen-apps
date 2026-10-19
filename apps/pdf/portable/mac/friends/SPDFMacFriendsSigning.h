// The app's half of the Friends helper's peer check (ADR 0002 § Peer checks, portable/friends/README.md § protocol).
//
// In a team-signed ShenzhenPDF the client library must ignore SZFRIENDS_STATE_DIR and talk only to a helper signed by
// the same team. Otherwise any process running as the person could point the next launch at a socket of its own
// (launchctl setenv) and receive every message, file path and picture. The library is libc only, so the team and the
// signature check come from here, through Security.framework, set once before the first spawn or connect.
//
// Unsigned and ad-hoc builds (development, tests) have no Team ID, and nothing is set: they keep the library's uid
// check and honour SZFRIENDS_STATE_DIR, as the library's own default does.

#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stddef.h>

NS_ASSUME_NONNULL_BEGIN

// szfriends_peer_verifier's shape (client/szfriends_client.h), restated so this file needs no Friends include path.
typedef bool (*SPDFMacFriendsPeerVerifier)(void* _Nullable context, const void* _Nullable auditToken, size_t length,
                                           const char* requirement);
// szfriends_set_signing_policy, as a block so tests can record what the app would set. Returns its status (0: OK).
typedef int (^SPDFMacFriendsSetSigningPolicy)(const char* team, SPDFMacFriendsPeerVerifier verifier);

// The Team ID in this process's own code signature, or nil for unsigned and ad-hoc code or an unreadable signature.
NSString* _Nullable SPDFMacFriendsOwnTeamIdentifier(void);

// The verifier the library calls with a connected helper's audit token: YES only when that process's code is valid
// and meets `requirement` (the library passes the team requirement it builds). Any failure, a wrong token length
// included, is NO, so a signed app never falls back to trusting a helper it could not check.
bool SPDFMacFriendsVerifyPeer(void* _Nullable context, const void* _Nullable auditToken, size_t length,
                              const char* requirement);

// Reads the team with `teamIdentifier` and, when there is one, calls `setPolicy` with it and SPDFMacFriendsVerifyPeer.
// YES when it called `setPolicy`; NO for an unsigned build, which sets nothing.
BOOL SPDFMacFriendsApplySigningPolicy(NSString* _Nullable (^teamIdentifier)(void),
                                      SPDFMacFriendsSetSigningPolicy setPolicy);

NS_ASSUME_NONNULL_END
