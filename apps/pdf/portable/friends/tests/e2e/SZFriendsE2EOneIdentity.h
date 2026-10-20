// friends-one-identity-check: one person's Shenzhen Friends is one identity, one helper and one history on each of
// their computers, whichever of ShenzhenPDF, Shenzhen Files and Shenzhen 3D run there, and one profile across the
// computers they joined (brief § One identity per Mac user; friends-multi-device.md; PROTOCOL.md § Lifecycle).
//
// One computer: the three apps run as processes of their own in one test home ($HOME, with nothing telling them where
// Friends lives), each with the real Friends views of its toolkit and the helper its bundle embeds (oneid.mk):
//   ShenzhenPDF     szfriends_e2e_appkit_app.m: the AppKit helper link, dropdown and pages, in process
//   Shenzhen Files  szfriends_e2e_gtk_views_app.c: the GTK link, button and dropdown, as Files' adapter hosts them
//   Shenzhen 3D     apps/3d/electron/friends-one-identity-app.mjs: the packaged Electron shell with its Friends host
//                   and React panel, hidden, driven by Playwright
// They are driven over stdin and stdout (SZFriendsE2EApps.h): protocol-level lines, and ui_* lines that type into the
// real composer and read what the real views show. A friend, Ben, is a harness helper of his own.
//
// Two computers: harness helpers on state directories of their own, joined into one profile with the code, nearby
// (loopback Bonjour) and online (the local Node host and coturn, SZFriendsE2EOnline.h), driven as the apps drive them.

#import "SZFriendsE2EApps.h"
#import "SZFriendsE2EDevices.h"

NS_ASSUME_NONNULL_BEGIN

BOOL SZFE2EOneIDScenarioStartOrders(SZFE2EWorld *world);
BOOL SZFE2EOneIDScenarioRealViews(SZFE2EWorld *world);
BOOL SZFE2EOneIDScenarioBuilds(SZFE2EWorld *world);
BOOL SZFE2EOneIDScenarioCrash(SZFE2EWorld *world);
BOOL SZFE2EOneIDScenarioHome(SZFE2EWorld *world);

BOOL SZFE2EOneIDScenarioComputersNearby(SZFE2EWorld *world);
BOOL SZFE2EOneIDScenarioComputersOnline(SZFE2EWorld *world);
BOOL SZFE2EOneIDScenarioComputersAway(SZFE2EWorld *world);

NS_ASSUME_NONNULL_END
