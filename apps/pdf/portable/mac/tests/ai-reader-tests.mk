ifndef SPDF_AI_READER_TESTS_INCLUDED
SPDF_AI_READER_TESTS_INCLUDED := 1
# Production-linked AI acceptance binaries. No user app or network is launched.
include mac/tests/workspace-probe.mk
include mac/tests/chat-markdown-tests.mk
AI_READER_BASE_OBJS := $(filter-out \
	$(BUILD)/workspace-probe/mac/tests/SPDFMacWorkspaceProbe.o,$(MAC_WORKSPACE_PROBE_OBJS))
AI_CONTEXT_TEST := $(BUILD)/SPDFMacAIDocumentContextTests
AI_ANALYSIS_TEST := $(BUILD)/SPDFMacAIAnalysisServiceTests
AI_CHAT_VIEW_TEST := $(BUILD)/SPDFMacAIChatViewTests
# Header-based acceptance fixtures must invalidate their test translation units.
-include $(BUILD)/workspace-probe/mac/tests/SPDFMacAIDocumentContextTests.d
-include $(BUILD)/workspace-probe/mac/tests/SPDFMacAIAnalysisServiceTests.d
$(AI_CONTEXT_TEST): $(AI_READER_BASE_OBJS) $(BUILD)/workspace-probe/mac/tests/SPDFMacAIDocumentContextTests.o \
	$(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) mupdf-libs
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc $(AI_READER_BASE_OBJS) \
		$(BUILD)/workspace-probe/mac/tests/SPDFMacAIDocumentContextTests.o $(CORE_OBJS) $(YAML_OBJ) \
		$(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MUPDF_LIBS) -framework Cocoa -framework QuartzCore -framework \
		PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreServices -framework \
		Security -framework LocalAuthentication -lm -Wl,-dead_strip -o "$@"
$(AI_ANALYSIS_TEST): $(AI_READER_BASE_OBJS) $(BUILD)/workspace-probe/mac/tests/SPDFMacAIAnalysisServiceTests.o \
	$(CORE_OBJS) $(YAML_OBJ) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) mupdf-libs
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc $(AI_READER_BASE_OBJS) \
		$(BUILD)/workspace-probe/mac/tests/SPDFMacAIAnalysisServiceTests.o $(CORE_OBJS) $(YAML_OBJ) \
		$(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) $(MUPDF_LIBS) -framework Cocoa -framework QuartzCore -framework \
		PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreServices -framework \
		Security -framework LocalAuthentication -lm -Wl,-dead_strip -o "$@"
AI_CHAT_VIEW_SRCS := mac/SPDFMacAIChatViewParts.mm mac/SPDFMacAIChatActivityView.mm mac/SPDFMacAIChatActivity.mm \
	mac/SPDFMacAIChatBudget.mm \
	$(MAC_CHAT_MARKDOWN_SRCS)
$(AI_CHAT_VIEW_TEST): mac/tests/SPDFMacAIChatActivityViewChecks.h mac/tests/SPDFMacAIChatActivityStepChecks.h \
		mac/friends/SPDFMacFriendsEmojiTables.h $(AI_CHAT_VIEW_SRCS) mac/tests/SPDFMacAIChatBlankRowsChecks.h \
		mac/tests/SPDFMacAIAnswerCardViewChecks.h mac/tests/SPDFMacAIChatOrderChecks.h \
		mac/tests/SPDFMacAIChatReopenChecks.h mac/tests/SPDFMacAIChatDockChecks.h mac/tests/SPDFMacAIChatBannerChecks.h \
		mac/tests/SPDFMacAIChatEditChecks.h mac/tests/SPDFMacAIChatLinkChecks.h mac/SPDFMacAIChatViewInternal.h \
		mac/tests/SPDFMacAIChatRetryChecks.h \
		mac/tests/SPDFMacAIChatViewTests.mm mac/SPDFMacAIChatView.mm mac/SPDFMacAIChatViewMessages.mm \
		mac/SPDFMacAIAnswerCardView.mm \
		mac/SPDFMacAIAnswerCard.mm mac/SPDFMacAICitations.mm mac/SPDFMacAIChatSearch.mm \
		mac/SPDFMacSidebarNavigation.mm mac/SPDFMacSidebarModeControl.mm mac/SPDFMacPanelSearchField.mm \
		mac/SPDFMacAIChatDock.mm mac/SPDFMacAIChatHistoryView.mm mac/SPDFMacAIChatMarkdown.mm \
		mac/SPDFMacAIChatStore.mm mac/SPDFMacAIChatStoreRequestOnly.mm \
		mac/SPDFMacCollectionStyle.mm mac/SPDFMacGroupActionButton.mm \
		$(patsubst %.mm,$(BUILD)/workspace-probe/%.o,$(MAC_MARKDOWN_SRCS)) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) \
		$(CORE_RECOLOR_OBJ)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Imac mac/tests/SPDFMacAIChatViewTests.mm \
		mac/SPDFMacAIChatView.mm mac/SPDFMacAIChatViewMessages.mm $(AI_CHAT_VIEW_SRCS) mac/SPDFMacAIAnswerCardView.mm \
		mac/SPDFMacAIAnswerCard.mm mac/SPDFMacAICitations.mm mac/SPDFMacAIChatSearch.mm \
		mac/SPDFMacSidebarNavigation.mm mac/SPDFMacSidebarModeControl.mm mac/SPDFMacPanelSearchField.mm \
		mac/SPDFMacAIChatDock.mm mac/SPDFMacAIChatHistoryView.mm mac/SPDFMacAIChatMarkdown.mm \
		mac/SPDFMacAIChatStore.mm mac/SPDFMacAIChatStoreRequestOnly.mm \
		mac/SPDFMacCollectionStyle.mm mac/SPDFMacGroupActionButton.mm \
		$(patsubst %.mm,$(BUILD)/workspace-probe/%.o,$(MAC_MARKDOWN_SRCS)) $(MAC_MD4C_OBJ) $(MAC_GUMBO_OBJS) \
		$(CORE_RECOLOR_OBJ) -framework Cocoa -framework QuartzCore -framework ImageIO -Wl,-dead_strip -o "$@"
.PHONY: mac-ai-reader-acceptance
mac-ai-reader-acceptance: $(AI_CONTEXT_TEST) $(AI_ANALYSIS_TEST) $(AI_CHAT_VIEW_TEST)
	"$(AI_CONTEXT_TEST)"
	"$(AI_ANALYSIS_TEST)"
	"$(AI_CHAT_VIEW_TEST)"

endif

.PHONY: mac-ai-chat-organization-tests
mac-ai-chat-organization-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac \
		mac/tests/SPDFMacAIChatOrganizationTests.mm mac/SPDFMacAIChatStore.mm -framework Foundation -o \
		"$(BUILD)/SPDFMacAIChatOrganizationTests"
	"$(BUILD)/SPDFMacAIChatOrganizationTests"

.PHONY: mac-ai-chat-history-tests
mac-ai-chat-history-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac \
		mac/tests/SPDFMacAIChatHistoryViewTests.mm mac/SPDFMacAIChatHistoryView.mm \
		mac/SPDFMacPanelSearchField.mm mac/SPDFMacCollectionStyle.mm mac/SPDFMacGroupActionButton.mm \
		-framework Cocoa -framework QuartzCore -o "$(BUILD)/SPDFMacAIChatHistoryViewTests"
	"$(BUILD)/SPDFMacAIChatHistoryViewTests"
