#pragma once
#import <Foundation/Foundation.h>
// Called only for the explicit --agent-command CLI mode, before app creation.
int SPDFMacRunAgentCommand(const char* json);
NSDictionary* SPDFMacValidateAgentCommand(NSData* data, NSError** error);
NSString* SPDFMacAgentRequestDirectory(void);
NSInteger SPDFMacAgentChooseMatch(NSArray<NSDictionary*>* matches, NSDictionary* command, NSError** error);
