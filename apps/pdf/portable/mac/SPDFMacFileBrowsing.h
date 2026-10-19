#pragma once

#import "SPDFMacDelegatePrivate.h"

NS_ASSUME_NONNULL_BEGIN

// The open flow: Open..., the Cmd+Shift+O path prompt, and the shared "pick a
// document, starting in this folder" step they both route through.
@interface ShenzhenMacDelegate (SPDFMacFileBrowsing)
- (void)openDocument:(nullable id)sender;
- (void)openPathPrompt:(nullable id)sender;
- (void)openResolvedPath:(NSString*)input;
// Presents the native Open panel rooted at the folder. Always native: only a
// real chooser can hand the selected file back to the app.
- (void)browseForDocumentInDirectory:(nullable NSString*)directory;
@end

NS_ASSUME_NONNULL_END
