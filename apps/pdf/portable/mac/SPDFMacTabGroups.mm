#import "SPDFMacTabGroups.h"
#import "SPDFMacModels.h"
#import "SPDFMacCollectionTabIdentity.h"
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

@implementation SPDFTabGroup
@synthesize colorName = _colorName;
- (NSString*)colorName { return self.collectionBackups ? @"Orange" : _colorName; }
+ (instancetype)generalGroup {
    SPDFTabGroup* group = [[self alloc] init];
    group.identifier = @"general";
    group.colorName = @"Gray";
    return group;
}
+ (instancetype)collectionBackupsGroup {
    SPDFTabGroup* group = [[self alloc] init];
    group.identifier = @"collection-backups";
    group.name = @"Collection Backups";
    group.colorName = @"Orange";
    return group;
}
+ (instancetype)groupWithColor:(NSString*)color {
    SPDFTabGroup* group = [[self alloc] init];
    group.identifier = NSUUID.UUID.UUIDString;
    group.colorName = [spdf_tab_group_colors() containsObject:color] ? color : @"Purple";
    return group;
}
- (BOOL)collectionBackups { return [self.identifier isEqualToString:@"collection-backups"]; }
- (BOOL)general { return [self.identifier isEqualToString:@"general"]; }
- (NSString*)displayName { return self.name.length ? self.name : self.general ? @"General" : self.colorName; }
- (NSDictionary*)dictionary {
    return @{@"id": self.identifier ?: @"", @"name": self.name ?: @"", @"color": self.colorName ?: @"Purple",
             @"collapsed": @(self.collapsed), @"hidden":@(self.hidden), @"explicitGeneral":@(self.explicitGeneral),
             @"lastUsedPath": self.lastUsedPath ?: @""};
}
+ (instancetype)fromDictionary:(id)value {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSString* identifier = value[@"id"];
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) return nil;
    SPDFTabGroup* group = [[self alloc] init];
    group.identifier = identifier;
    NSString* color = value[@"color"];
    group.colorName = [color isKindOfClass:NSString.class] && [spdf_tab_group_colors() containsObject:color]
        ? color : @"Purple";
    if (group.general) group.colorName = @"Gray";
    if ([value[@"name"] isKindOfClass:NSString.class]) group.name = value[@"name"];
    if ([value[@"lastUsedPath"] isKindOfClass:NSString.class]) group.lastUsedPath = value[@"lastUsedPath"];
    id collapsed = value[@"collapsed"];
    group.collapsed = [collapsed respondsToSelector:@selector(boolValue)] && [collapsed boolValue];
    for (NSString* key in @[@"hidden",@"explicitGeneral"]) {
        id flag=value[key];
        if ([flag respondsToSelector:@selector(boolValue)]) [group setValue:@([flag boolValue]) forKey:key];
    }
    return group;
}
- (id)copyWithZone:(NSZone*)zone { (void)zone; return [SPDFTabGroup fromDictionary:self.dictionary]; }
@end

NSArray<NSString*>* spdf_tab_group_colors(void) {
    // Function-local initialization is intentional: an ungrouped launch never
    // constructs the palette or generates an identifier.
    static NSArray* colors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ colors = @[@"Purple", @"Green", @"Blue", @"Teal", @"Rose", @"Coral",
                                      @"Amber", @"Indigo", @"Plum", @"Slate", @"Orange"]; });
    return colors;
}
static NSColor* RGB(unsigned rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0
                              blue:(rgb & 255) / 255.0 alpha:1];
}
// Group colours come from one of the palettes below, chosen in Settings › Appearance (Pastel but vibrant unless
// chosen). Each palette lists one base colour per stored colour name, in hue order: Coral red, Orange, Amber yellow,
// Green, Slate mint, Teal cyan, Blue, Indigo, Purple, Plum magenta, Rose pink. Sessions store the name, so a group
// keeps its place in the hues whichever palette is shown. Where a palette has fewer colours than names, a name repeats
// its nearest hue. tab-group-palettes.json, beside appearance.yaml, can replace any of them or add more by name (see
// apps/pdf/docs/tab-group-palettes.md); it is read with the choice and reread whenever it changes. Gray is General's, and the colour of tabs outside any group, in every palette. Per colour, worked out from the
// base when a palette is first used:
//   fill   the title tab ("chip") and the bar under an open group, the same in light and dark. Where white on the
//          base reaches 2.6:1, the base deepened in HSL lightness (0.01 steps) just until white reaches 4.5:1, with a
//          white label; otherwise the base itself with a near-black #111111 label.
//   edge   the chip's 1 pt outline, light then dark: the fill itself where it already stands 3:1 from the tab bar
//          (#eaeaea / #282828), else the nearest shade of the same hue that does (0.005 steps: the pale chips get a
//          darker outline in light mode).
// For Neon this gives the colours the owner approved: white on Coral #ee0000, Blue #146dff, Indigo #4d2bff, Purple
// #b026ff, Plum #d800af and Rose #e80063, near-black on the rest.
typedef struct { const char* name; unsigned base[11]; } SPDFGroupPalette;
static const char* const kHueOrder[11] = {"Coral", "Orange", "Amber", "Green", "Slate", "Teal", "Blue", "Indigo",
                                          "Purple", "Plum", "Rose"};
