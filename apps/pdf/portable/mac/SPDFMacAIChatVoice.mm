// Voice input in the chat composer: the microphone beside Send (or ⌥⌘V) listens, and what you say fills the text box as
// you speak, at the caret or over the selection, keeping what was already typed. It never sends. Clicking again, ⌥⌘V,
// Return or Esc stops listening and keeps what was heard; sending, switching chats and closing the panel stop it too.
// Speech becomes text on this Mac (SPDFMacVoiceTranscriber.swift, macOS 26); the assistant only gets the message you
// send. Right-clicking the microphone picks the language; it follows the keyboard's input source unless you pick one.
#import "SPDFMacAIChatViewInternal.h"
#import "SPDFMacVoiceTranscriber.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacIconGeometry.h"

static NSString* const SPDFVoiceLanguageKey = @"SPDFVoiceInputLanguage";
static NSString* const SPDFVoiceIdleTip = @"Speak your message (⌥⌘V). Right-click to choose the language.";

static NSString* SPDFVoiceLanguageName(NSString* identifier) {
    return [NSLocale.currentLocale localizedStringForLocaleIdentifier:identifier] ?: identifier;
}

// Languages written without spaces between words, so heard words are not spaced from the text before them.
// Just the language ("Chinese"), for the line under the composer; the menu names the variant.
static NSString* SPDFVoiceLanguageShortName(NSString* identifier) {
    NSString* code = [NSLocale localeWithLocaleIdentifier:identifier].languageCode;
    return (code ? [NSLocale.currentLocale localizedStringForLanguageCode:code] : nil) ?: SPDFVoiceLanguageName(identifier);
}

static BOOL SPDFVoiceLanguageUsesSpaces(NSString* identifier) {
    NSString* code = [[identifier componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-_"]]
        firstObject].lowercaseString;
    return ![@[ @"zh", @"ja", @"yue", @"th", @"wuu" ] containsObject:code ?: @""];
}

// The microphone: "mic" when idle, "mic.fill" in the accent colour while listening, dimmed with a ring filling up while
// the language's speech model downloads.
@interface SPDFChatMicButton : SPDFChatButton
@property(nonatomic) NSInteger phase;  // 0 idle, 1 getting ready or downloading, 2 listening
@property(nonatomic) double fraction;  // the download's progress, or below 0 before it has any
@end
@implementation SPDFChatMicButton
- (void)setPhase:(NSInteger)phase {
    _phase = phase;
    self.image = [NSImage imageWithSystemSymbolName:phase == 2 ? @"mic.fill" : @"mic" accessibilityDescription:nil];
    self.needsDisplay = YES;
}
- (void)setFraction:(double)fraction { _fraction = fraction; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
    if (self.phase == 0) { [super drawRect:dirty]; return; }
    NSColor* accent = SPDFCollectionColor(@"accent");
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, .5, .5) xRadius:5 yRadius:5];
    if (self.phase == 2) { [[accent colorWithAlphaComponent:.14] setFill]; [shape fill]; }
    NSColor* ink = self.phase == 2 ? accent : SPDFCollectionColor(@"secondary");
    NSImage* icon = SPDFChromeSymbolImage(self.image, SPDFToolbarSymbolPointSize, NSFontWeightMedium, ink);
    SPDFDrawVectorIconWithFraction(icon, NSInsetRect(self.bounds, 3, 3), YES, self.phase == 2 ? 1 : .6);
    if (self.phase == 1 && self.fraction >= 0) {
        NSPoint center = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
        CGFloat radius = MIN(NSWidth(self.bounds), NSHeight(self.bounds)) / 2 - 2;
        NSBezierPath* track = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x - radius, center.y - radius, 2 * radius, 2 * radius)];
        track.lineWidth = 2;
        [[SPDFCollectionColor(@"line") colorWithAlphaComponent:.8] setStroke];
        [track stroke];
        NSBezierPath* arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter:center radius:radius startAngle:-90
                                      endAngle:-90 + 360 * MAX(.03, MIN(1, self.fraction)) clockwise:NO];
        arc.lineWidth = 2;
        arc.lineCapStyle = NSLineCapStyleRound;
        [accent setStroke];
        [arc stroke];
    }
}
@end

