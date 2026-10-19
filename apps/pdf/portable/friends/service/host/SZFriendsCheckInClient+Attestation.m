// The check-in client's newest ID attestation (HOST-PROTOCOL.md § ID attestations): taken from a verified
// reservation answer when it checks out for this identity and the reserved ID, kept in attestationPath across
// launches, and handed to the helper for Add by ID answers while it still checks out. The queue writes; any thread
// reads, so the two ivars are touched only under @synchronized(self).

#import "service/host/SZFriendsCheckInClientPrivate.h"
#import "service/host/SZFriendsHostInternal.h"
#import "service/identity/SZFriendsIdentity.h"

#import <os/log.h>

@implementation SZFriendsCheckInClient (Attestation)

// The Friends ID belongs to the person: the host attests it for their root key, which is this identity's own on the
// first device and the root its membership names on a device that joined (HOST-PROTOCOL.md § Devices).
- (NSData *)attestedKey {
    NSData *chain = nil;
    NSData *root = _personKey ?: (self.membershipProvider ? self.membershipProvider(&chain) : nil);
    return root.length == 32 ? root : _identity.publicKey;
}

- (void)takeAttestation:(id)value forFriendsID:(NSString *)friendsID {
    // An older host sends none; the previous attestation stays, and -attestationForFriendsID: filters it by ID.
    if (value == nil || value == [NSNull null]) return;
    SZFriendsHostAttestation *attestation = [SZFriendsHostAttestation attestationFromDictionary:value];
    SZFriendsHostAttestationVerdict verdict =
        SZFriendsHostAttestationCheck(attestation, _cache.currentList, friendsID, [self attestedKey], [NSDate date]);
    if (verdict != SZFriendsHostAttestationValid) {
        // Never shown to anyone nearby: an attestation that does not check out here would not check out there.
        os_log_error(OS_LOG_DEFAULT, "Friends: a host attestation did not check out (%ld)", (long)verdict);
        return;
    }
    @synchronized(self) {
        _attestation = attestation;
        _attestationLoaded = YES;
    }
    [self writeAttestation:attestation];
    id<SZFriendsCheckInDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(checkInDidReceiveAttestation:)]) {
        [delegate checkInDidReceiveAttestation:attestation];
    }
}

- (SZFriendsHostAttestation *)keptAttestationForFriendsID:(NSString *)friendsID {
    SZFriendsHostAttestation *attestation = [self storedAttestation];
    if (attestation == nil || friendsID.length == 0) return nil;
    SZFriendsHostAttestationVerdict verdict =
        SZFriendsHostAttestationCheck(attestation, _cache.currentList, friendsID, [self attestedKey], [NSDate date]);
    return verdict == SZFriendsHostAttestationValid ? attestation : nil;
}

- (void)forgetAttestation {
    @synchronized(self) {
        _attestation = nil;
        _attestationLoaded = YES;
    }
    NSString *path = self.attestationPath;
    if (path) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

// The kept attestation, read from attestationPath the first time it is asked for.
- (SZFriendsHostAttestation *)storedAttestation {
    @synchronized(self) {
        if (!_attestationLoaded) {
            _attestationLoaded = YES;
            _attestation = [self readAttestation];
        }
        return _attestation;
    }
}

- (SZFriendsHostAttestation *)readAttestation {
    NSString *path = self.attestationPath;
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    SZFriendsHostAttestation *attestation = data ? [SZFriendsHostAttestation attestationFromData:data] : nil;
    // Left by an identity a reset replaced, or damaged: either way not this identity's to show.
    if (attestation && ![attestation.identityKey isEqualToData:[self attestedKey]]) return nil;
    return attestation;
}

- (void)writeAttestation:(SZFriendsHostAttestation *)attestation {
    NSString *path = self.attestationPath;
    if (path == nil) return;
    NSError *error = nil;
    if (![[attestation encodedData] writeToFile:path options:NSDataWritingAtomic error:&error]) {
        // This launch still has it in memory; the next one gets a fresh one at check-in.
        os_log_error(OS_LOG_DEFAULT, "Friends: could not keep the host attestation: %{public}@",
                     error.localizedDescription);
        return;
    }
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0600} ofItemAtPath:path error:NULL];
}

@end
