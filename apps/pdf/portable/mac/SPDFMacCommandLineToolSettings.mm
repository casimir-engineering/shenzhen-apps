// The "Command-line tool" row of Settings > General (SPDFMacCommandLineTool.h). Kept apart from
// SPDFMacUnifiedSettings.mm so that file stays within its size cap. Reads commandLineTool (the row's sentence) from
// the state; the button reports the action installCommandLineTool.

#import "SPDFMacUnifiedSettings.h"

@interface SPDFMacUnifiedSettingsController (SPDFMacCommandLineToolPageBuilding)
- (NSDictionary*)state;
- (void)actionRow:(NSString*)title detail:(NSString*)detail label:(NSString*)label action:(NSString*)action;
@end

@implementation SPDFMacUnifiedSettingsController (SPDFMacCommandLineTool)
- (void)buildCommandLineToolRow {
    [self actionRow:@"Command-line tool" detail:self.state[@"commandLineTool"] ?: @"" label:@"Install Command-Line Tool"
             action:@"installCommandLineTool"];
}
@end
