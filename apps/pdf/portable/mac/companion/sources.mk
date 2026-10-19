# Collection uses PDFKit plus the shared Markdown renderer. Do not link the reader,
# MuPDF, updater, agent server, or Keychain backend into its independent process.
# Passwords still arrive on demand over the parent's private pipe.
MAC_COLLECTION_SRCS := $(MAC_MARKDOWN_SRCS) \
    $(sort $(wildcard mac/SPDFMacCollectionStore*.mm)) \
    $(sort $(wildcard mac/SPDFMacCollectionWindow*.mm)) \
    mac/SPDFMacCollectionManagerWindow.mm mac/SPDFMacCollectionStyle.mm \
    mac/SPDFMacCollectionUsage.mm mac/SPDFMacCollectionSavePanel.mm \
    mac/SPDFMacCollectionCompareEngine.mm mac/SPDFMacCollectionCompareLoad.mm \
    mac/SPDFMacCollectionCompareViews.mm mac/SPDFMacCollectionCompareWindow.mm \
    mac/SPDFMacCollectionCompareLatest.mm mac/SPDFMacCollectionLocate.mm \
    mac/SPDFMacCollectionPipe.mm mac/SPDFMacCollectionCompanionRuntime.mm \
    mac/SPDFMacPasswordCredentials.mm mac/SPDFMacMarkdownPrinting.mm \
    mac/SPDFMacFileExplorerPreference.mm mac/SPDFMacSearchFileCache.mm
MAC_COLLECTION_FRAMEWORKS := -framework Cocoa -framework QuartzCore -framework PDFKit \
    -framework UniformTypeIdentifiers -framework CoreServices -framework ImageIO
