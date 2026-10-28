// Private to SPDFMacRemoteLinks.mm (links, downloads, opening) and SPDFMacRemoteLinkViews.mm (where a link opens,
// the progress bar, notes and alerts): one window's link state, kept on the coordinator as an associated object so
// the capped SPDFMacDelegatePrivate.h gains no ivar.
#pragma once

#import "SPDFMacRemoteLinks.h"
#import "SPDFMacRemoteDownload.h"

@interface ShenzhenMacDelegate (SPDFMacRemoteLinksHost)
- (void)openDocumentHereAtPath:(NSString*)path page:(NSNumber*)page;
- (void)enqueueVisibleMinimapThumbnailRenders;
- (NSInteger)indexOfTabForPath:(NSString*)path;
- (void)loadSelectedTab;
- (void)rememberActiveTabState;
@end

// One link's document: its download, and the page the link asked for.
@interface SPDFMacRemoteLinkJob : NSObject
@property(nonatomic) SPDFMacRemoteDownload* download;
@property(nonatomic) NSInteger page;      // 1-based, 0 for none
@property(nonatomic) BOOL opened;         // its tab exists
@property(nonatomic) BOOL attempting;     // a trial open is running
@property(nonatomic) int64_t triedAt;     // bytes received at the last trial open
@property(nonatomic) CFAbsoluteTime openableSince; // the document first opened (0: not yet)
@property(nonatomic) BOOL reloadWhenReadable; // a restored tab opened on the partial file before this download began
@end
// Where a link asked the document to open beyond its page: a chapter or section, or a Markdown heading. It waits
// until the document's tab is in front and the part it names can be looked up (a PDF's outline may arrive late in
// the download, a Markdown file's headings as it streams in).
@interface SPDFMacRemoteTarget : NSObject
@property(nonatomic, copy) NSString* path;
@property(nonatomic, copy) NSString* name; // the heading, else the section
@property(nonatomic) CFAbsoluteTime deadline;
@end
// The download's progress: a thin bar along the top edge of the page area, the system accent colour on a faint
// track, drawn only while the tab in front is downloading.
@interface SPDFMacRemoteProgressBar : NSView
@property(nonatomic) double fraction;
@end
@interface SPDFMacRemoteLinksState : NSObject <SPDFMacRemoteDownloadDelegate>
@property(nonatomic, weak) ShenzhenMacDelegate* reader;
@property(nonatomic) NSMutableDictionary<NSString*, SPDFMacRemoteLinkJob*>* jobs; // by file path
@property(nonatomic) SPDFMacRemoteProgressBar* bar;
@property(nonatomic) NSMutableDictionary<NSString*, SPDFMacRemoteTarget*>* targets; // by file path
@property(nonatomic) NSTimer* targetTimer;
@property(nonatomic) NSView* note; // SPDFMacRemoteLinks -showRemoteNote:sticky:
@property(nonatomic) NSTextField* noteLabel;
@property(nonatomic) NSTimer* noteTimer;
@property(nonatomic) BOOL noteSticky;
@end

@interface ShenzhenMacDelegate (SPDFMacRemoteLinksPrivate)
- (void)remoteLinkProgress:(SPDFMacRemoteDownload*)download;
- (void)remoteLinkFinished:(SPDFMacRemoteDownload*)download;
- (SPDFMacRemoteLinksState*)remoteLinksState;
// SPDFMacRemoteLinkViews.mm
- (void)setRemoteTarget:(NSString*)name path:(NSString*)path;
- (void)resolveRemoteTargets;
- (void)updateRemoteLinkIndicator;
- (void)showRemoteNote:(NSString*)text sticky:(BOOL)sticky;
- (void)hideRemoteNote;
- (void)showRemoteLinkAlert:(NSString*)title message:(NSString*)message;
@end