// One listening session's bookkeeping, and the language menu.
@interface SPDFChatVoiceInput : NSObject <NSMenuDelegate>
@property(nonatomic, weak) SPDFMacAIChatView* view;
@property(nonatomic) id<SPDFVoiceTranscribing> transcriber;
@property(nonatomic, copy) NSString* language;   // the language listening now, or about to
@property(nonatomic, copy) NSString* before;     // the composer's text when listening began, for Undo
@property(nonatomic, copy) NSString* shown;      // the heard words now in the composer, at `anchor`
@property(nonatomic) NSUInteger anchor, skip, settled;
@property(nonatomic) BOOL listening, finishing;
@property(nonatomic) id monitor;
@property(nonatomic, copy) NSArray<NSString*>* supported;
@property(nonatomic, copy) NSArray<NSString*>* installed;
@property(nonatomic) BOOL loadingLanguages;
@property(nonatomic) BOOL restartAfterStop;
@property(nonatomic) id windowClosing;
@end
@implementation SPDFChatVoiceInput
- (void)loadLanguages:(void (^)(void))then {
    Class<SPDFVoiceTranscribing> engine = SPDFVoiceTranscriberClass();
    if (!engine || self.loadingLanguages) return;
    self.loadingLanguages = YES;
    __weak SPDFChatVoiceInput* weakSelf = self;
    [engine loadLanguages:^(NSArray<NSString*>* supported, NSArray<NSString*>* installed) {
        SPDFChatVoiceInput* strongSelf = weakSelf;
        strongSelf.supported = supported; strongSelf.installed = installed; strongSelf.loadingLanguages = NO;
        if (then) then();
    }];
}
- (NSMenuItem*)item:(NSString*)title language:(NSString*)language chosen:(NSString*)chosen {
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:@selector(chooseLanguage:) keyEquivalent:@""];
    item.target = self; item.representedObject = language ?: @"";
    item.state = [(language ?: @"") isEqual:chosen ?: @""] ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}
- (void)menuNeedsUpdate:(NSMenu*)menu {
    [menu removeAllItems];
    NSString* chosen = [NSUserDefaults.standardUserDefaults stringForKey:SPDFVoiceLanguageKey];
    NSString* keyboard = [SPDFVoiceTranscriberClass() inputSourceLanguages].firstObject;
    NSString* follow = keyboard.length ? [NSString stringWithFormat:@"Same as Keyboard (%@)", SPDFVoiceLanguageName(keyboard)]
                                       : @"Same as Keyboard";
    [menu addItem:[self item:follow language:nil chosen:chosen]];
    [menu addItem:NSMenuItem.separatorItem];
    if (!self.supported) {
        NSMenuItem* wait = [[NSMenuItem alloc] initWithTitle:@"Finding languages…" action:nil keyEquivalent:@""];
        wait.enabled = NO; [menu addItem:wait];
        __weak NSMenu* weakMenu = menu; __weak SPDFChatVoiceInput* weakSelf = self;
        [self loadLanguages:^{ NSMenu* open = weakMenu; if (open) [weakSelf menuNeedsUpdate:open]; }];
        return;
    }
    NSComparator byName = ^NSComparisonResult(NSString* a, NSString* b) {
        return [SPDFVoiceLanguageName(a) localizedStandardCompare:SPDFVoiceLanguageName(b)];
    };
    for (NSString* language in [self.installed sortedArrayUsingComparator:byName])
        [menu addItem:[self item:SPDFVoiceLanguageName(language) language:language chosen:chosen]];
    NSMutableArray* others = [self.supported mutableCopy];
    [others removeObjectsInArray:self.installed];
    if (!others.count) return;
    NSMenuItem* more = [[NSMenuItem alloc] initWithTitle:@"More Languages" action:nil keyEquivalent:@""];
    more.submenu = [NSMenu new];
    NSMenuItem* note = [[NSMenuItem alloc] initWithTitle:@"Downloaded the first time you use one" action:nil keyEquivalent:@""];
    note.enabled = NO; [more.submenu addItem:note];
    for (NSString* language in [others sortedArrayUsingComparator:byName])
        [more.submenu addItem:[self item:SPDFVoiceLanguageName(language) language:language chosen:chosen]];
    [menu addItem:more];
}
- (void)chooseLanguage:(NSMenuItem*)item {
    NSString* language = item.representedObject;
    if (language.length) [NSUserDefaults.standardUserDefaults setObject:language forKey:SPDFVoiceLanguageKey];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:SPDFVoiceLanguageKey];
    SPDFMacAIChatView* view = self.view;
    if (self.listening && !self.finishing) { self.restartAfterStop = YES; [view stopVoiceInput]; }
}
@end