static const SPDFGroupPalette kBuiltIn[] = {
    // Indigo #4d2bff is not one of the ten neons: an electric indigo in their style, as installed before.
    {"Neon", {0xff3131, 0xff8c00, 0xfff200, 0x39ff14, 0x00ff9f, 0x00f0ff, 0x2d7dff, 0x4d2bff, 0xb026ff, 0xff2bd6, 0xff4f9a}},
    // No blue: Blue repeats Teal.
    {"Coolors vivid", {0xf42a45, 0xff6b00, 0xffc445, 0xf0f000, 0x00e65e, 0x00a695, 0x00a695, 0xc2add9, 0xcf6dcf, 0xc961a5,
                       0xd17b92}},
    // Eight colours: Slate repeats Teal, Plum repeats Purple, Rose repeats Coral.
    {"Coolors pastel rainbow", {0xffadad, 0xffd6a5, 0xfdffb6, 0xcaffbf, 0x9bf6ff, 0x9bf6ff, 0xa0c4ff, 0xbdb2ff, 0xffc6ff,
                                0xffc6ff, 0xffadad}},
    // No green: Green repeats Amber.
    {"Cyberpunk", {0xff003c, 0xf5a524, 0xfcee0a, 0xfcee0a, 0x0abdc6, 0x00f0ff, 0x05d9e8, 0x7b61ff, 0x9d4edd, 0xea00d9,
                   0xff2a6d}},
    // Nine colours: Slate repeats Green, Indigo repeats Purple.
    {"Pastel", {0xfec89a, 0xffe5a8, 0xb5e48c, 0x99d98c, 0x99d98c, 0xbde0fe, 0xa2d2ff, 0xcdb4db, 0xcdb4db, 0xffc8dd,
                0xffafcc}},
    // No red: Coral is a light coral; Plum is violet and Rose a deep pink, so no two groups share a colour.
    {"Pastel but vibrant", {0xffa8a8, 0xffa94d, 0xffd43b, 0x69db7c, 0x63e6be, 0x38d9a9, 0x4dabf7, 0x748ffc, 0xb197fc,
                            0xbe4bdb, 0xe64980}},
    // Plum repeats Purple. Slate is a greener mint than Apple's #00c7be and Teal is Apple's cyan, as Apple's mint and
    // teal were too close to tell apart side by side.
    {"Apple system", {0xff3b30, 0xff9500, 0xffcc00, 0x34c759, 0x2ed3b7, 0x32ade6, 0x007aff, 0x5856d6, 0xaf52de, 0xaf52de,
                      0xff2d55}},
    // The vivid chips of c24eca17, in the family of Codex's own icons.
    {"Codex", {0xe1292f, 0xf76b15, 0xffc205, 0x2fb26a, 0x59779a, 0x0ea5b0, 0x1a6ae6, 0x4f46e5, 0xa03ae0, 0xd01fb0,
               0xe11969}},
};
// The palettes in use: the built-in ones, each replaced by the file's palette of the same name, then the file's others.
struct SPDFPalette { std::string name; unsigned base[11]; };
static std::vector<SPDFPalette> gPalettes;
static const unsigned kGray = 0x6e6e6e;
static double Linear(unsigned channel) {
    double c = channel / 255.0;
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}
static double Luminance(unsigned rgb) {
    return 0.2126 * Linear((rgb >> 16) & 255) + 0.7152 * Linear((rgb >> 8) & 255) + 0.0722 * Linear(rgb & 255);
}
static double Contrast(unsigned a, unsigned b) {
    double la = Luminance(a), lb = Luminance(b);
    return (MAX(la, lb) + 0.05) / (MIN(la, lb) + 0.05);
}
// HSL as Python's colorsys works it, so the values match the ones worked out (and approved) with it.
static void ToHSL(unsigned rgb, double* h, double* l, double* s) {
    double r = ((rgb >> 16) & 255) / 255.0, g = ((rgb >> 8) & 255) / 255.0, b = (rgb & 255) / 255.0;
    double hi = MAX(r, MAX(g, b)), lo = MIN(r, MIN(g, b)), range = hi - lo;
    *l = (hi + lo) / 2;
    if (hi == lo) { *h = 0; *s = 0; return; }
    *s = *l <= 0.5 ? range / (hi + lo) : range / (2.0 - hi - lo);
    double rc = (hi - r) / range, gc = (hi - g) / range, bc = (hi - b) / range;
    double hue = r == hi ? bc - gc : g == hi ? 2.0 + rc - bc : 4.0 + gc - rc;
    *h = fmod(fmod(hue / 6.0, 1.0) + 1.0, 1.0);
}
static double HueChannel(double m1, double m2, double hue) {
    hue = fmod(fmod(hue, 1.0) + 1.0, 1.0);
    if (hue < 1.0 / 6) return m1 + (m2 - m1) * hue * 6;
    if (hue < 0.5) return m2;
    if (hue < 2.0 / 3) return m1 + (m2 - m1) * (2.0 / 3 - hue) * 6;
    return m1;
}
static unsigned FromHSL(double h, double l, double s) {
    double m2 = l <= 0.5 ? l * (1 + s) : l + s - l * s, m1 = 2 * l - m2;
    double channels[3] = {HueChannel(m1, m2, h + 1.0 / 3), HueChannel(m1, m2, h), HueChannel(m1, m2, h - 1.0 / 3)};
    if (s == 0) channels[0] = channels[1] = channels[2] = l;
    unsigned rgb = 0;
    for (double c : channels) rgb = rgb << 8 | (unsigned)lround(MAX(0.0, MIN(1.0, c)) * 255);
    return rgb;
}
// The same hue stepped lighter (step > 0) or darker until it stands target:1 from against.
static unsigned Shade(unsigned rgb, double target, unsigned against, double step) {
    double h, l, s;
    ToHSL(rgb, &h, &l, &s);
    for (int n = 0; Contrast(rgb, against) < target && n < 400; n++) rgb = FromHSL(h, l += step, s);
    return rgb;
}
typedef struct { unsigned fill; BOOL whiteLabel; unsigned edgeLight, edgeDark; } SPDFGroupColor;
static SPDFGroupColor Worked(unsigned base) {
    SPDFGroupColor entry;
    entry.whiteLabel = Contrast(base, 0xffffff) >= 2.6;
    entry.fill = entry.whiteLabel ? Shade(base, 4.5, 0xffffff, -0.01) : base;
    entry.edgeLight = Shade(entry.fill, 3, 0xeaeaea, -0.005);
    entry.edgeDark = Shade(entry.fill, 3, 0x282828, 0.005);
    return entry;
}
// The active palette's worked colours by name, Gray last. Nothing is read or worked out until a group is drawn.
static size_t gPalette = SIZE_MAX;
static SPDFGroupColor gColors[12];
static NSString* PaletteFile(void) {
    NSString* root = NSProcessInfo.processInfo.environment[@"SPDF_STATE_DIR"];
    if (!root.length) root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/ShenzhenPDF"];
    return [root stringByAppendingPathComponent:@"appearance.yaml"];
}
// To the reader's other windows (each its own process) sharing this state, and no other copy of the app.
static NSString* PaletteChanged(void) { return [@"ShenzhenPDFTabGroupPaletteChanged:" stringByAppendingString:PaletteFile()]; }
static NSString* OverrideFile(void) {
    return [PaletteFile().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"tab-group-palettes.json"];
}
static size_t PaletteIndex(NSString* name) {
    for (size_t i = 0; name && i < gPalettes.size(); i++)
        if (gPalettes[i].name == name.UTF8String) return i;
    return SIZE_MAX;
}
static BOOL ParseHex(id value, unsigned* rgb) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString* hex = [value hasPrefix:@"#"] ? [value substringFromIndex:1] : value;
    if (hex.length != 6 || [hex rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:
            @"0123456789abcdefABCDEF"].invertedSet].location != NSNotFound) return NO;
    *rgb = (unsigned)strtoul(hex.UTF8String, NULL, 16);
    return YES;
}
// The built-in palettes, then the file's: {"palettes": [{"name": "...", "colors": [11 × "#rrggbb", Coral to Rose]}]}.
// A file that is not exactly that is left out as a whole, with a line in the log.
static void ReadPalettes(void) {
    gPalettes.clear();
    for (const SPDFGroupPalette& builtIn : kBuiltIn) {
        gPalettes.push_back(SPDFPalette{builtIn.name, {}});
        memcpy(gPalettes.back().base, builtIn.base, sizeof builtIn.base);
    }
    NSData* data = [NSData dataWithContentsOfFile:OverrideFile()];
    id json = data.length && data.length <= (1 << 20) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray* list = [json isKindOfClass:NSDictionary.class] ? json[@"palettes"] : nil;
    if (!data) return;
    NSString* problem = [list isKindOfClass:NSArray.class] ? nil : @"it is not JSON of the form {\"palettes\": [...]}";
    std::vector<SPDFPalette> read;
    for (NSUInteger n = 0; !problem && n < list.count; n++) {
        NSDictionary* item = [list[n] isKindOfClass:NSDictionary.class] ? list[n] : nil;
        NSString* name = item[@"name"];
        NSArray* colors = item[@"colors"];
        BOOL ok = [name isKindOfClass:NSString.class] && name.length && name.length <= 60 &&
                  [name isEqualToString:[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]] &&
                  [name rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound &&
                  [colors isKindOfClass:NSArray.class] && colors.count == 11;
        SPDFPalette entry{ok ? name.UTF8String : "", {}};
        for (NSUInteger i = 0; ok && i < 11; i++) ok = ParseHex(colors[i], &entry.base[i]);
        if (!ok) problem = [NSString stringWithFormat:@"palette %lu needs a one-line \"name\" and \"colors\": 11 colours "
                                                      @"like \"#2ed3b7\"", (unsigned long)n + 1];
        read.push_back(entry);
    }
    if (problem) return (void)NSLog(@"ShenzhenPDF: tab group palettes in %@ are ignored: %@", OverrideFile(), problem);
    for (const SPDFPalette& entry : read) {
        size_t i = PaletteIndex(@(entry.name.c_str()));
        i == SIZE_MAX ? gPalettes.push_back(entry) : (void)(gPalettes[i] = entry);
    }
}
static NSString* gChosen; // the palette saved in appearance.yaml, which may be one the file no longer has
static void Recolor(void);
static void UsePalette(size_t index) { // never chosen, or gone: Pastel but vibrant, built in and so always listed
    gPalette = index < gPalettes.size() ? index : PaletteIndex(@"Pastel but vibrant");
    for (size_t i = 0; i < 11; i++) gColors[i] = Worked(gPalettes[gPalette].base[i]);
    gColors[11] = Worked(kGray);
}
// The file is watched from when the palettes are first read: its folder, for a file saved by replacing it, created
// or removed, and the file itself, for one written in place. Each change is read once things settle.
static dispatch_source_t gFolderWatch, gFileWatch;
static struct stat gSeen;
static void FileMaybeChanged(void);
static dispatch_source_t Watch(NSString* path, unsigned long mask) {
    int fd = open(path.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) return nil;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd, mask,
                                                      dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{ FileMaybeChanged(); });
    dispatch_source_set_cancel_handler(source, ^{ close(fd); });
    dispatch_resume(source);
    return source;
}
static BOOL Seen(void) {
    struct stat now = {};
    if (stat(OverrideFile().fileSystemRepresentation, &now) != 0) memset(&now, 0, sizeof now);
    BOOL same = now.st_ino == gSeen.st_ino && now.st_dev == gSeen.st_dev && now.st_size == gSeen.st_size &&
                now.st_mtimespec.tv_sec == gSeen.st_mtimespec.tv_sec && now.st_mtimespec.tv_nsec == gSeen.st_mtimespec.tv_nsec;
    BOOL replaced = now.st_ino != gSeen.st_ino || now.st_dev != gSeen.st_dev;
    gSeen = now;
    if (replaced && gFileWatch) dispatch_source_cancel(gFileWatch);
    if (replaced) gFileWatch = now.st_ino ? Watch(OverrideFile(), DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND |
                                                                 DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME) : nil;
    return same;
}
static void FileMaybeChanged(void) {
    static BOOL pending;
    if (pending) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        pending = NO;
        if (Seen()) return;
        ReadPalettes();
        UsePalette(PaletteIndex(gChosen));
        Recolor();
        [NSNotificationCenter.defaultCenter postNotificationName:SPDFTabGroupPalettesChangedNotification object:nil];
    });
}
static void LoadPalette(void) {
    if (gPalette != SIZE_MAX) return;
    NSString* text = [NSString stringWithContentsOfFile:PaletteFile() encoding:NSUTF8StringEncoding error:nil];
    for (NSString* line in [text componentsSeparatedByString:@"\n"])
        if ([line hasPrefix:@"tabGroupColors:"])
            gChosen = [[line substringFromIndex:15] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    Seen();
    gFolderWatch = Watch(PaletteFile().stringByDeletingLastPathComponent, DISPATCH_VNODE_WRITE);
    ReadPalettes();
    UsePalette(PaletteIndex(gChosen));
    // Another window of the reader switched palettes in Settings.
    [NSDistributedNotificationCenter.defaultCenter addObserverForName:PaletteChanged() object:nil queue:NSOperationQueue.mainQueue
                                                           usingBlock:^(NSNotification* note) {
        size_t chosen = PaletteIndex(note.object);
        if (chosen == SIZE_MAX || chosen == gPalette) return;
        gChosen = note.object;
        UsePalette(chosen);
        Recolor();
    }];
}
static const SPDFGroupColor& GroupColor(NSString* color) {
    LoadPalette();
    if (color)
        for (size_t i = 0; i < 11; i++)
            if (!strcmp(kHueOrder[i], color.UTF8String)) return gColors[i];
    return gColors[11];
}
static void Redraw(NSView* view) {
    view.needsDisplay = YES;
    if ([view isKindOfClass:NSImageView.class]) [((NSImageView*)view).image recache];
    for (NSView* child in view.subviews) Redraw(child);
}
// Every window of this process at once: the tab bars, the group picker and Groups draw from the table.
static void Recolor(void) {
    for (NSWindow* window in NSApp.windows) {
        NSView* frame = window.contentView.superview ?: window.contentView;
        if (frame) Redraw(frame);
    }
}
NSString* const SPDFTabGroupPalettesChangedNotification = @"SPDFTabGroupPalettesChanged";
NSArray<NSString*>* spdf_tab_group_palettes(void) {
    LoadPalette();
    NSMutableArray* names = [NSMutableArray array];
    for (const SPDFPalette& palette : gPalettes) [names addObject:@(palette.name.c_str())];
    return names;
}
NSString* spdf_tab_group_palette(void) {
    LoadPalette();
    return @(gPalettes[gPalette].name.c_str());
}
NSArray<NSNumber*>* spdf_tab_group_palette_fills(NSString* palette) {
    LoadPalette();
    size_t index = PaletteIndex(palette);
    NSMutableArray* fills = [NSMutableArray array];
    if (index != SIZE_MAX)
        for (size_t i = 0; i < 11; i++) [fills addObject:@(Worked(gPalettes[index].base[i]).fill)];
    return fills;
}
BOOL spdf_tab_group_set_palette(NSString* palette) {
    LoadPalette();
    size_t index = PaletteIndex(palette);
    if (index == SIZE_MAX) return NO;
    gChosen = palette;
    // appearance.yaml's other lines (the light or dark choice) stay as they are.
    NSString* old = [NSString stringWithContentsOfFile:PaletteFile() encoding:NSUTF8StringEncoding error:nil];
    NSMutableString* text = [NSMutableString stringWithFormat:@"tabGroupColors: %@\n", palette];
    for (NSString* line in [old componentsSeparatedByString:@"\n"])
        if (line.length && ![line hasPrefix:@"tabGroupColors:"]) [text appendFormat:@"%@\n", line];
    [NSFileManager.defaultManager createDirectoryAtPath:PaletteFile().stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL saved = [text writeToFile:PaletteFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (index != gPalette) {
        UsePalette(index);
        Recolor();
    }
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:PaletteChanged() object:palette userInfo:nil
                                                     deliverImmediately:YES];
    return saved;
}
static BOOL IsDark(NSAppearance* appearance) {
    return [[appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
        isEqualToString:NSAppearanceNameDarkAqua];
}
NSColor* spdf_tab_group_accent(NSString* color) { return RGB(GroupColor(color).fill); }
NSColor* spdf_tab_group_label(NSString* color) { return RGB(GroupColor(color).whiteLabel ? 0xffffff : 0x111111); }
NSColor* spdf_tab_group_edge(NSString* color) {
    const SPDFGroupColor& entry = GroupColor(color);
    return IsDark(NSAppearance.currentDrawingAppearance) ? RGB(entry.edgeDark) : RGB(entry.edgeLight);
}
unsigned spdf_tab_group_hex(NSString* color, int part, BOOL dark) {
    const SPDFGroupColor& entry = GroupColor(color);
    return part == 0 ? entry.fill : part == 1 ? (entry.whiteLabel ? 0xffffff : 0x111111)
                                              : (dark ? entry.edgeDark : entry.edgeLight);
}
NSImage* spdf_tab_group_swatch_image(NSString* color) {
    NSString* label = color.length ? color : @"Gray";
    return [NSImage imageWithSize:NSMakeSize(12, 12) flipped:NO drawingHandler:^BOOL(NSRect rect) {
      NSBezierPath* dot = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 1.5, 1.5)];
      [spdf_tab_group_accent(label) setFill];
      [dot fill];
      [spdf_tab_group_edge(label) setStroke];
      [dot stroke];
      return YES;
    }];
}
// The selected tab of a group: its colour over the tab bar, strong enough to read as selected and light enough
// (dark enough in Dark Aqua) that the tab's ordinary title colour keeps 5:1 or more on it. The light colours are
// thinner in Dark Aqua, where a stronger tint would brighten the tab under its white title.
NSColor* spdf_tab_group_selected_fill(NSString* color, BOOL dark) {
    const CGFloat darkAlpha = GroupColor(color).whiteLabel ? 0.42 : 0.36;
    return [spdf_tab_group_accent(color) colorWithAlphaComponent:dark ? darkAlpha : 0.30];
}
NSString* spdf_tab_group_unused_color(NSArray<SPDFDocumentTab*>* tabs) {
    NSMutableArray* available = [spdf_tab_group_colors() mutableCopy];
    for (SPDFDocumentTab* tab in tabs) if (tab.group.colorName) [available removeObject:tab.group.colorName];
    if (!available.count) available = [spdf_tab_group_colors() mutableCopy];
    return available[arc4random_uniform((uint32_t)available.count)];
}
NSArray<SPDFDocumentTab*>* spdf_tab_group_members(NSArray<SPDFDocumentTab*>* tabs, SPDFTabGroup* group) {
    NSMutableArray* members = [NSMutableArray array];
    if (!group) return members;
    for (SPDFDocumentTab* tab in tabs)
        if ([tab.group.identifier isEqualToString:group.identifier]) [members addObject:tab];
    return members;
}
NSInteger spdf_tab_group_prepare_gap_drop(NSArray<SPDFDocumentTab*>* tabs,
    SPDFDocumentTab* tab, NSInteger insertionIndex) {
    SPDFTabGroup* general = nil;
    NSInteger last = -1;
    for (NSUInteger i = 0; i < tabs.count; ++i) if (tabs[i].group.general) {
        if (!general) general = tabs[i].group;
        last = (NSInteger)i;
    }
    general = general ?: SPDFTabGroup.generalGroup;
    general.explicitGeneral = YES;
    general.hidden = NO;
    tab.group = general;
    return last >= 0 ? last + 1 : MAX(0, MIN(insertionIndex, (NSInteger)tabs.count));
}
void spdf_tab_groups_normalize(NSMutableArray<SPDFDocumentTab*>* tabs) {
    // Legacy Backups groups are retired without any filesystem work at launch.
    for (SPDFDocumentTab* tab in tabs) if (tab.group.collectionBackups) {
        SPDFTabGroup* original=nil;
        for (SPDFDocumentTab* other in tabs)
            if (!other.group.collectionBackups && tab.collectionHistoryDocumentID.length &&
                [other.collectionHistoryDocumentID isEqual:tab.collectionHistoryDocumentID]) { original=other.group; break; }
        tab.group=original;
    }
    BOOL hasCustom = NO;
    BOOL hasAny = NO;
    BOOL retainGeneral = NO;
    for (SPDFDocumentTab* tab in tabs) {
        if (tab.group) hasAny = YES;
        if (tab.group.general && (tab.group.hidden || tab.group.explicitGeneral)) retainGeneral = YES;
        if (tab.group && !tab.group.general) { hasCustom = YES; break; }
    }
    if (!hasAny) return;
    if (!hasCustom && !retainGeneral) { for (SPDFDocumentTab* tab in tabs) tab.group = nil; return; }
    // Strip refreshes also happen while reading. Already canonical, contiguous
    // groups need no rebuilding. Only multiple groups need an identifier set;
    // scanning every preceding tab at each boundary makes refresh quadratic.
    BOOL needsNormalization = NO;
    SPDFTabGroup* previous = nil;
    NSMutableSet<NSString*>* seen = nil;
    for (NSUInteger i = 0; i < tabs.count && !needsNormalization; ++i) {
        SPDFTabGroup* group = tabs[i].group;
        if (!group) { needsNormalization = YES; break; }
        if (group == previous) continue;
        if (previous) {
            if (!seen) seen = [NSMutableSet setWithObject:previous.identifier];
            if ([seen containsObject:group.identifier]) { needsNormalization = YES; break; }
            [seen addObject:group.identifier];
        }
        previous = group;
    }
    if (!needsNormalization) return;
    NSMutableDictionary<NSString*, SPDFTabGroup*>* canonical = [NSMutableDictionary dictionary];
    // Ungrouping a custom group can place nil-group tabs before an existing
    // General. Keep that General's explicit visibility instead of replacing it.
    for (SPDFDocumentTab* tab in tabs) if (tab.group.general) { canonical[@"general"]=tab.group; break; }
    NSMutableArray<NSString*>* order = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSMutableArray*>* buckets = [NSMutableDictionary dictionary];
    for (SPDFDocumentTab* tab in tabs) {
        NSString* identifier = tab.group.identifier ?: @"general";
        if (!buckets[identifier]) {
            canonical[identifier] = canonical[identifier] ?: tab.group ?: SPDFTabGroup.generalGroup;
            buckets[identifier] = [NSMutableArray array];
            [order addObject:identifier];
        }
        tab.group = canonical[identifier];
        [buckets[identifier] addObject:tab];
    }
    [tabs removeAllObjects];
    for (NSString* identifier in order) [tabs addObjectsFromArray:buckets[identifier]];
}
void spdf_tab_groups_activate(NSArray<SPDFDocumentTab*>* tabs, SPDFDocumentTab* selected) {
    if (!selected.group) return;
    for (SPDFDocumentTab* tab in tabs)
        tab.group.collapsed = tab.group != selected.group;
    selected.group.collapsed = NO;
    selected.group.lastUsedPath = selected.path;
}

BOOL spdf_tab_groups_reveal(NSArray<SPDFDocumentTab*>* tabs, SPDFDocumentTab* opened) {
    SPDFTabGroup* group = opened.group;
    if (!group) return NO;
    BOOL changed = group.hidden || group.collapsed;
    for (SPDFDocumentTab* tab in tabs) changed = changed || (tab.group != group && !tab.group.collapsed);
    group.hidden = NO;
    spdf_tab_groups_activate(tabs, opened);
    return changed;
}

void spdf_tab_group_collection_copy(NSMutableArray<SPDFDocumentTab*>* tabs, SPDFDocumentTab* tab) {
    // Compatibility entry point: copies now remain ordinary group members.
    if (tab && [tabs containsObject:tab]) spdf_tab_groups_normalize(tabs);
}
