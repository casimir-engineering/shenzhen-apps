#pragma once
// One row of chat activity (SPDFMacAIChatActivity.h) in the AI chat transcript:
//   step   running: the title, a spinner and its live actions (Cancel) on the first line, its status under the title;
//          failed: the title, and the reason under it in red, wrapped; done: one quiet 24 pt line, the title and its
//          own status (none for a plain "Done") in 12 pt secondary text; stopped (Stop, out of time): the quiet title
//          with its status wrapped under it, unless the title already ends with it ("Python run stopped"). Expanded,
//          a step shows its detail (code in the chat's code box), what it printed (a box captioned "output", without
//          colours), its note in secondary text, and its links: https ones, each title truncating before its host,
//          then http ones as plain text with "Not a secure page" under them;
//   card   a bordered box: title, Markdown body (the chat's renderer, wide blocks scrolling sideways inside the card)
//          or, for text the person approves (SPDFMacAIActivityBodyIsLiteral), that text character for character,
//          attachments, the status wrapped on its own line, the live actions at the right of a footer;
//   image  the picture at its size or smaller, left-aligned and framed, with the caption and Save… under it;
//   fold   two or more finished steps in a row, folded into one line ("3 steps · Searched the web, …") that opens
//          to show them; it says how many of them stopped ("3 steps · 3 stopped · …"). Running steps, failures and
//          cards are never folded.
// Nothing in a row asks for more width than the transcript has: text truncates or wraps, pictures scale down.
// The chat view owns the rows and rebuilds one when its entry changes.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// What the transcript shows for a chat's activity: the rows {entry, actions} (actions: those whose handler is still
// alive, SPDFMacAIChatSession -liveActivityActionsForEntry:), sorted by anchor, with each run of two or more
// finished steps at one anchor replaced by a fold {fold: [rows], entry: its first step's entry}, so a fold sorts and
// anchors like that step.
NSArray<NSDictionary*>* SPDFMacAIChatActivityUnits(NSArray<NSDictionary*>* rows);
// A unit's row identity: the entry's id, or "fold:" and its first step's id.
NSString* SPDFMacAIChatActivityUnitKey(NSDictionary* unit);

@interface SPDFMacAIChatActivityRow : NSStackView
// `expanded`: the unit keys and entry ids whose details are open.
- (instancetype)initWithUnit:(NSDictionary*)unit expanded:(NSSet<NSString*>*)expanded width:(CGFloat)width;
@property(nonatomic, readonly, copy) NSString* entryID;  // SPDFMacAIChatActivityUnitKey
@property(nonatomic, readonly, copy) NSDictionary* unit;
@property(nonatomic, copy, nullable) void (^perform)(NSString* entryID, NSString* actionID);
// A disclosure in this row (the fold's, or one of its steps') was clicked: `key` should now be `expanded`.
@property(nonatomic, copy, nullable) void (^toggled)(NSString* key, BOOL expanded);
// nil: a save panel on the row's window.
@property(nonatomic, copy, nullable) void (^saveImage)(NSString* path, NSString* caption);
@property(nonatomic, copy, nullable) void (^openLink)(NSURL* URL);
@end

// A PNG the chat may show: inside the chat store's folder, at most 8 MB, decodable. nil for anything else, so a
// path written into a chat file cannot make the view read another file.
NSImage* _Nullable SPDFMacAIChatStoredImage(NSString* _Nullable path);
// Save… without a handler: a save panel on `window` named after the caption, writing the stored PNG.
void SPDFMacAIChatSaveStoredImage(NSWindow* _Nullable window, NSString* path, NSString* caption);

NS_ASSUME_NONNULL_END
