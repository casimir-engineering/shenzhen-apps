// SZFriendsProfilePage: the name friends see, the picture, your ID with Copy and QR, and adding someone by ID.

#import "mac/SZFriendsDetailsPage.h"
#import "mac/SZFriendsDevices.h"
#import "mac/SZFriendsLinkPage.h"

#import <CoreImage/CoreImage.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "avatars/SZFriendsAvatars.h"

// The QR of `id.qr_payload`, drawn with hard pixel edges so a phone camera reads it at any size.
@interface SZFriendsQRView : NSView
@property(nonatomic, copy) NSString *payload;
@end

@implementation SZFriendsQRView {
    NSImage *_image;
}
- (void)setPayload:(NSString *)payload {
    if ([payload isEqualToString:_payload]) return;
    _payload = [payload copy];
    _image = nil;
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    if (filter && data.length) {
        [filter setValue:data forKey:@"inputMessage"];
        [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
        CIImage *output = filter.outputImage;
        if (output) {
            NSCIImageRep *rep = [NSCIImageRep imageRepWithCIImage:output];
            _image = [[NSImage alloc] initWithSize:rep.size];
            [_image addRepresentation:rep];
        }
    }
    self.needsDisplay = YES;
}
- (BOOL)isAccessibilityElement {
    return YES;
}
- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityImageRole;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    // Always dark on white, in both appearances: scanners need the contrast, not the theme.
    [NSColor.whiteColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
    if (!_image) return;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationNone;
    [_image drawInRect:NSInsetRect(self.bounds, 6, 6)];
    [NSGraphicsContext restoreGraphicsState];
}
@end

// The profile's scrolling content, which also takes a dropped image: it starts the same crop step as Use your own
// picture… (brief § Product contract: choose a file or drop an image, then crop to the circle).
@interface SZFriendsProfileContent : SZFriendsFlippedView
@property(nonatomic, copy) void (^onImageDrop)(NSString *path);
@end

@implementation SZFriendsProfileContent
- (NSString *)imagePath:(id<NSDraggingInfo>)info {
    NSDictionary *fileURLsOnly = @{NSPasteboardURLReadingFileURLsOnlyKey : @YES};
    NSArray<NSURL *> *urls = [info.draggingPasteboard readObjectsForClasses:@[ NSURL.class ] options:fileURLsOnly];
    if (urls.count != 1) return nil;
    UTType *type = nil;
    [urls[0] getResourceValue:&type forKey:NSURLContentTypeKey error:nil];
    return [type conformsToType:UTTypeImage] ? urls[0].path : nil;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return [self imagePath:sender] ? NSDragOperationCopy : NSDragOperationNone;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSString *path = [self imagePath:sender];
    if (path && self.onImageDrop) self.onImageDrop(path);
    return path != nil;
}
@end

@interface SZFriendsProfilePage () <NSTextFieldDelegate>
@end

@implementation SZFriendsProfilePage {
    NSString *_token;
    NSDictionary *_data;
    NSScrollView *_scroll;
    SZFriendsFlippedView *_content;
    SZFriendsAvatarView *_avatar;
    NSTextField *_nameLabel;
    SZFriendsNameEditor *_nameEditor; // the name friends see, with Save (SZFriendsListPage.h)
    NSString *_appliedName;           // the name last shown, so a snapshot never overwrites what is being typed
    NSTextField *_animalsTitle;
    NSMutableArray<SZFriendsButton *> *_animals;
    SZFriendsFlippedView *_idCard;
    NSTextField *_idTitle;
    NSTextField *_idValue;
    NSTextField *_idNote;
    SZFriendsQRView *_qr;
    SZFriendsYourLinksView *_links;
    SZFriendsYourComputersView *_computers;
    BOOL _largeQR;
    NSTextField *_addLabel;
    NSTextField *_addHint;
    NSTextField *_addResult;
    BOOL _addFailed;
    BOOL _revealAdd; // scroll Add by ID into view at the next layout
    CGFloat _divider;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithContext:context])) return nil;
    SZFriendsAppearance *appearance = context.appearance;
    __weak SZFriendsProfilePage *weakSelf = self;
    _header = [[SZFriendsHeaderView alloc] initWithAppearance:appearance];
    _header.backButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf.context.navigator goBack];
    };
    [self addSubview:_header];
    SZFriendsProfileContent *content = [[SZFriendsProfileContent alloc] initWithFrame:NSMakeRect(0, 0, 400, 500)];
    content.onImageDrop = ^(NSString *path) { [weakSelf beginCropForImageAtPath:path]; };
    _content = content;
    _content.drawContents = ^(SZFriendsFlippedView *view) {
        SZFriendsProfilePage *page = weakSelf;
        if (!page) return;
        [appearance.separatorColor setFill];
        NSRectFill(NSMakeRect(16, page->_divider, NSWidth(view.bounds) - 32, 1));
    };
    _scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 48, 400, 500)];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.documentView = _content;
    [self addSubview:_scroll];

    _avatar = [SZFriendsAvatarView new];
    _nameLabel = SZFriendsLabel(@"", appearance.captionFont, appearance.secondaryTextColor);
    _nameEditor = [[SZFriendsNameEditor alloc] initWithContext:context font:appearance.bodyFont];
    _nameEditor.onLayoutChange = ^{ [weakSelf setNeedsLayout:YES]; };
    _nameEditor.onCancel = ^{ [weakSelf cancelNameEdit]; };
    _photoButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStyleSecondary appearance:appearance];
    _photoButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf toggleAnimals];
    };
    _animalsTitle = SZFriendsLabel(@"", SZFriendsSemibold(appearance.secondaryFont), appearance.primaryTextColor);
    _animals = [NSMutableArray array];
    _ownPictureButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStyleLink appearance:appearance];
    _ownPictureButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        SZFriendsProfilePage *page = weakSelf;
        page.context.chooseImage(^(NSString *path) {
            if (path) [weakSelf beginCropForImageAtPath:path];
        });
    };
    _idCard = [SZFriendsFlippedView new];
    _idCard.fillColor = appearance.fieldBackgroundColor;
    _idCard.strokeColor = appearance.separatorColor;
    _idCard.cornerRadius = 10;
    _idTitle = SZFriendsLabel(@"", SZFriendsSemibold(appearance.captionFont), appearance.secondaryTextColor);
    NSFont *idFont = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
    _idValue = SZFriendsLabel(@"", idFont, appearance.primaryTextColor);
    _idNote = SZFriendsLabel(@"", appearance.secondaryFont, appearance.primaryTextColor);
    _cpyButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStyleSecondary appearance:appearance];
    _cpyButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        SZFriendsProfilePage *page = weakSelf;
        if (page) [page.context copyText:SZFStr(SZFDict(page->_data, @"id"), @"friends_id")];
    };
    _qrButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStyleSecondary appearance:appearance];
    _qrButton.onPress = ^(SZFriendsButton *button) {
        SZFriendsProfilePage *page = weakSelf;
        if (!page) return;
        page->_largeQR = !page->_largeQR;
        button.selectedLook = page->_largeQR;
        [page setNeedsLayout:YES];
    };
    _qr = [SZFriendsQRView new];
    for (NSView *view in @[ _idTitle, _idValue, _idNote, _cpyButton, _qrButton, _qr ]) [_idCard addSubview:view];
    _addLabel = SZFriendsLabel(@"", SZFriendsSemibold(appearance.bodyFont), appearance.primaryTextColor);
    _addField = [NSTextField textFieldWithString:@""];
    _addField.bezelStyle = NSTextFieldRoundedBezel;
    _addField.font = appearance.bodyFont;
    _addField.delegate = self;
    _addButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStylePrimary appearance:appearance];
    _addButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf sendAddRequest];
    };
    _addHint = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _addResult = SZFriendsLabel(@"", appearance.secondaryFont, appearance.primaryTextColor);
    _links = [[SZFriendsYourLinksView alloc] initWithContext:context];
    _computers = [[SZFriendsYourComputersView alloc] initWithContext:context];
    for (NSView *view in @[ _avatar, _nameLabel, _nameEditor, _photoButton, _animalsTitle, _ownPictureButton, _idCard,
                            _links, _computers, _addLabel, _addField, _addButton, _addHint, _addResult ])
        [_content addSubview:view];
    [_content registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
    return self;
}

