#pragma once
#import "SPDFMacCollectionCredentials.h"
@interface MemoryKeychain : NSObject <SPDFCollectionKeychainAccess>
@property(nonatomic) NSMutableDictionary* items;
@property(nonatomic) NSDictionary* lastQuery;
@property(nonatomic) NSData* transferredBytes;
@property(nonatomic) NSInteger reads, adds, updates;
@property(nonatomic) OSStatus failure;
@end
@implementation MemoryKeychain
- (instancetype)init { if((self=[super init])) _items=[NSMutableDictionary dictionary]; return self; }
- (OSStatus)copyMatching:(NSDictionary*)query result:(NSData**)result {
    self.reads++; self.lastQuery=query;
    if(self.failure) return self.failure;
    NSData* data=self.items[query[(__bridge id)kSecAttrAccount]];
    if(!data) return errSecItemNotFound;
    *result=[data copy]; return errSecSuccess;
}
- (OSStatus)add:(NSDictionary*)attributes {
    self.adds++; self.lastQuery=attributes; self.transferredBytes=attributes[(__bridge id)kSecValueData];
    if(self.failure) return self.failure;
    NSString* account=attributes[(__bridge id)kSecAttrAccount];
    if(self.items[account]) return errSecDuplicateItem;
    self.items[account]=[attributes[(__bridge id)kSecValueData] copy]; return errSecSuccess;
}
- (OSStatus)update:(NSDictionary*)query attributes:(NSDictionary*)attributes {
    self.updates++; self.lastQuery=query;
    if(self.failure) return self.failure;
    self.items[query[(__bridge id)kSecAttrAccount]]=[attributes[(__bridge id)kSecValueData] copy]; return errSecSuccess;
}
@end
