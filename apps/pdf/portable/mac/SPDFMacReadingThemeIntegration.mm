#import "SPDFMacMarkdownDelegatePrivate.h"

#import "SPDFMacReadingTheme.h"
#import "SPDFMacWorkspaceChrome.h"

#import "SPDFMacSupport.h"
#import "markdown/SPDFMarkdown.h"

// The document-agnostic reading-theme toggle: one always-visible toolbar button
// right of the A-/A+ text-size pill, a View-menu item on Shift+Cmd+I, and the
// persisted "markdownTheme" preference they drive.
//
// One preference, two mechanisms. A Markdown document has no colors of its own,
// so the dark variant is applied by RESTYLING it (SPDFMarkdownThemeVariant).
// Every other format arrives as a rasterized page, so the same preference is
// applied by RECOLORING those pixels in the core (SPDF_RENDER_DARK_THEME, see
// portable/core/spdf_recolor.h). Both endpoints are the Markdown dark theme's
// own paper and body-text colors, so a recolored PDF page and a dark Markdown
// page are the same product rather than two similar-looking things.
//
// The key kept its original "markdownTheme" name deliberately: users who had
// already chosen the dark Markdown theme keep it, for every document, with no
// migration step and no window where the two halves could disagree.
//
// Print, Save as PDF and Copy Page never carry the flag. A PDF's colors are its
// content, and a file with our dark paper baked in would be wrong everywhere
// else it is ever opened.

@implementation ShenzhenMacDelegate (SPDFMacReadingThemeIntegration)

- (SPDFMarkdownThemeVariant)markdownThemeVariant {
    return _darkReadingTheme ? SPDFMarkdownThemeVariantDark : SPDFMarkdownThemeVariantLight;
}

// Called from the render wrappers, which run on background queues. The read is
// a plain byte and a toggle bumps _renderGeneration and rebuilds the page cache,
// so the worst a race can produce is one page rendered under the outgoing theme;
// its imageDarkTheme stamp then fails -renderedPageImage:matchesZoom: and it is
// re-rendered like any other stale page.
- (unsigned)readingThemeRenderFlags {
    if (!_darkReadingTheme) return 0;
    // Core rendering applies the same preservation setting to standalone
    // pictures and embedded figures; format handling stays in the core.
    return SPDF_RENDER_DARK_THEME | (_darkThemePreservesImages ? SPDF_RENDER_PRESERVE_IMAGES : 0u);
}

// What a dark render encodes: the theme itself and, because recoloring happens
// in the core, whether image colors were kept. Both are stamped on the bitmap so
// a cached page can be recognised as stale, which is how a keep-image-colors
// flip (and a tab switch between documents that disagree) re-renders.
- (void)stampReadingThemeOnRenderedPage:(SPDFRenderedPage*)page renderFlags:(unsigned)renderFlags {
    page.imageDarkTheme = (renderFlags & SPDF_RENDER_DARK_THEME) != 0;
    page.imagePreservesImageColors = (renderFlags & SPDF_RENDER_PRESERVE_IMAGES) != 0;
}

// Whether an already-rendered bitmap is usable under the live reading theme.
// preservesImageColors only means anything for a dark render, so a light page is
// judged on the theme alone.
- (BOOL)renderedPageMatchesReadingTheme:(SPDFRenderedPage*)page {
    if (page.imageDarkTheme != _darkReadingTheme) return NO;
    return !page.imageDarkTheme || page.imagePreservesImageColors == _darkThemePreservesImages;
}

// While LIGHT is active the button shows the moon (pressing it switches to
// dark); while DARK is active it shows the sun (pressing switches to light).
- (NSString*)readingThemeToggleTitle {
    return _darkReadingTheme ? @"Switch to Light Reading Theme" : @"Switch to Dark Reading Theme";
}

- (void)buildReadingThemeToolbarButton {
    // A SINGLE-segment pill rather than a push button: on a Markdown tab every
    // control actually visible beside it (page, zoom, text size, find) is an
    // NSSegmentedControl, so the shared button factory's textured bezel read as
    // a foreign control. spdf_single_toolbar_segment reuses the paired pill's
    // own configuration, so background, height and icon tint match exactly.
    _readingThemeButton = spdf_single_toolbar_segment(self, @selector(toggleReadingTheme:), nil);
    [_readingThemeButton.widthAnchor constraintEqualToConstant:32].active = YES;
    [self updateReadingThemeControls];
}