- (SZFriendsDropdownView)kind {
    return SZFriendsDropdownViewProfile;
}

- (SZFriendsYourLinksView *)linksView {
    return _links;
}

- (SZFriendsYourComputersView *)computersView {
    return _computers;
}

- (NSArray<SZFriendsButton *> *)animalButtons {
    return [_animals copy];
}

- (NSView *)preferredFirstResponder {
    return _addField;
}

- (void)pageWillAppear {
    [super pageWillAppear];
    // The page opens from Add by ID: in a short dropdown that section is below the ID card and Your computers, so it
    // scrolls into view with the field that has the focus (the owner's narrow dropdown showed only its top edge).
    _revealAdd = YES;
    __weak SZFriendsProfilePage *weakSelf = self;
    _token = [self.context.link subscribeToView:@"profile" params:nil handler:^(NSDictionary *data, NSInteger rev) {
        (void)rev;
        [weakSelf applySnapshot:data];
    }];
}

- (void)pageDidDisappear {
    [super pageDidDisappear];
    if (_token) [self.context.link unsubscribe:_token];
    _token = nil;
}

- (void)applySnapshot:(NSDictionary *)data {
    _data = [data copy];
    SZFriendsAppearance *appearance = self.context.appearance;
    [_header setTitle:SZFStr(data, @"title") subtitle:nil subtitleColor:nil clickable:NO accessibilityLabel:nil];
    [_header setBack:SZFDict(data, @"back") fallbackLabel:[self.context string:@"back"]];
    if (self.onBackBadgeChange) self.onBackBadgeChange();
    NSDictionary *name = SZFDict(data, @"name");
    _nameLabel.stringValue = SZFStr(name, @"label") ?: @"";
    NSString *savedName = SZFStr(name, @"value") ?: @"";
    NSTextField *nameField = _nameEditor.field;
    if (!nameField.currentEditor || [nameField.stringValue isEqualToString:_appliedName ?: @""])
        nameField.stringValue = savedName;
    _appliedName = savedName;
    _nameEditor.currentName = savedName;
    [_nameEditor reloadStrings];
    nameField.placeholderString = SZFStr(name, @"placeholder");
    nameField.accessibilityLabel = _nameLabel.stringValue;
    NSDictionary *picture = SZFDict(data, @"picture");
    _avatar.avatar = SZFDict(picture, @"avatar");
    _photoButton.title = SZFStr(picture, @"choose_label") ?: @"";
    _ownPictureButton.title = SZFStr(picture, @"own_picture_label") ?: @"";
    _animalsTitle.stringValue = [self.context string:@"animals_title"];
    [self rebuildAnimals:picture];
    NSDictionary *identifier = SZFDict(data, @"id");
    _idTitle.stringValue = SZFStr(identifier, @"label") ?: @"";
    _idValue.stringValue = SZFStr(identifier, @"friends_id") ?: @"";
    _idNote.stringValue = SZFStr(identifier, @"note") ?: @"";
    // A changed ID is news the person should not miss; every other state is a plain note.
    BOOL changed = [SZFStr(identifier, @"state") isEqualToString:@"changed"];
    _idNote.drawsBackground = changed;
    _idNote.backgroundColor = changed ? [appearance.warningColor colorWithAlphaComponent:0.18] : NSColor.clearColor;
    _cpyButton.title = SZFStr(identifier, @"copy_label") ?: @"";
    _qrButton.title = SZFStr(identifier, @"qr_label") ?: @"";
    _qr.payload = SZFStr(identifier, @"qr_payload") ?: @"";
    _qr.accessibilityLabel = _idValue.stringValue;
    // No QR while nothing can read one (null in M1): a code a phone camera cannot act on only invites a dead end.
    _qr.hidden = !_qr.payload.length;
    _qrButton.hidden = _qr.hidden || !_qrButton.title.length;
    if (_qr.hidden) _largeQR = NO;
    NSDictionary *add = SZFDict(data, @"add");
    _addLabel.stringValue = SZFStr(add, @"label") ?: @"";
    _addField.placeholderString = SZFStr(add, @"placeholder");
    _addField.accessibilityLabel = _addLabel.stringValue;
    _addButton.title = SZFStr(add, @"button_label") ?: @"";
    [self updateAddButton];
    _addHint.stringValue = SZFStr(add, @"hint") ?: @"";
    [_links applyLinks:SZFDict(data, @"links")];
    [_computers applyDevices:SZFDict(data, @"devices")];
    [self setNeedsLayout:YES];
}