@implementation SPDFMacAIChatView (Voice)

- (SPDFChatVoiceInput*)voiceInput { return (SPDFChatVoiceInput*)_voiceInput; }

- (void)setUpVoice {
    SPDFChatMicButton* mic = [[SPDFChatMicButton alloc] initWithFrame:NSZeroRect];
    mic.title = @""; mic.bordered = NO; mic.identifier = @"voice"; mic.target = self;
    mic.action = @selector(toggleVoiceInput:); mic.translatesAutoresizingMaskIntoConstraints = NO;
    mic.phase = 0; mic.toolTip = SPDFVoiceIdleTip; mic.accessibilityLabel = @"Voice input";
    mic.hidden = !SPDFVoiceTranscriberClass();
    [mic.widthAnchor constraintEqualToConstant:28].active = YES;
    [mic.heightAnchor constraintEqualToConstant:28].active = YES;
    _mic = mic;
    [self addSubview:mic];
    SPDFChatVoiceInput* voice = [SPDFChatVoiceInput new];
    voice.view = self;
    _voiceInput = voice;
    NSMenu* languages = [NSMenu new];
    languages.delegate = voice;
    mic.menu = languages;
    // Under the composer, when voice input can't start: what happened and the one thing to do about it.
    _voiceNoteText = SPDFCollectionText(@"", 11, NSFontWeightRegular, YES);
    _voiceNoteText.identifier = @"voiceNote"; _voiceNoteText.maximumNumberOfLines = 2;
    _voiceNoteText.cell.truncatesLastVisibleLine = YES;
    [_voiceNoteText setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    _voiceNoteButton = [self button:@"Open Settings…" action:@"voiceNote"];
    _voiceNoteButton.target = self; _voiceNoteButton.action = @selector(voiceNoteAction:);
    [_voiceNoteButton setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    _voiceNote = [NSStackView stackViewWithViews:@[ _voiceNoteText, _voiceNoteButton ]];
    _voiceNote.spacing = 8; _voiceNote.identifier = @"voiceNoteRow"; _voiceNote.hidden = YES;
    _voiceNote.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_voiceNote];
    // The microphone sits between Stop and Send; the note, when shown, between the composer and that row.
    for (NSLayoutConstraint* constraint in self.constraints)
        if (constraint.firstItem == _input && constraint.firstAttribute == NSLayoutAttributeBottom) constraint.active = NO;
    _stopTrailing.active = NO;
    _stopTrailing = [_stop.trailingAnchor constraintEqualToAnchor:mic.leadingAnchor constant:-8];
    _inputAboveButtons = [_input.bottomAnchor constraintEqualToAnchor:_send.topAnchor constant:-8];
    _inputAboveNote = [_input.bottomAnchor constraintEqualToAnchor:_voiceNote.topAnchor constant:-6];
    [NSLayoutConstraint activateConstraints:@[
        _stopTrailing, _inputAboveButtons,
        [mic.trailingAnchor constraintEqualToAnchor:_send.leadingAnchor constant:-6],
        [mic.centerYAnchor constraintEqualToAnchor:_send.centerYAnchor],
        [_voiceNote.leadingAnchor constraintEqualToAnchor:_input.leadingAnchor],
        [_voiceNote.trailingAnchor constraintEqualToAnchor:_input.trailingAnchor],
        [_voiceNote.bottomAnchor constraintEqualToAnchor:_send.topAnchor constant:-8],
    ]];
}

- (NSString*)voiceHint {
    SPDFChatVoiceInput* voice = [self voiceInput];
    SPDFChatMicButton* mic = (SPDFChatMicButton*)_mic;
    if (!voice || mic.phase == 0 || _history) return nil;
    NSString* name = SPDFVoiceLanguageShortName(voice.language ?: @"");
    if (mic.phase == 1 && mic.fraction >= 0)
        return [NSString stringWithFormat:@"Downloading %@ speech recognition… %.0f%%", name, 100 * mic.fraction];
    if (mic.phase == 1) return @"Getting ready to listen…";
    return [NSString stringWithFormat:@"Listening in %@ · ↵ or Esc stops", name];
}

- (void)showVoiceHint {
    if (_history) return;
    _inputHelp.stringValue = [self voiceHint] ?: @"↵ Send · ⇧↵ New line";
    SPDFChatMicButton* mic = (SPDFChatMicButton*)_mic;
    mic.toolTip = mic.phase == 2 ? @"Stop listening (⌥⌘V, Return or Esc)"
        : mic.phase == 1 ? @"Stop getting ready (⌥⌘V)" : SPDFVoiceIdleTip;
}

- (void)updateVoiceButton {
    _mic.hidden = _history || !SPDFVoiceTranscriberClass();
    if (_history) { [self endVoiceInput]; _voiceNote.hidden = YES; [self placeVoiceNote]; }
}

- (void)placeVoiceNote {
    if (_voiceNote.hidden) { _inputAboveNote.active = NO; _inputAboveButtons.active = YES; }
    else { _inputAboveButtons.active = NO; _inputAboveNote.active = YES; }
}

// `kind`: what went wrong (SPDFMacVoiceTranscriber.h); nil hides the note.
- (void)showVoiceNote:(NSString*)kind {
    SPDFChatVoiceInput* voice = [self voiceInput];
    NSString* name = SPDFVoiceLanguageShortName(voice.language ?: @"");
    NSString* text = nil, *button = nil;
    if ([kind isEqual:@"microphone"]) {
        text = @"To speak your message, allow Shenzhen PDF to use the microphone in System Settings.";
        button = @"Open Settings…";
    } else if ([kind isEqual:@"download"]) {
        text = [NSString stringWithFormat:@"%@ speech recognition couldn’t be downloaded. Check your internet connection.", name];
        button = @"Try Again";
    } else if ([kind isEqual:@"language"]) {
        text = @"Speech in this language can’t be turned into text on this Mac. Right-click the microphone to pick another.";
    } else if ([kind isEqual:@"audio"]) {
        text = @"The microphone didn’t start. Check it’s connected and chosen as the input in Sound settings.";
        button = @"Open Sound Settings…";
    } else if (kind) {
        text = @"Voice input stopped unexpectedly. Click the microphone to try again.";
    }
    _voiceNoteText.stringValue = text ?: @"";
    _voiceNoteText.toolTip = text;
    _voiceNoteButton.title = button ?: @"";
    _voiceNoteButton.accessibilityLabel = button; _voiceNoteButton.toolTip = button;
    _voiceNoteButton.hidden = !button;
    _voiceNoteButton.identifier = kind ?: @"";
    [_voiceNoteButton invalidateIntrinsicContentSize];
    _voiceNote.hidden = !text;
    [self placeVoiceNote];
    if (text) NSAccessibilityPostNotification(_voiceNoteText, NSAccessibilityValueChangedNotification);
}

- (void)voiceNoteAction:(NSButton*)sender {
    NSString* kind = sender.identifier;
    if ([kind isEqual:@"download"]) { [self showVoiceNote:nil]; [self toggleVoiceInput:nil]; return; }
    NSString* pane = [kind isEqual:@"audio"] ? @"x-apple.systempreferences:com.apple.Sound-Settings.extension?input"
        : @"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone";
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:pane]];
}

