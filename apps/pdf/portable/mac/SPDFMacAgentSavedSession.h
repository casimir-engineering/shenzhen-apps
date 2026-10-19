#pragma once
#import <Foundation/Foundation.h>
NSDictionary* SPDFMacAgentSavedSession(NSDictionary* command, NSString* directory, NSError** error);
BOOL SPDFMacAgentReaderIsRunning(void);
