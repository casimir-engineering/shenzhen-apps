#pragma once
#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (SPDFMacAIToolsComments)
- (NSDictionary*)aiReadCommentsAtPath:(NSString*)path;
// Receipt contains private beforeBytes; callers must remove it before passing
// the public receipt to a model. Original bytes enable exact inverse edits.
- (NSDictionary*)aiEditComment:(NSDictionary*)arguments progress:(NSProgress*)progress;
- (BOOL)aiUndoCommentReceipt:(NSDictionary*)receipt progress:(NSProgress*)progress;
@end