- (void)updateReadingThemeControls {
    if (!_readingThemeButton) return;
    // Always visible: the theme now applies to every document, not just
    // Markdown, so hiding it for PDF tabs would hide the feature.
    _readingThemeButton.hidden = NO;
    NSString* symbol = _darkReadingTheme ? @"sun.max" : @"moon.stars";
    NSImage* icon = [NSImage imageWithSystemSymbolName:symbol
                              accessibilityDescription:self.readingThemeToggleTitle];
    // Template rendering makes the glyph adopt the toolbar's control tint, the
    // way every other toolbar icon does.
    [icon setTemplate:YES];
    [_readingThemeButton setImage:icon forSegment:0];
    [_readingThemeButton setToolTip:self.readingThemeToggleTitle forSegment:0];
    _readingThemeButton.toolTip = self.readingThemeToggleTitle;
    _readingThemeButton.accessibilityLabel = self.readingThemeToggleTitle;
}

// The viewport GUTTER (the area around the sheets) for the rendered-document
// path: the dark theme names its own #121212, clearly below the paper, so a
// page edge always reads; light keeps every surface exactly as it was. The
// document view additionally swaps its drop shadow for a 1px page border in
// dark (see SPDFDocumentView.drawsPageShadow/pageBorderColor). Presentation
// mode owns the background while it is on and is never disturbed here.
// Two callers own the live document chrome and both matter. This one runs at
// launch and on a theme flip; -newDocumentView applies the variant too, because
// a tab switch REPLACES the document view (-replaceDocumentViewForTabSwitch)
// and a fresh one defaults to Light -- its gutter then fell back to the system
// canvas colour, a hair off the dark paper so a page had no visible edge, and
// its pageBorderColor was nil, dropping the border that stands in for the
// shadow in dark. The minimap is seeded where it is created, since it does not
// exist yet the first time this runs.
- (void)applyReadingThemeToDocumentViewport {
    if (!_pageScrollView || _presentationMode) return;
    if (_pageView.themeVariant != self.markdownThemeVariant) {
        _pageView.themeVariant = self.markdownThemeVariant;
        [_pageView setNeedsDisplay:YES];
    }
    NSColor* gutter = _pageView.viewportBackgroundColor ?: NSColor.windowBackgroundColor;
    _pageScrollView.backgroundColor = gutter;
    _pageScrollView.contentView.backgroundColor = gutter;
    // The minimap is the same document on the same paper: it needs the same
    // gutter and page border, or its sheets lose their edges in dark.
    _minimapView.themeVariant = self.markdownThemeVariant;
}

- (void)toggleReadingTheme:(id)sender {
    (void)sender;
    _darkReadingTheme = !_darkReadingTheme;
    [self savePersistentState];
    [self applyReadingThemeToDocumentViewport];
    [self applyReadingThemeToEveryTab];
    [self updateReadingThemeControls];
    if ([self isMarkdownActive]) [self updateControlsForActiveMarkdown];
}

// Keep-image-colors belongs to the document on screen, not to the app: a
// datasheet whose figures are color-coded wants its colors kept while the scan
// in the next tab does not. Only the selected tab changes, so no other tab's
// cache is dropped.
- (void)toggleDarkThemePreservesImages:(id)sender {
    (void)sender;
    SPDFDocumentTab* selected = [self selectedTab];
    if (!selected) return;
    _darkThemePreservesImages = !selected.preservesImageColors;
    selected.preservesImageColors = _darkThemePreservesImages;
    NSString* key=[self documentStateKeyForPath:selected.path];
    if(key.length) {
        if(!_documentStates) _documentStates=[NSMutableDictionary dictionary];
        NSMutableDictionary* state=[_documentStates[key] mutableCopy] ?: [NSMutableDictionary dictionary];
        state[@"preservesImageColors"]=@(_darkThemePreservesImages); state[@"path"]=selected.path;
        _documentStates[key]=state;
    }
    [self syncWorkspaceChrome];
    [self savePersistentState];
    // Only the recolored formats care, and only while the theme is on.
    if (!_darkReadingTheme) return;
    if ([self isMarkdownActive]) {
        // Draw-time only, so a flip costs a redraw rather than a rerender.
        self.activeMarkdownSession.preservesImageColors = _darkThemePreservesImages;
        [self.activeMarkdownSession.rootView setNeedsDisplay:YES];
        // Markdown repaints in place, so its minimap has to be refreshed too --
        // its thumbnails are rendered from the same plan and cached per page.
        [self updateMarkdownMinimap];
        return;
    }
    if (!_doc) return;
    // Re-render at the current viewport rather than jumping: the user is
    // reading, and a color flip should not move the page under them.
    selected.cachedRenderedPages = nil;
    NSValue* restoreOrigin = [NSValue valueWithPoint:_pageScrollView.contentView.bounds.origin];
    [self renderDocumentAndScrollToPage:_pageIndex alignTop:NO restoreOrigin:restoreOrigin];
}

