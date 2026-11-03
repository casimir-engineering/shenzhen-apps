#pragma once
// Your name on comments, changed where it is shown: in a new comment's box and on your own cards in the Comments panel.
// Hovering the name shows a small pencil after it, the pointing hand and "Change your name"; a click turns the name
// into a field with the name selected. Return or a click elsewhere keeps the new name, Esc keeps the old one, and an
// empty name changes nothing. The reader stores it as Settings does (SPDFMacCommentAuthorIntegration.mm).
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFCommentAuthorToolTip;  // "Change your name"

// The pencil after the name, `pointSize` high, in the secondary text colour; its width is what it needs.
FOUNDATION_EXPORT NSImage* SPDFCommentAuthorPencil(CGFloat pointSize);
// `name` trimmed, or nil when that leaves nothing or the same name as `previous`: what a finished edit keeps.
FOUNDATION_EXPORT NSString* _Nullable SPDFCommentAuthorEditedName(NSString* _Nullable name, NSString* _Nullable previous);

// The field that edits a name in place, over `frame` of `host`, with the name selected and the keyboard in it.
// `done` runs once: with the new name (SPDFCommentAuthorEditedName) or nil, and `byKey` YES after Return or Esc (the
// host then puts the keyboard back where it was), NO after a click elsewhere took the keyboard.
@interface SPDFCommentAuthorNameEdit : NSObject
+ (instancetype)editName:(NSString*)name
                  inView:(NSView*)host
                   frame:(NSRect)frame
                    font:(NSFont*)font
               alignment:(NSTextAlignment)alignment
                    done:(void (^)(NSString* _Nullable name, BOOL byKey))done;
@property(nonatomic, readonly) NSTextField* field;
- (void)commit;
- (void)cancel;
@end

// Where a click on a name drawn by its host view edits it: a clear control over the name and its pencil (a table passes
// clicks to controls in its rows), with the pointing hand, "Change your name", and `hovered` when the pointer is on it.
@interface SPDFCommentAuthorHotspot : NSControl
@property(nonatomic, copy, nullable) void (^pressed)(void);
@property(nonatomic, copy, nullable) void (^hovered)(BOOL over);
@end

// The byline of a comment box: the name, right-aligned. While `editable`, it has the pencil, cursor and tooltip on
// hover and a click edits it; `changed` gets the new name. Not editable, it is the name and nothing else.
@interface SPDFMacCommentAuthorByline : NSView
@property(nonatomic, copy) NSString* name;
@property(nonatomic) BOOL editable;
@property(nonatomic, copy, nullable) void (^changed)(NSString* name);
// Where the keyboard goes after Return or Esc in the field.
@property(nonatomic, weak, nullable) NSView* keyboardHome;
@property(nonatomic, readonly, getter=isEditing) BOOL editing;
@property(nonatomic, readonly, getter=isHovered) BOOL hovered;
// The name and its pencil: where the pointer shows the hand and a click edits.
@property(nonatomic, readonly) NSRect nameArea;
- (void)beginEditing;
// Ends an edit, keeping or dropping the typed name; nothing when not editing.
- (void)commitEditing;
- (void)cancelEditing;
@end

NS_ASSUME_NONNULL_END