- (void)setVoicePhase:(NSInteger)phase fraction:(double)fraction {
    SPDFChatMicButton* mic = (SPDFChatMicButton*)_mic;
    mic.phase = phase; mic.fraction = fraction;
    [self showVoiceHint];
}

- (void)toggleVoiceInput:(id)sender {
    (void)sender;
    SPDFChatVoiceInput* voice = [self voiceInput];
    Class<SPDFVoiceTranscribing> engine = SPDFVoiceTranscriberClass();
    if (!voice || !engine || _history) return;
    if (voice.listening) {
        if (voice.finishing) return;
        if (((SPDFChatMicButton*)_mic).phase == 2) [self stopVoiceInput]; else [self endVoiceInput];
        return;
    }
    [self showVoiceNote:nil];
    voice.listening = YES;
    [self setVoicePhase:1 fraction:-1];
    [self.window makeFirstResponder:_composer];
    __weak __typeof__(self) weakSelf = self;
    void (^begin)(void) = ^{ [weakSelf beginVoiceInput]; };
    NSInteger status = [engine microphoneStatus];
    if (status == 1) begin();
    else if (status == 0) [engine requestMicrophone:^(BOOL granted) {
        if (granted) begin(); else [weakSelf failVoiceInput:@"microphone"];
    }];
    else [self failVoiceInput:@"microphone"];
}

