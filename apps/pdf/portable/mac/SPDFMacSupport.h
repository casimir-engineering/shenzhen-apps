#import <Cocoa/Cocoa.h>
#import "SPDFMacDocumentFormats.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSArray<UTType*>* spdf_document_content_types(void);
NSString* spdf_display_label_without_extension(NSString* label);
NSString* spdf_display_name_for_path(NSString* path);
NSString* spdf_display_path_without_extension(NSString* path);
NSArray<NSString*>* spdf_disambiguated_display_names_for_paths(NSArray<NSString*>* paths);
NSArray<NSDictionary<NSString*, NSString*>*>* spdf_translation_languages(void);
NSArray<NSDictionary<NSString*, NSString*>*>* spdf_ocr_languages(void);
NSArray<NSString*>* spdf_ocr_language_components(NSString* language);
BOOL spdf_ocr_language_uses_extra_traineddata(NSString* language);
NSImage* spdf_translate_toolbar_image(void);
NSImage* spdf_ocr_toolbar_image(void);
NSImage* spdf_markdown_font_size_toolbar_image(BOOL larger);
NSSegmentedControl* spdf_paired_toolbar_segments(id target, SEL action, NSImage* leadingImage, NSImage* trailingImage);

// Sizes the fit-mode popup to the title it is CURRENTLY showing, rather than to
// the widest title in its menu. An NSPopUpButton's intrinsic width is the widest
// item plus a constant 48.6pt of chrome (measured across every title this menu
// uses), so a fixed width leaves the short ones -- "100%", "1600%" -- floating in
// the middle of a box sized for "Fit Height".
void spdf_fit_popup_select_and_size(NSPopUpButton* popup, NSMenuItem* itemToSelect);
// The one-segment pill, configured identically to the paired one (rounded
// style, momentary tracking) so a lone toolbar toggle matches the pills beside
// it instead of reading as a differently-bezeled push button.
NSSegmentedControl* spdf_single_toolbar_segment(id target, SEL action, NSImage* image);
BOOL spdf_is_allowed_external_url(NSURL* url);

BOOL spdf_zoom_profile_enabled(void);
double spdf_zoom_profile_now_ms(void);
void spdf_zoom_profile_log(NSString* format, ...) NS_FORMAT_FUNCTION(1, 2);

// Launch-time profiling (SPDF_LAUNCH_PROFILE=1): timestamps are reported
// relative to process entry (image-load constructor). Zero overhead when the
// environment variable is unset.
BOOL spdf_launch_profile_enabled(void);
void spdf_launch_profile_log(NSString* format, ...) NS_FORMAT_FUNCTION(1, 2);
// CFAbsoluteTime (ms) of the kernel process spawn (sysctl p_starttime);
// predates dyld/code-signature work, so cold pre-main segments are visible.
double spdf_process_spawn_time_ms(void);

// The per-user state directory holding settings.yaml / session.yaml / etc.
// Normally ~/Library/Application Support/ShenzhenPDF; SPDF_STATE_DIR points it
// somewhere else so a measurement or test launch reads and rewrites a scratch
// copy instead of clobbering the real session. The directory is created on
// first call. Every state reader/writer in the app must go through this.
NSString* spdf_mac_support_directory(void);

// SPDF_NO_ACTIVATE=1: skip the launch-time -activateIgnoringOtherApps: so a
// profiling launch (open -g -j) genuinely stays in the background instead of
// stealing focus from whatever the user is doing. Affects launch only; every
// user-initiated window raise still activates normally.
BOOL spdf_launch_activation_suppressed(void);
