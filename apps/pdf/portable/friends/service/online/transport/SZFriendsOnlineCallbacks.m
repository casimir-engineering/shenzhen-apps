// The bridge from libdatachannel's C callbacks, which run on the stack's own threads, to the peer connection
// objects. Handles are looked up in a registry of weak references rather than passed as user pointers, so a
// callback racing -close or deallocation finds nothing instead of a freed object. Nothing here logs.

#import "service/online/transport/SZFriendsOnlinePeerConnection.h"

#include <os/lock.h>
#include <rtc/rtc.h>

static os_unfair_lock gRegistryLock = OS_UNFAIR_LOCK_INIT;
static NSMapTable<NSNumber *, SZFriendsOnlinePeerConnection *> *gRegistry;

void SZFriendsOnlineRegisterHandle(int handle, SZFriendsOnlinePeerConnection *connection) {
    os_unfair_lock_lock(&gRegistryLock);
    if (gRegistry == nil) gRegistry = [NSMapTable strongToWeakObjectsMapTable];
    [gRegistry setObject:connection forKey:@(handle)];
    os_unfair_lock_unlock(&gRegistryLock);
}

void SZFriendsOnlineUnregisterHandle(int handle) {
    os_unfair_lock_lock(&gRegistryLock);
    [gRegistry removeObjectForKey:@(handle)];
    os_unfair_lock_unlock(&gRegistryLock);
}

static SZFriendsOnlinePeerConnection *Lookup(int handle) {
    os_unfair_lock_lock(&gRegistryLock);
    SZFriendsOnlinePeerConnection *connection = [gRegistry objectForKey:@(handle)];
    os_unfair_lock_unlock(&gRegistryLock);
    return connection;
}

#pragma mark - Peer connection callbacks

static void RTC_API OnDescription(int pc, const char *sdp, const char *type, void *ptr) {
    (void)type;
    (void)ptr;
    SZFriendsOnlinePeerConnection *connection = Lookup(pc);
    NSString *text = sdp ? @(sdp) : nil;
    if (connection && text) [connection stackDidCreateDescription:text];
}

static void RTC_API OnCandidate(int pc, const char *candidate, const char *mid, void *ptr) {
    (void)mid;
    (void)ptr;
    SZFriendsOnlinePeerConnection *connection = Lookup(pc);
    NSString *text = candidate ? @(candidate) : nil;
    if (connection && text) [connection stackDidGatherCandidate:text];
}

static void RTC_API OnState(int pc, rtcState state, void *ptr) {
    (void)ptr;
    [Lookup(pc) stackStateDidChange:(SZFriendsOnlinePCState)state];
}

static void RTC_API OnICEState(int pc, rtcIceState state, void *ptr) {
    (void)ptr;
    if (state == RTC_ICE_CONNECTED || state == RTC_ICE_COMPLETED) [Lookup(pc) stackICEDidConnect];
}

static void RTC_API OnGathering(int pc, rtcGatheringState state, void *ptr) {
    (void)ptr;
    if (state == RTC_GATHERING_COMPLETE) [Lookup(pc) stackGatheringDidComplete];
}

// The answerer's side of the offerer's channel. It is open when this runs. Only a reliable, ordered channel can carry
// ADR 0001's stream; anything else the peer opens is closed unheard.
static void RTC_API OnDataChannel(int pc, int dc, void *ptr) {
    (void)ptr;
    SZFriendsOnlinePeerConnection *connection = Lookup(pc);
    rtcReliability reliability;
    memset(&reliability, 0, sizeof reliability);
    BOOL usable = connection != nil && rtcGetDataChannelReliability(dc, &reliability) == RTC_ERR_SUCCESS &&
                  !reliability.unordered && !reliability.unreliable;
    if (!usable) {
        dispatch_async(SZFriendsOnlineTeardownQueue(), ^{
            rtcDelete(dc);
        });
        return;
    }
    SZFriendsOnlineRegisterHandle(dc, connection);
    SZFriendsOnlineInstallChannelCallbacks(dc);
    [connection stackChannelDidOpen:dc];
}

void SZFriendsOnlineInstallPeerCallbacks(int pc) {
    rtcSetLocalDescriptionCallback(pc, OnDescription);
    rtcSetLocalCandidateCallback(pc, OnCandidate);
    rtcSetStateChangeCallback(pc, OnState);
    rtcSetIceStateChangeCallback(pc, OnICEState);
    rtcSetGatheringStateChangeCallback(pc, OnGathering);
    rtcSetDataChannelCallback(pc, OnDataChannel);
}

#pragma mark - Data channel callbacks

static void RTC_API OnOpen(int dc, void *ptr) {
    (void)ptr;
    [Lookup(dc) stackChannelDidOpen:dc];
}

static void RTC_API OnMessage(int dc, const char *message, int size, void *ptr) {
    (void)ptr;
    SZFriendsOnlinePeerConnection *connection = Lookup(dc);
    if (connection == nil) return;
    // A negative size marks a text message: ADR 0001 is binary, so text is a protocol error.
    if (size < 0 || message == NULL) {
        [connection stackChannelDidReceiveText:dc];
        return;
    }
    [connection stackChannel:dc didReceive:[NSData dataWithBytes:message length:(NSUInteger)size]];
}

static void RTC_API OnClosed(int dc, void *ptr) {
    (void)ptr;
    [Lookup(dc) stackChannelDidClose:dc];
}

static void RTC_API OnError(int dc, const char *error, void *ptr) {
    (void)error; // never logged: it may name addresses
    (void)ptr;
    [Lookup(dc) stackChannelDidClose:dc];
}

static void RTC_API OnBufferedAmountLow(int dc, void *ptr) {
    (void)ptr;
    [Lookup(dc) stackChannelBufferedAmountLow:dc];
}

void SZFriendsOnlineInstallChannelCallbacks(int dc) {
    rtcSetOpenCallback(dc, OnOpen);
    rtcSetMessageCallback(dc, OnMessage);
    rtcSetClosedCallback(dc, OnClosed);
    rtcSetErrorCallback(dc, OnError);
    rtcSetBufferedAmountLowThreshold(dc, (int)SZFriendsOnlineChannelLowWater);
    rtcSetBufferedAmountLowCallback(dc, OnBufferedAmountLow);
}