- (void)failVoiceInput:(NSString*)kind {
    [self endVoiceInput];
    [self showVoiceNote:kind];
}

- (void)beginVoiceInput {
    SPDFChatVoiceInput* voice = [self voiceInput];
    Class<SPDFVoiceTranscribing> engine = SPDFVoiceTranscriberClass();
    if (!voice.listening || voice.transcriber || !engine) return;
    NSString* wanted = [NSUserDefaults.standardUserDefaults stringForKey:SPDFVoiceLanguageKey];
    if (!wanted.length) wanted = [engine inputSourceLanguages].firstObject ?: NSLocale.preferredLanguages.firstObject ?: @"en-US";
    __weak __typeof__(self) weakSelf = self;
    [engine resolveLanguage:wanted done:^(NSString* found) {
        __typeof__(self) strongSelf = weakSelf;
        SPDFChatVoiceInput* current = [strongSelf voiceInput];
        if (!strongSelf || !current.listening || current.transcriber) return;
        current.language = found ?: wanted;
        if (!found) { [strongSelf failVoiceInput:@"language"]; return; }
        [strongSelf startTranscriber:[(Class)engine new]];
    }];
}

- (void)startTranscriber:(id<SPDFVoiceTranscribing>)transcriber {
    SPDFChatVoiceInput* voice = [self voiceInput];
    NSRange selection = _composer.selectedRange;
    if (NSMaxRange(selection) > _composer.string.length) selection = NSMakeRange(_composer.string.length, 0);
    voice.transcriber = transcriber;
    voice.before = [_composer.string copy];
    voice.anchor = selection.location; voice.shown = [_composer.string substringWithRange:selection];
    voice.skip = 0; voice.settled = 0; voice.finishing = NO;
    [_composer breakUndoCoalescing];
    __weak __typeof__(self) weakSelf = self;
    __weak id<SPDFVoiceTranscribing> weakTranscriber = transcriber;
    transcriber.onText = ^(NSString* settled, NSString* pending) {
        if ([weakSelf voiceInput].transcriber == weakTranscriber) [weakSelf voiceHeard:settled pending:pending];
    };
    transcriber.onState = ^(NSString* state, double fraction) {
        __typeof__(self) strongSelf = weakSelf;
        if ([strongSelf voiceInput].transcriber != weakTranscriber) return;
        if ([state isEqual:@"downloading"]) [strongSelf setVoicePhase:1 fraction:fraction];
        else if ([state isEqual:@"listening"]) [strongSelf setVoicePhase:2 fraction:0];
        else if ([state isEqual:@"stopped"]) [strongSelf finishVoiceInput];
    };
    transcriber.onError = ^(NSString* kind, NSString* message) {
        __typeof__(self) strongSelf = weakSelf;
        if ([strongSelf voiceInput].transcriber != weakTranscriber) return;
        NSLog(@"Voice input: %@: %@", kind, message);
        [strongSelf failVoiceInput:kind];
    };
    voice.monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent* event) {
        return [weakSelf voiceKey:event] ? nil : event;
    }];
    [transcriber startWithLanguage:voice.language];
}

