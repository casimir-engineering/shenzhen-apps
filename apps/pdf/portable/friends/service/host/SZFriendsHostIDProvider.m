// The Friends IDs a check-in claims: the current one first, then a fresh draw after each collision, with the
// identity area's word-count rule (ADR 0006 § Three-word threshold): the signed list's new_id_words, or three
// words after three collisions in a row whatever a stale list says.

#import "service/host/SZFriendsHostInternal.h"
#import "service/identity/SZFriendsIdentity.h"

#import <sodium.h>

SZFriendsIDProvider SZFriendsHostIDProvider(NSString *currentID, SZFriendsIDCodec *codec,
                                            SZFriendsHostListCache *cache) {
    NSString *current = [currentID copy];
    return ^NSString *(NSUInteger collisionsInARow) {
        if (collisionsInARow == 0) return current;
        NSUInteger words = SZFriendsWordCountForNewID(cache.currentList.newIDWords, collisionsInARow);
        return [codec randomIDWithWordCount:words
                                  generator:^uint32_t(uint32_t bound) {
                                      return randombytes_uniform(bound);
                                  }];
    };
}