- (void)rebuildAnimals:(NSDictionary *)picture {
    for (NSView *view in _animals) [view removeFromSuperview];
    [_animals removeAllObjects];
    SZFriendsAnimalSet *set = SZFriendsCurrentAnimalSet();
    NSInteger setNumber = (NSInteger)SZFNum(picture, @"animal_set");
    id selectedValue = picture[@"selected_index"];
    NSInteger selected = [selectedValue isKindOfClass:NSNumber.class] ? [selectedValue integerValue] : -1;
    if (!set || !_showingAnimals) return;
    __weak SZFriendsProfilePage *weakSelf = self;
    for (NSInteger index = 0; index < set.count; index++) {
        if (![set containsIndex:index]) continue;
        NSDictionary *avatar = @{@"kind" : @"animal", @"set" : @(setNumber), @"index" : @(index), @"initials" : @"",
                                 @"color" : [set colorAtIndex:index] ?: @"#5a5a66"};
        SZFriendsButton *button = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStylePlain
                                                        appearance:self.context.appearance];
        button.icon = ^(NSRect rect, NSColor *color) {
            (void)color;
            SZFriendsDrawAvatar(avatar, rect);
        };
        button.iconSize = NSMakeSize(36, 36);
        button.selectedLook = index == selected;
        button.accessibilityLabel = [set nameAtIndex:index];
        button.toolTip = button.accessibilityLabel;
        button.onPress = ^(SZFriendsButton *pressed) {
            (void)pressed;
            [weakSelf.context.link sendIntent:@"set_picture"
                                       fields:@{@"picture" : @{@"kind" : @"animal", @"set" : @(setNumber),
                                                               @"index" : @(index)}}
                                        reply:nil];
        };
        [_animals addObject:button];
        [_content addSubview:button];
    }
}