// Return and Esc stop listening instead of sending or closing; the words heard stay in the composer.
- (BOOL)voiceKey:(NSEvent*)event {
    SPDFChatVoiceInput* voice = [self voiceInput];
    if (!voice.listening || voice.finishing || event.window != self.window || _composer.hasMarkedText) return NO;
    BOOL shift = (event.modifierFlags & NSEventModifierFlagShift) != 0;
    if (event.keyCode != 53 && !((event.keyCode == 36 || event.keyCode == 76) && !shift)) return NO;
    [self toggleVoiceInput:nil];
    return YES;
}

- (void)voiceHeard:(NSString*)settled pending:(NSString*)pending {
    SPDFChatVoiceInput* voice = [self voiceInput];
    NSString* text = _composer.string;
    NSRange range = NSMakeRange(voice.anchor, voice.shown.length);
    // Typing or editing over the words being heard leaves them as they are; what comes next goes at the caret.
    if (NSMaxRange(range) > text.length || ![[text substringWithRange:range] isEqual:voice.shown]) {
        voice.anchor = MIN(_composer.selectedRange.location, text.length); voice.shown = @""; voice.skip = voice.settled;
        range = NSMakeRange(voice.anchor, 0);
    }
    NSString* heard = [settled stringByAppendingString:pending];
    NSString* piece = heard.length >= voice.skip ? [heard substringFromIndex:voice.skip] : heard;
    piece = [piece stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    voice.settled = settled.length;
    if (!piece.length && !voice.shown.length) return;
    NSCharacterSet* space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    if (piece.length && range.location > 0 && SPDFVoiceLanguageUsesSpaces(voice.language ?: @"") &&
        ![space characterIsMember:[text characterAtIndex:range.location - 1]] &&
        ![NSCharacterSet.punctuationCharacterSet characterIsMember:[piece characterAtIndex:0]])
        piece = [@" " stringByAppendingString:piece];
    if ([piece isEqual:voice.shown]) return;
    // In the composer's own font and colour: a bare string at the start of an empty box would come out black.
    [_composer.textStorage replaceCharactersInRange:range
                               withAttributedString:[[NSAttributedString alloc] initWithString:piece
                                                                                    attributes:_composer.typingAttributes]];
    [_composer didChangeText];
    voice.shown = piece;
    _composer.selectedRange = NSMakeRange(range.location + piece.length, 0);
    [_composer scrollRangeToVisible:_composer.selectedRange];
}

// Stops listening: the words already heard settle, then finishVoiceInput.
- (void)stopVoiceInput {
    SPDFChatVoiceInput* voice = [self voiceInput];
    if (!voice.listening || voice.finishing) return;
    if (!voice.transcriber) { [self endVoiceInput]; return; }
    voice.finishing = YES;
    if (voice.monitor) [NSEvent removeMonitor:voice.monitor];
    voice.monitor = nil;
    [self setVoicePhase:0 fraction:0];
    id<SPDFVoiceTranscribing> transcriber = voice.transcriber;
    [transcriber stop];
    // The last words settle in well under a second; should they not, the composer keeps what it shows.
    __weak __typeof__(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([weakSelf voiceInput].transcriber == transcriber) [weakSelf finishVoiceInput];
    });
}