- (void)toggleDefaultImageColors:(id)sender {
    (void)sender;
    _darkThemePreservesImagesDefault=!_darkThemePreservesImagesDefault;
    [self savePersistentState];
}

// The toggle has to reach EVERY tab, not just the active one, or a background
// tab would come back light. Markdown restyles in place; a rendered document
// drops its cached bitmaps and re-renders on the existing background queue,
// exactly the way a zoom or fit-mode change already does. Inactive tabs simply
// lose their cache, which activateCachedSelectedTab rebuilds on the way in.
- (void)applyReadingThemeToEveryTab {
    SPDFDocumentTab* selected = [self selectedTab];
    for (SPDFDocumentTab* tab in _tabs) {
        if (tab == selected) continue;
        [tab.cachedMarkdownSession applyThemeVariant:self.markdownThemeVariant];
        // That tab's own choice, not the selected document's.
        tab.cachedMarkdownSession.preservesImageColors = tab.preservesImageColors;
        tab.cachedRenderedPages = nil;
    }
    if ([self isMarkdownActive]) {
        [self.activeMarkdownSession applyThemeVariant:self.markdownThemeVariant];
        // Draw-time only, so a "keep image colors" flip costs a redraw rather
        // than the rerender a theme flip needs.
        self.activeMarkdownSession.preservesImageColors = _darkThemePreservesImages;
        [self.activeMarkdownSession.rootView setNeedsDisplay:YES];
        return;
    }
    if (!_doc) return;
    // Re-render at the current viewport rather than jumping: the user is
    // reading, and a theme flip should not move the page under them.
    NSValue* restoreOrigin = [NSValue valueWithPoint:_pageScrollView.contentView.bounds.origin];
    [self renderDocumentAndScrollToPage:_pageIndex alignTop:NO restoreOrigin:restoreOrigin];
}

// Overflow-menu mirror, called from rebuildToolbarOverflowMenuWithHiddenViews:
// (the theme button collapses into the overflow with the text-size pill).
- (void)addReadingThemeOverflowItemsToMenu:(NSMenu*)menu hiddenViews:(NSSet<NSView*>*)hiddenViews {
    if (![hiddenViews containsObject:_readingThemeButton]) return;
    [self addOverflowItemWithTitle:self.readingThemeToggleTitle
                            action:@selector(toggleReadingTheme:)
                              menu:menu
                             state:NSControlStateValueOff
                           enabled:YES];
}

@end

void SPDFMacInstallReadingThemeMenuItems(NSMenu* viewMenu, id target) {
    // Title flips between "Dark"/"Light" in -validateMenuItem:, matching the
    // toolbar button's moon/sun.
    NSMenuItem* theme = [viewMenu addItemWithTitle:@"Switch to Dark Reading Theme"
                                            action:@selector(toggleReadingTheme:)
                                     keyEquivalent:@"i"];
    theme.target = target;
    theme.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    NSMenuItem* images = [viewMenu addItemWithTitle:@"Invert Image Colors in Dark Theme"
                                             action:@selector(toggleDarkThemePreservesImages:)
                                      keyEquivalent:@"I"];
    images.target = target;
    images.keyEquivalentModifierMask = NSEventModifierFlagCommand;
}
