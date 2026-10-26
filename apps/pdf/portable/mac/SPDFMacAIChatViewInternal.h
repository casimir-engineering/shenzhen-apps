#pragma once
// The chat panel's own state, shared by its two implementation files: SPDFMacAIChatView.mm (the panel, its
// transcript and activity rows) and SPDFMacAIChatViewMessages.mm (message rows, editing an earlier question, the
// summary marker and the chat actions menu). Nothing else imports this.
#import "SPDFMacAIChatView.h"
#import "SPDFMacAIChatViewParts.h"
#import "SPDFMacChatMarkdownView.h"
@class SPDFMacAIChatSearch;

// A message in the transcript. One of your own carries an Edit button, shown while the pointer is over the message,
// and "Edit message" in its context menu.
@interface SPDFChatMarkdownMessageView : SPDFMacChatMarkdownView
@property(nonatomic, weak) SPDFChatButton* hoverButton;
@property(nonatomic, copy) void (^editAction)(void);
@end

@interface SPDFMacAIChatView () <NSTextViewDelegate, NSSearchFieldDelegate> {
    @package
    SPDFChatComposer* _composer; NSTextField* _status; NSTextField* _inputHelp; NSScrollView* _scroll;
    NSScrollView* _input; NSStackView* _messages;
    SPDFMacAIChatSearch* _chatFind;
    NSLayoutConstraint* _inputHeight; NSLayoutConstraint* _stopTrailing; NSLayoutConstraint* _stopHistoryTrailing;
    NSStackView* _issue; NSTextField* _issueText; NSButton* _recovery;
    NSLayoutConstraint* _scrollAboveIssue; NSLayoutConstraint* _scrollAboveInput;
    NSView* _banner; NSLayoutConstraint* _scrollBelowPrompt; NSArray<NSLayoutConstraint*>* _bannerConstraints;
    NSButton* _redo; NSSearchField* _chatSearch; NSTextField* _activityDetail; NSProgressIndicator* _progress;
    NSTextField* _prompt; NSLayoutConstraint* _promptHeight; NSArray* _displayedMessages;
    NSArray* _displayedActivity; NSMutableSet<NSString*>* _expandedActivity;
    NSString* _submissionError; NSButton* _send; NSButton* _stop; NSButton* _undo; NSUInteger _visibleLimit;
    NSString* _chatID; BOOL _history; BOOL _running; BOOL _preserveScroll;
    __weak SPDFMacAIChatSession* _displayedSession;
    // The question being edited: its position in the chat (NSNotFound when none), its text and the draft.
    NSUInteger _editIndex,_editPlace; NSString* _editOriginal; NSString* _editDraft;
    __weak SPDFChatMessageView* _editor;
    // Attachments (SPDFMacAIChatAttachments.mm): the paperclip, the row of chips above the composer and its note.
    NSButton* _attach; NSTextField* _attachmentNote; NSView* _attachmentRow;
    NSLayoutConstraint* _attachmentRowHeight; NSArray<NSDictionary*>* _shownAttachments;
    // Following the end of the chat (SPDFMacAIChatViewFollow.mm): whether to stay at the end as it grows, the pill
    // saying what is below, messages that arrived below while the person read above and the first of them (its index
    // and its row), and whether a scroll is the view's own rather than the person's.
    BOOL _followNewest; NSButton* _newMessagesPill; NSUInteger _unseenMessages; NSUInteger _firstUnseenIndex;
    __weak NSView* _firstUnseenRow; BOOL _scrollingItself;
}
- (NSButton*)button:(NSString*)title action:(NSString*)action;
@end

@interface SPDFMacAIChatView (Follow)
- (void)setUpFollowing;
- (BOOL)scrolledToEnd;
- (void)scrollToNewest;
- (void)followNewest;
- (void)noteUnseenMessages:(NSArray*)messages from:(NSUInteger)first;
- (void)noteRowsFrom:(NSUInteger)rows forMessage:(NSUInteger)index;
- (void)updateNewMessagesPill;
@end

@interface SPDFMacAIChatView (Messages)
- (void)addText:(NSString*)text role:(NSString*)role;
// `index` is the position of one of your own messages in the chat; those rows can be edited.
- (void)addText:(NSString*)text role:(NSString*)role messageIndex:(NSUInteger)index;
- (NSMenu*)chatActionsMenu;
- (void)addSummaryMarker;
- (SPDFChatButton*)editButtonForMessageAtIndex:(NSUInteger)index;
// The question being edited, in place of its message: an editable text with Cancel and Send under it.
- (void)addEditorWithRole:(NSString*)role;
- (void)focusEditor;
- (void)validateEditForMessages:(NSArray*)messages;
- (void)clearEdit;
- (void)redisplayKeepingPosition;
- (void)beginEditingMessageAtIndex:(NSUInteger)index;
- (void)endEditing;
- (void)commitEdit;
@end
