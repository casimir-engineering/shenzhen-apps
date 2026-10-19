#pragma once
#import "SPDFMacSearchablePicker.h"
#import "SPDFMacAILanguage.h"
// Shared setup/settings control. Building or searching this local list never uses the network.
static inline SPDFMacSearchablePicker* SPDFMacAILanguagePicker(NSString* selected,void (^changed)(NSString*)) {
    SPDFMacSearchablePicker* picker=[[SPDFMacSearchablePicker alloc] initWithFrame:NSZeroRect];
    picker.identifier=@"aiLanguage"; picker.itemName=@"languages"; picker.accessibilityLabel=@"AI language";
    picker.choices=SPDFMacAILanguageChoices(); picker.selectedID=selected ?: @"en"; picker.selected=changed;
    [picker.widthAnchor constraintEqualToConstant:300].active=YES;
    [picker.heightAnchor constraintEqualToConstant:28].active=YES;
    return picker;
}
