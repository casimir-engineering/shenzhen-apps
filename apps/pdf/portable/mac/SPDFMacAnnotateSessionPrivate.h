#pragma once
// What SPDFMacAnnotateSession.mm and its saving category (SPDFMacAnnotateSessionSaving.mm) share.
#import "SPDFMacAnnotateSession.h"

@class SPDFAnnotatePicture;

@interface SPDFMacAnnotateSession () {
  @package
    spdf_paint_doc* _canvas;
    NSMutableDictionary<NSNumber*, NSValue*>* _pageCanvases;  // page -> spdf_paint_doc*
}
@property(nonatomic, weak, readwrite) SPDFDocumentTab* tab;
@property(nonatomic, readwrite) SPDFAnnotateDocumentKind kind;
@property(nonatomic, copy, readwrite) NSString* format;
@property(nonatomic, readwrite) BOOL writesInPlace;
@property(nonatomic, readwrite) BOOL loaded;
@property(nonatomic, copy, readwrite) NSString* projectPath;
@property(nonatomic, copy) NSDictionary* pictureProperties;  // the picture's metadata, written back on save
@property(nonatomic) BOOL lastWriteFailed;                    // dirty even though the core was marked saved
@property(nonatomic) BOOL keptCopyChanges;                    // a WebP or RAW came back with unsaved drawing (dirty)
@property(nonatomic) NSInteger pendingWrites;                 // encodes and writes in flight
@property(nonatomic, strong) NSTimer* autosaveTimer;
// The picture's size in pixels when the reader last read its file: the page the reader lays out is that size, so the
// canvas view scales canvas pixels by the page's width over it (the canvas may have been resized since).
@property(nonatomic) NSSize readerPixelSize;
@property(nonatomic, copy) NSDictionary* fileStamp;
- (void)noteChange;  // posts SPDFAnnotateSessionDidChangeNotification, schedules the .szpaint autosave
@end

@interface SPDFMacAnnotateSession (Saving)
// The .szpaint kept beside a picture and the record of the file it belongs to (size and modification time).
+ (NSString*)sidecarPathForPath:(NSString*)path;
// The kept layers, when `path` is unchanged since they were written; NULL otherwise.
+ (spdf_paint_doc*)openSidecarForPath:(NSString*)path;
- (void)writeSidecarNow:(BOOL)synchronously;
- (void)discardKeptChanges;  // Don't Save on a WebP or RAW drawn on: what was kept for it goes
- (void)discardKeptChangesForPath:(NSString*)path;
// The file as Annotate last read or wrote it (size, modification time); YES when something else changed it since.
- (void)rememberFileStamp;
- (BOOL)fileChangedElsewhere;
@end

// Shared JSON helpers.
NSString* SPDFAnnotateJSONString(id object);
NSDictionary* SPDFAnnotateParseAnswer(char* answer);  // frees answer
NSDictionary* SPDFAnnotateErrorAnswer(NSString* code, NSString* message);

// SPDFMacAnnotateSessionTools.mm: the tool and colours the person chose last, kept in settings.json for the next tab.
// A PDF starts on Fill & Sign's Text (a form is filled by clicking its fields); a picture or canvas on the last tool.
void SPDFAnnotateRememberTool(SPDFAnnotateTool tool, NSInteger brush);
void SPDFAnnotateRememberColors(spdf_paint_color color1, spdf_paint_color color2);
void SPDFAnnotateAdoptRememberedChoices(SPDFMacAnnotateSession* session);
