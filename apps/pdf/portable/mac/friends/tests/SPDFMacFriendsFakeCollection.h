// A scripted Collection for the host adapter's tests: rows in SPDFMacCollectionStore's shapes, and a count of every
// call so a test can prove Collection is never consulted while it is off.

#pragma once
#import <Foundation/Foundation.h>
#import "SPDFMacFriendsRevision.h"

@interface SPDFMacFriendsFakeCollection : NSObject <SPDFMacFriendsCollectionLookup>
@property(nonatomic) BOOL enabled;
@property(nonatomic, copy) NSArray<NSDictionary*>* documents;                     // id, path, title, latestVersionID
@property(nonatomic, copy) NSDictionary<NSString*, NSArray<NSDictionary*>*>* versions; // document id -> versions
@property(nonatomic, copy) NSDictionary<NSString*, NSDictionary*>* archives;       // path -> {document, version}
@property(nonatomic, copy) NSDictionary<NSString*, NSString*>* materialized;      // version id -> file path
@property(nonatomic) NSInteger calls;
@end

@implementation SPDFMacFriendsFakeCollection
- (BOOL)friendsCollectionEnabled { return self.enabled; }
- (NSDictionary*)friendsArchiveInfoForPath:(NSString*)path { self.calls++; return self.archives[path]; }
- (NSDictionary*)friendsDocumentForPath:(NSString*)path {
    self.calls++;
    for (NSDictionary* document in self.documents)
        if ([document[@"path"] isEqual:path]) return document;
    return nil;
}
- (NSArray<NSDictionary*>*)friendsVersionsForDocumentID:(NSString*)documentID {
    self.calls++;
    return self.versions[documentID] ?: @[];
}
- (NSArray<NSDictionary*>*)friendsDocuments { self.calls++; return self.documents ?: @[]; }
- (NSURL*)friendsFileForVersionID:(NSString*)versionID documentID:(NSString*)documentID {
    (void)documentID;
    self.calls++;
    NSString* path = self.materialized[versionID];
    return path ? [NSURL fileURLWithPath:path] : nil;
}
@end

#import <CommonCrypto/CommonDigest.h>
static inline NSString* SPDFMacFriendsTestSHA256(NSData* data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString* hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}
