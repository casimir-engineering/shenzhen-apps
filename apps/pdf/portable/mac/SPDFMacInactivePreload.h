#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Thread-safe handoff for one inactive-tab open. The foreground can claim the
// document while the worker is preparing, opening, or rendering without ever
// starting a competing open for the same path.
@interface SPDFMacInactivePreload : NSObject

@property(nonatomic, readonly, getter=isForegroundClaimed) BOOL foregroundClaimed;
@property(nonatomic, readonly, strong) dispatch_group_t completionGroup;
@property(nonatomic, weak, nullable) NSOperation* operation;

- (BOOL)workerMayBeginOpen;
- (BOOL)workerMayContinueWithDocument:(void*)document attributes:(NSDictionary*)attributes;
- (void)workerFinishedWithPages:(nullable NSArray*)pages;
- (BOOL)workerFinishedCancelledDocument:(void* _Nullable)document attributes:(nullable NSDictionary*)attributes;
- (void)workerFinishedWithoutDocument;

- (BOOL)claimForForeground;
// Release a rejected foreground claim only after its worker relinquishes the
// document. Completion runs off-main exactly once, including an empty claim.
- (void)discardForegroundDocumentWithHandler:(void (^)(void* _Nullable document))handler;
- (void* _Nullable)takeForegroundDocumentWithAttributes:(NSDictionary* _Nullable* _Nullable)attributes;
- (void* _Nullable)takeBackgroundDocumentWithAttributes:(NSDictionary* _Nullable* _Nullable)attributes
                                                  pages:(NSArray* _Nullable* _Nullable)pages;

@end

NS_ASSUME_NONNULL_END
