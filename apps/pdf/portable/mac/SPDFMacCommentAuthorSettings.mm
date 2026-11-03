// The "Your name on comments" row of Settings > Reading & access. Kept apart from SPDFMacUnifiedSettings.mm so that
// file stays within its size cap. Reads commentAuthor (empty: use the Mac's name) and commentAuthorDefault (that
// name, shown as the placeholder) from the state, and reports a change as commentAuthor.

#import "SPDFMacUnifiedSettings.h"

@interface SPDFMacUnifiedSettingsController (SPDFMacCommentAuthorPageBuilding)
- (NSDictionary*)state;
- (NSMutableDictionary<NSString*, NSControl*>*)controls;
- (NSStackView*)row:(NSString*)title detail:(NSString*)detail control:(NSView*)control;
- (void)emit:(NSDictionary*)change;
@end

@implementation SPDFMacUnifiedSettingsController (SPDFMacCommentAuthor)
- (void)buildCommentAuthorRow {
    NSTextField* field = [NSTextField new];
    field.identifier = @"commentAuthor";
    field.accessibilityLabel = @"Your name on comments";
    field.font = [NSFont systemFontOfSize:13];
    field.stringValue = self.state[@"commentAuthor"] ?: @"";
    field.placeholderString = self.state[@"commentAuthorDefault"] ?: @"";
    field.target = self;
    field.action = @selector(commentAuthorChanged:);
    field.cell.sendsActionOnEndEditing = YES;
    [field.widthAnchor constraintEqualToConstant:240].active = YES;
    self.controls[@"commentAuthor"] = field;
    [self row:@"Your name on comments" detail:@"Shown on each comment you add, in PDFs and Markdown. Leave empty to use your Mac’s name."
        control:field];
}

- (void)showCommentAuthor:(NSString*)stored {
    [self updateState:@{@"commentAuthor" : stored ?: @""}];
    NSTextField* field = (NSTextField*)self.controls[@"commentAuthor"];
    if (field && !field.currentEditor) field.stringValue = stored ?: @"";
}

- (void)commentAuthorChanged:(NSTextField*)sender {
    NSString* name = [sender.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([name isEqualToString:self.state[@"commentAuthor"] ?: @""]) return;
    [self emit:@{@"commentAuthor" : name}];
}
@end