- (void)toggleAnimals {
    _showingAnimals = !_showingAnimals;
    _photoButton.selectedLook = _showingAnimals;
    [self rebuildAnimals:SZFDict(_data, @"picture")];
    [self setNeedsLayout:YES];
}

#pragma mark - Add by ID, name

// Send request rests until something is typed, as Save does beside the name.
- (void)updateAddButton {
    NSString *typed = [_addField.stringValue ?: @"" stringByTrimmingCharactersInSet:
                                                        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    _addButton.enabled = typed.length > 0;
    _addButton.needsDisplay = YES;
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == _addField) [self updateAddButton];
}

- (void)sendAddRequest {
    NSString *friendsID = [_addField.stringValue ?: @"" stringByTrimmingCharactersInSet:
                                                            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!friendsID.length) return;
    __weak SZFriendsProfilePage *weakSelf = self;
    [self.context.link sendIntent:@"add_by_id" fields:@{@"friends_id" : friendsID}
                            reply:^(NSDictionary *result, SZFriendsLinkError *error) {
                                SZFriendsProfilePage *page = weakSelf;
                                if (!page) return;
                                page->_addFailed = error != nil;
                                NSString *message = error ? error.message : SZFStr(result, @"message");
                                page->_addResult.stringValue = message ?: @"";
                                page->_addResult.textColor = error ? page.context.appearance.destructiveColor
                                                                   : page.context.appearance.primaryTextColor;
                                // The answer appears under the field, out of VoiceOver's way: speak it too.
                                [page.context announce:message];
                                if (!error) page->_addField.stringValue = @"";
                                [page updateAddButton];
                                page->_revealAdd = YES; // and in view, however short the dropdown
                                [page setNeedsLayout:YES];
                            }];
}