- (void)finishVoiceInput {
    SPDFChatVoiceInput* voice = [self voiceInput];
    NSString* before = voice.before, *after = [_composer.string copy];
    BOOL restart = voice.restartAfterStop;
    [self endVoiceInput];
    // One Undo takes back everything heard in this session.
    NSUndoManager* undo = _composer.undoManager;
    if (before && ![before isEqual:after] && undo) {
        __weak SPDFChatComposer* composer = _composer;
        __block void (^restore)(NSString*, NSString*);
        void (^set)(NSString*, NSString*) = ^(NSString* text, NSString* other) {
            composer.string = text; composer.selectedRange = NSMakeRange(text.length, 0);
            [undo registerUndoWithTarget:composer handler:^(id target) { (void)target; restore(other, text); }];
        };
        restore = set;
        [undo registerUndoWithTarget:composer handler:^(id target) { (void)target; set(before, after); }];
        [undo setActionName:@"Voice Input"];
    }
    if (restart) dispatch_async(dispatch_get_main_queue(), ^{ [self toggleVoiceInput:nil]; });
}

// Stops listening at once, leaving the composer as it is (sending, another chat, the panel closing).
- (void)endVoiceInput {
    SPDFChatVoiceInput* voice = [self voiceInput];
    if (!voice.listening) return;
    id<SPDFVoiceTranscribing> transcriber = voice.transcriber;
    // Heard words go in without Undo steps of their own; Undo steps for typing in the box meanwhile would point at
    // text that has moved, so they go (finishVoiceInput then adds one step for the whole session).
    if (voice.before && ![voice.before isEqual:_composer.string])
        [_composer.undoManager removeAllActionsWithTarget:_composer.textStorage];
    voice.transcriber = nil; voice.listening = NO; voice.finishing = NO; voice.restartAfterStop = NO;
    voice.before = nil; voice.shown = nil;
    transcriber.onText = nil; transcriber.onState = nil; transcriber.onError = nil;
    [transcriber cancel];
    if (voice.monitor) [NSEvent removeMonitor:voice.monitor];
    voice.monitor = nil;
    [self setVoicePhase:0 fraction:0];
}

- (BOOL)performKeyEquivalent:(NSEvent*)event {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask &
        (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagShift);
    if (flags == (NSEventModifierFlagCommand | NSEventModifierFlagOption) && _mic && !_mic.hiddenOrHasHiddenAncestor &&
        [event.charactersIgnoringModifiers.lowercaseString isEqual:@"v"]) {
        [self toggleVoiceInput:nil];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

- (void)viewDidHide { [super viewDidHide]; [self endVoiceInput]; }
- (void)viewWillMoveToWindow:(NSWindow*)window {
    if (window != self.window) [self endVoiceInput];
    [super viewWillMoveToWindow:window];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    SPDFChatVoiceInput* voice = [self voiceInput];
    if (voice.windowClosing) [NSNotificationCenter.defaultCenter removeObserver:voice.windowClosing];
    voice.windowClosing = nil;
    if (!self.window || !voice || _mic.hidden) return;
    __weak __typeof__(self) weakSelf = self;
    voice.windowClosing = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification
        object:self.window queue:nil usingBlock:^(NSNotification* note) { (void)note; [weakSelf endVoiceInput]; }];
    if (voice.supported) return;
    // The language menu's list, fetched once the panel is up rather than when it opens.
    __weak SPDFChatVoiceInput* weakVoice = voice;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [weakVoice loadLanguages:nil];
    });
}

@end
