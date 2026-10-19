#import "SPDFMacAIAppControls.h"

NSString* const SPDFMacAIAppControlsHiddenPrefix = @"szfriends.";

static BOOL HiddenIdentifier(NSString* identifier) {
    return [identifier isKindOfClass:NSString.class] && [identifier hasPrefix:SPDFMacAIAppControlsHiddenPrefix];
}
BOOL SPDFMacAIAppControlsHidesWindow(NSWindow* window) {
    return window && (HiddenIdentifier(window.identifier) || HiddenIdentifier(window.contentView.identifier));
}
BOOL SPDFMacAIAppControlsHidesView(NSView* view) {
    for(NSView* ancestor=view;ancestor;ancestor=ancestor.superview)if(HiddenIdentifier(ancestor.identifier))return YES;
    return SPDFMacAIAppControlsHidesWindow(view.window);
}
BOOL SPDFMacAIAppControlsHidesMenuItem(NSMenuItem* item) {
    for(NSMenuItem* current=item;current;current=current.parentItem)if(HiddenIdentifier(current.identifier))return YES;
    return NO;
}
static BOOL Secret(NSView* view) {
    NSString* placeholder=[view isKindOfClass:NSTextField.class] ? [(NSTextField*)view placeholderString] : @"";
    NSString* name=[NSString stringWithFormat:@"%@ %@ %@ %@",view.identifier ?: @"",
        view.accessibilityLabel ?: @"",view.toolTip ?: @"",placeholder ?: @""];
    if([view isKindOfClass:NSSecureTextField.class])return YES;
    for(NSString* word in @[@"password",@"credential",@"api key",@"apiKey",@"api_key",@"secret",@"access token"])
        if([name localizedCaseInsensitiveContainsString:word])return YES;
    return NO;
}
static BOOL Available(NSControl* control) {
    NSWindow* window=control.window;
    if(!window.visible || window.miniaturized || window.attachedSheet || !control.enabled ||
        (NSApp.modalWindow && NSApp.modalWindow!=window))return NO;
    // Checked again at the moment of use: a control may have moved under hidden interface since it was listed.
    if(SPDFMacAIAppControlsHidesView(control))return NO;
    for(NSView* view=control;view;view=view.superview)if(view.hidden || Secret(view))return NO;
    return control.action!=@selector(terminate:);
}
static id Value(NSControl* control) {
    // NSPopUpButton inherits NSButton; its state is not its selection.
    if([control isKindOfClass:NSPopUpButton.class])return @([(NSPopUpButton*)control indexOfSelectedItem]);
    if([control isKindOfClass:NSButton.class])return @([(NSButton*)control state]);
    return control.stringValue ?: @"";
}
static void NotifyText(NSTextField* field) {
    id delegate=field.delegate;
    if([delegate respondsToSelector:@selector(controlTextDidChange:)])
        [delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification
                                                                     object:field]];
    if([delegate respondsToSelector:@selector(controlTextDidEndEditing:)])
        [delegate controlTextDidEndEditing:[NSNotification notificationWithName:NSControlTextDidEndEditingNotification
                                                                        object:field]];
}
static NSString* Bounded(NSString* value) {
    if(value.isAbsolutePath)value=value.lastPathComponent;
    NSUInteger count=MIN(value.length,(NSUInteger)200);
    // Keep UTF-16 well formed without an unbounded composed-character expansion.
    if(count && CFStringIsSurrogateHighCharacter([value characterAtIndex:count-1]))count--;
    return count<value.length ? [value substringToIndex:count] : value ?: @"";
}
static BOOL AddRow(NSDictionary* row,NSMutableArray* rows,NSUInteger* bytes) {
    NSUInteger size=[NSJSONSerialization dataWithJSONObject:row options:0 error:nil].length;
    if(!size || size>*bytes)return NO;
    *bytes-=size;[rows addObject:row];return YES;
}
static void AddControl(NSView* view,NSMutableArray* rows,NSMutableDictionary* targets,NSUInteger* bytes,
                       NSUInteger* visited,NSUInteger depth) {
    if(!view || view.hidden || Secret(view) || rows.count>=250 || *visited>=3000 || depth>50 || *bytes<256)return;
    // Ancestors were checked on the way down, so the view's own identifier settles its whole subtree.
    if(HiddenIdentifier(view.identifier))return;
    (*visited)++;
    if([view isKindOfClass:NSControl.class]) {
        NSControl* control=(id)view;
        BOOL popup=[control isKindOfClass:NSPopUpButton.class];
        BOOL button=[control isKindOfClass:NSButton.class];
        BOOL editable=[control isKindOfClass:NSTextField.class] && [(NSTextField*)control isEditable];
        if((button || editable || popup) && control.action!=@selector(terminate:)) {
            NSString* identifier=[@"control:" stringByAppendingString:NSUUID.UUID.UUIDString];
            NSString* label=control.accessibilityLabel ?: control.toolTip ?: control.identifier;
            if(!label.length && button)label=[(NSButton*)control title];
            NSMutableDictionary* row=[@{@"id":identifier,@"label":Bounded(label),@"enabled":@(Available(control)),
                @"kind":popup ? @"choice" : button ? @"button" : @"text",
                @"value":Bounded([Value(control) description])} mutableCopy];
            if(popup) {
                NSMutableArray* choices=[NSMutableArray array];NSPopUpButton* choice=(id)control;
                NSUInteger scanned=0;
                for(NSMenuItem* item in choice.itemArray) {
                    if(choices.count>=20 || scanned++>=200)break;
                    // A clipped option cannot be selected by its exact title. Omit it rather than inventing a value.
                    if(item.title.length<=200 && !item.hidden && !item.separatorItem && item.enabled)
                        [choices addObject:item.title];
                }
                row[@"choices"]=choices;row[@"totalChoices"]=@(choice.numberOfItems);
            }
            if(AddRow(row,rows,bytes))targets[identifier]=control;
        }
    }
    for(NSView* child in view.subviews)AddControl(child,rows,targets,bytes,visited,depth+1);
}
static BOOL LiveMenuItem(NSMenuItem* item) {
    if(!item.action || item.action==@selector(terminate:) || item.hidden || !item.enabled)return NO;
    if(SPDFMacAIAppControlsHidesMenuItem(item))return NO;
    NSMenu* menu=item.menu;
    while(menu && menu!=NSApp.mainMenu) {
        NSMenu* parent=menu.supermenu;BOOL found=NO;
        for(NSMenuItem* owner in parent.itemArray)if(owner.submenu==menu && !owner.hidden && owner.enabled)found=YES;
        if(!found)return NO;menu=parent;
    }
    return menu && [item.menu.itemArray containsObject:item];
}
static void AddMenu(NSMenu* menu,NSString* prefix,NSMutableArray* rows,NSMutableDictionary* targets,
                    NSUInteger* bytes,NSUInteger* visited,NSUInteger depth) {
    if(!menu || depth>12 || *visited>=2000 || *bytes<256)return;
    [menu update];
    for(NSMenuItem* item in menu.itemArray) {
        if(rows.count>=300 || *visited>=2000 || *bytes<256)break;
        (*visited)++;
        if(item.separatorItem || item.hidden || HiddenIdentifier(item.identifier))continue;
        NSString* title=prefix.length ? [NSString stringWithFormat:@"%@ → %@",prefix,item.title] : item.title;
        if(item.submenu) {AddMenu(item.submenu,Bounded(title),rows,targets,bytes,visited,depth+1);continue;}
        if(!item.action || item.action==@selector(terminate:))continue;
        NSString* identifier=[@"menu:" stringByAppendingString:NSUUID.UUID.UUIDString];
        if(AddRow(@{@"id":identifier,@"label":Bounded(title),@"enabled":@(LiveMenuItem(item))},rows,bytes))
            targets[identifier]=item;
    }
}
static void QueueNativeAction(void (^action)(void)) {
    // Native commands may enter runModal. Run outside the serial main dispatch queue so a
    // subsequent tool can still inspect and dismiss the dialog in its nested event loop.
    [NSRunLoop.mainRunLoop performInModes:@[NSDefaultRunLoopMode,NSModalPanelRunLoopMode] block:action];
    CFRunLoopWakeUp(CFRunLoopGetMain());
}
NSDictionary* SPDFMacAIAppControlsInspect(NSMenu* mainMenu,NSArray<NSWindow*>* windows,NSMutableDictionary* targets) {
    NSMutableArray* controls=[NSMutableArray array],*menus=[NSMutableArray array];
    NSUInteger menuBytes=32000,controlBytes=32000,menuVisits=0,viewVisits=0;
    AddMenu(mainMenu,@"",menus,targets,&menuBytes,&menuVisits,0);
    for(NSWindow* window in windows)
        if(window.visible && !window.miniaturized && !SPDFMacAIAppControlsHidesWindow(window))
            AddControl(window.contentView,controls,targets,&controlBytes,&viewVisits,0);
    return @{@"menus":menus,@"controls":controls,@"note":@"Use typed document tools first. Native commands may open "
        "dialogs; inspect again to continue or cancel. Secure and credential-labelled fields are omitted. Results are "
        "bounded."};
}
NSDictionary* SPDFMacAIAppControlsOperate(NSString* operation,NSDictionary* arguments,NSDictionary* targets) {
    if(![operation isEqual:@"activate"] && ![operation isEqual:@"set"])return @{@"error":@"Unsupported operation."};
    NSString* identifier=arguments[@"id"];
    if(![identifier isKindOfClass:NSString.class])return @{@"error":@"An inspected target ID is required."};
    id target=[targets objectForKey:identifier];
    if(!target)return @{@"error":@"Inspect app controls again; this target is no longer known."};
    if([target isKindOfClass:NSMenuItem.class] && [operation isEqual:@"activate"]) {
        NSMenuItem* item=target;[item.menu update];
        if(!LiveMenuItem(item))return @{@"error":@"This command is currently unavailable."};
        QueueNativeAction(^{if(LiveMenuItem(item))[NSApp sendAction:item.action to:item.target from:item];});
        return @{@"dispatched":@YES,@"queued":@YES,@"inspectAgain":@YES,@"undoable":@NO};
    }
    if(![target isKindOfClass:NSControl.class])return @{@"error":@"This target is not a control."};
    NSControl* control=target;
    if(!Available(control))return @{@"error":@"This control is unavailable."};
    BOOL sent=NO;
    if([operation isEqual:@"activate"] && [control isKindOfClass:NSButton.class] &&
        ![control isKindOfClass:NSPopUpButton.class]) {
        QueueNativeAction(^{if(Available(control))[(NSButton*)control performClick:nil];});sent=YES;
    }
    else if([operation isEqual:@"set"] && [arguments[@"value"] isKindOfClass:NSString.class]) {
        NSString* value=arguments[@"value"];
        if(value.length>8192)return @{@"error":@"Control values are limited to 8192 characters."};
        if([control isKindOfClass:NSTextField.class] && [(NSTextField*)control isEditable]) {
            QueueNativeAction(^{
                if(!Available(control) || ![(NSTextField*)control isEditable])return;
                control.stringValue=value;NotifyText((NSTextField*)control);
                if(control.action)[NSApp sendAction:control.action to:control.target from:control];
            });sent=YES;
        } else if([control isKindOfClass:NSPopUpButton.class]) {
            NSPopUpButton* popup=(id)control;NSInteger index=[popup indexOfItemWithTitle:value];
            NSMenuItem* item=index>=0 ? [popup itemAtIndex:index] : nil;
            if(!item || !item.enabled || item.hidden || item.separatorItem)
                return @{@"error":@"Choose an exact enabled option."};
            QueueNativeAction(^{
                if(!Available(popup) || item.menu!=popup.menu || !item.enabled || item.hidden)return;
                [popup selectItem:item];
                if(control.action)[NSApp sendAction:control.action to:control.target from:control];
            });sent=YES;
        }
    }
    NSMutableDictionary* result=[@{@"dispatched":@(sent),@"queued":@(sent),@"inspectAgain":@YES,
        @"undoable":@NO} mutableCopy];
    if(!sent)result[@"error"]=@"Unsupported operation for this control.";
    return result;
}