- (NSTextField *)nameField {
    return _nameEditor.field;
}

// Escape in the name field: the saved name comes back, and the field lets go.
- (void)cancelNameEdit {
    _nameEditor.field.stringValue = _appliedName ?: @"";
    [_nameEditor reset];
    _nameEditor.field.stringValue = _appliedName ?: @"";
    if (_nameEditor.field.currentEditor) [self.window makeFirstResponder:nil];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    (void)textView;
    if (command == @selector(cancelOperation:)) {
        SZFriendsForwardEscape(self);
        return YES;
    }
    if (command != @selector(insertNewline:)) return NO;
    if (control == _addField) [self sendAddRequest];
    return YES;
}

#pragma mark - Your own picture

- (void)beginCropForImageAtPath:(NSString *)path {
    [_cropView removeFromSuperview];
    SZFriendsCropView *crop = [[SZFriendsCropView alloc] initWithContext:self.context imagePath:path];
    __weak SZFriendsProfilePage *weakSelf = self;
    NSString *imagePath = [path copy];
    crop.onCancel = ^{ [weakSelf dismissInnermostPicker]; };
    crop.onUse = ^(NSDictionary *square) {
        SZFriendsProfilePage *page = weakSelf;
        NSDictionary *picture = @{@"kind" : @"image", @"path" : imagePath, @"crop" : square};
        [page.context.link sendIntent:@"set_picture" fields:@{@"picture" : picture} reply:nil];
        [page dismissInnermostPicker];
    };
    _cropView = crop;
    [self addSubview:crop];
    [self setNeedsLayout:YES];
}

- (BOOL)dismissInnermostPicker {
    if ([_computers cancelRenaming] || SZFriendsDisarmActionButtons(self)) return YES;
    if (_cropView) {
        [_cropView removeFromSuperview];
        _cropView = nil;
        return YES;
    }
    if (_showingAnimals) {
        [self toggleAnimals];
        return YES;
    }
    return NO;
}

#pragma mark - Layout

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    _header.frame = NSMakeRect(0, 0, width, SZFriendsHeaderHeight);
    _scroll.frame = NSMakeRect(0, SZFriendsHeaderHeight, width, height - SZFriendsHeaderHeight);
    _cropView.frame = _scroll.frame;
    CGFloat pad = 16, inner = width - 2 * pad, y = 14;
    _avatar.frame = NSMakeRect(pad, y + 4, 44, 44);
    CGFloat photoWidth = MAX(72, [_photoButton fittingWidth]);
    // The name and its Save take the row beside the picture; Choose picture goes under them, so the name being
    // typed stays readable at the narrowest dropdown.
    CGFloat fieldX = pad + 56, fieldWidth = inner - 56;
    _nameLabel.frame = NSMakeRect(fieldX, y, fieldWidth, 15);
    CGFloat editorHeight = [_nameEditor heightForWidth:fieldWidth];
    _nameEditor.frame = NSMakeRect(fieldX, y + 19, fieldWidth, editorHeight);
    _photoButton.frame = NSMakeRect(fieldX, y + 19 + editorHeight + 8, photoWidth, 28);
    y += 19 + editorHeight + 8 + 28 + 14;
    _animalsTitle.hidden = _ownPictureButton.hidden = !_showingAnimals;
    if (_showingAnimals) {
        y = SZFriendsPlace(_animalsTitle, pad, y, inner) + 8;
        CGFloat cell = 44;
        NSInteger columns = MAX(1, (NSInteger)floor((inner + 4) / (cell + 4)));
        CGFloat gap = columns > 1 ? (inner - columns * cell) / (columns - 1) : 0;
        for (NSUInteger i = 0; i < _animals.count; i++) {
            NSInteger column = (NSInteger)i % columns, row = (NSInteger)i / columns;
            _animals[i].frame = NSMakeRect(floor(pad + column * (cell + gap)), y + row * (cell + 4), cell, cell);
        }
        if (_animals.count) y += ((_animals.count + columns - 1) / columns) * (cell + 4) + 4;
        _ownPictureButton.frame = NSMakeRect(pad - 2, y, [_ownPictureButton fittingWidth], 20);
        y += 20 + 14;
    }
    CGFloat qrSide = _qr.hidden ? 0 : _largeQR ? MIN(200, inner - 24) : 92;
    CGFloat cardInner = inner - 24, textWidth = _largeQR || _qr.hidden ? cardInner : cardInner - qrSide - 12;
    CGFloat cardY = 12;
    cardY = SZFriendsPlace(_idTitle, 12, cardY, textWidth) + 6;
    cardY = SZFriendsPlace(_idValue, 12, cardY, textWidth) + 8;
    CGFloat copyWidth = MAX(56, [_cpyButton fittingWidth]), qrWidth = MAX(72, [_qrButton fittingWidth]);
    _cpyButton.frame = NSMakeRect(12, cardY, copyWidth, 26);
    _qrButton.frame = NSMakeRect(12 + copyWidth + 8, cardY, qrWidth, 26);
    cardY += 26 + 8;
    cardY = SZFriendsPlace(_idNote, 12, cardY, textWidth);
    if (_qr.hidden) {
        _qr.frame = NSZeroRect;
    } else if (_largeQR) {
        _qr.frame = NSMakeRect(12 + floor((cardInner - qrSide) / 2), cardY + 12, qrSide, qrSide);
        cardY += 12 + qrSide;
    } else {
        _qr.frame = NSMakeRect(12 + cardInner - qrSide, 12, qrSide, qrSide);
        cardY = MAX(cardY, 12 + qrSide);
    }
    _idCard.frame = NSMakeRect(pad, y, inner, cardY + 12);
    y += cardY + 12 + 14;
    CGFloat linksHeight = [_links layoutForWidth:inner];
    _links.frame = NSMakeRect(pad, y, inner, linksHeight);
    if (linksHeight > 0) y += linksHeight + 4;
    CGFloat computersHeight = [_computers layoutForWidth:inner];
    _computers.frame = NSMakeRect(pad, y, inner, computersHeight);
    if (computersHeight > 0) y += computersHeight + 10;
    _divider = y;
    y += 15;
    y = SZFriendsPlace(_addLabel, pad, y, inner) + 8;
    CGFloat addWidth = MAX(96, [_addButton fittingWidth]);
    _addField.frame = NSMakeRect(pad, y, inner - addWidth - 8, 28);
    _addButton.frame = NSMakeRect(width - pad - addWidth, y, addWidth, 28);
    y += 28 + 6;
    y = SZFriendsPlace(_addHint, pad, y, inner);
    if (_addResult.stringValue.length) y = SZFriendsPlace(_addResult, pad, y + 10, inner);
    else _addResult.hidden = YES;
    _content.frame = NSMakeRect(0, 0, width, MAX(y + 16, NSHeight(_scroll.frame)));
    _content.needsDisplay = YES;
    if (_revealAdd && _data && _addLabel.stringValue.length) {
        _revealAdd = NO;
        NSRect section = NSUnionRect(_addLabel.frame, _addResult.hidden ? _addHint.frame : _addResult.frame);
        [_content scrollRectToVisible:NSInsetRect(section, 0, -12)];
    }
}

@end
