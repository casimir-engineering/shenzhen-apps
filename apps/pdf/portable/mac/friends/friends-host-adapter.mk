# ShenzhenPDF's Shenzhen Friends host adapter (portable/mac/friends/) and its headless suite.
#
# Until the lead includes this file from portable/Makefile, run it as
#   make -C portable -f Makefile -f mac/friends/friends-host-adapter.mk mac-friends-host-adapter-tests
# Make runs with cwd portable/, so every path here is relative to portable/.
#
# WHY a directory and makefile of its own: the app and the workspace probe compile every portable/mac/*.mm, and these
# sources need the Friends views and client library, which the app links only once the lead wires them in
# (portable/friends/README.md § host adapter). Tests link the adapter's pure units with fakes of the views' value
# classes; the reader-facing categories, which need the whole coordinator, are compiled -fsyntax-only against the
# real reader and Friends headers so a hook that no longer matches them fails here rather than in the app build.

HOST_ADAPTER_DIR := mac/friends
HOST_ADAPTER_BUILD := $(BUILD)/friends-host-adapter
# Reader headers by name (-Imac), Friends headers as "mac/SZFriendsHost.h" (-Ifriends), the adapter's own by name.
HOST_ADAPTER_INCLUDES := -Imac -Ifriends -I$(HOST_ADAPTER_DIR) -I$(HOST_ADAPTER_DIR)/tests
HOST_ADAPTER_FLAGS = $(MAC_TARGET_FLAGS) $(PORTABLE_TEST_OPTFLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror \
	$(HOST_ADAPTER_INCLUDES)
HOST_ADAPTER_FAKES := $(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsViewFakes.mm
HOST_ADAPTER_REVISION_SRCS := $(addprefix $(HOST_ADAPTER_DIR)/,SPDFMacFriendsRevision.mm SPDFMacFriendsTabPasteboard.mm)
HOST_ADAPTER_SCOPE_SRCS := $(addprefix $(HOST_ADAPTER_DIR)/,SPDFMacFriendsChatScope.mm SPDFMacFriendsChatScopeGate.mm \
	SPDFMacFriendsChatTools.mm SPDFMacFriendsChatHistory.mm SPDFMacFriendsComposerText.mm \
	SPDFMacFriendsComposerScope.mm SPDFMacFriendsToolProvider.mm SPDFMacFriendsChatGrant.mm \
	SPDFMacFriendsGrantBar.mm) mac/SPDFMacAITransport.mm

# Every test compiles inside its phony target after rm -f, so a stale binary sharing the source's mtime second is
# never mistaken for a fresh pass (portable/friends/README.md § Building and testing).
define HOST_ADAPTER_RUN
	@mkdir -p "$(HOST_ADAPTER_BUILD)"
	rm -f "$(HOST_ADAPTER_BUILD)/$(1)"
	clang++ $(HOST_ADAPTER_FLAGS) $(2) -o "$(HOST_ADAPTER_BUILD)/$(1)"
	"$(HOST_ADAPTER_BUILD)/$(1)"
endef

.PHONY: mac-friends-host-adapter-tests friends-host-adapter-check \
	mac-friends-launch-tests mac-friends-title-bar-tests mac-friends-pasteboard-tests mac-friends-attach-tests \
	mac-friends-scope-tests mac-friends-settings-tests mac-friends-integration-tests mac-friends-host-adapter-syntax \
	mac-friends-app-controls-tests mac-friends-promise-tests mac-friends-release-verify-tests \
	mac-friends-tool-provider-tests mac-friends-send-tests mac-friends-slash-tests mac-friends-send-card-tests \
	mac-friends-markdown-tests mac-friends-link-tests mac-friends-received-tests

mac-friends-launch-tests:
	$(call HOST_ADAPTER_RUN,SPDFMacFriendsLaunchTests,$(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsLaunchTests.mm \
		$(addprefix $(HOST_ADAPTER_DIR)/,SPDFMacFriendsLaunch.mm SPDFMacFriendsSettings.mm SPDFMacFriendsSigning.mm) \
		-framework Foundation -framework Security)

mac-friends-title-bar-tests:
	$(call HOST_ADAPTER_RUN,SPDFMacFriendsTitleBarTests,$(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsTitleBarTests.mm \
		$(HOST_ADAPTER_DIR)/SPDFMacFriendsTitleBar.mm mac/SPDFMacWindowChrome.mm -framework Cocoa)

mac-friends-pasteboard-tests:
	$(call HOST_ADAPTER_RUN,SPDFMacFriendsPasteboardTests,$(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsPasteboardTests.mm \
		$(HOST_ADAPTER_REVISION_SRCS) $(HOST_ADAPTER_FAKES) -framework Cocoa)

# Links the views' drop code (as mac-friends-promise-tests does), so a tab drag is judged by the real verdict.
mac-friends-attach-tests: $$(HOST_ADAPTER_PROMISE_OBJS)
	$(call HOST_ADAPTER_RUN,SPDFMacFriendsAttachTests,$(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsAttachTests.mm \
		$(HOST_ADAPTER_REVISION_SRCS) $(addprefix $(HOST_ADAPTER_DIR)/,SPDFMacFriendsAttachItems.mm SPDFMacFriendsHost.mm \
		SPDFMacFriendsShareMenu.mm \
		SPDFMacFriendsLaunch.mm SPDFMacFriendsSettings.mm) $(HOST_ADAPTER_PROMISE_OBJS) $(HOST_ADAPTER_FAKES) \
		-framework Cocoa -framework UniformTypeIdentifiers)

# Links ShenzhenPDF's real chat session (and what it needs) so scope enforcement is tested where it happens.
HOST_ADAPTER_SESSION_SRCS := mac/SPDFMacAIChatSession.mm mac/SPDFMacAIAnswerCard.mm mac/SPDFMacAIChatVision.mm \
	mac/SPDFMacAIChatStore.mm mac/SPDFMacAIChatStoreRequestOnly.mm \
	mac/SPDFMacAICitations.mm mac/SPDFMacAIToolRegistry.mm mac/SPDFMacAIRequestContext.mm \
	mac/SPDFMacAIChatActivity.mm mac/SPDFMacAIChatSessionSummaries.mm mac/SPDFMacAIChatBudget.mm \
	mac/SPDFMacAIChatSessionCalls.mm mac/SPDFMacAIToolArguments.mm mac/SPDFMacAIChatSessionRecovery.mm mac/SPDFMacAIChatProgress.mm
mac-friends-scope-tests:
	$(call HOST_ADAPTER_RUN,SPDFMacFriendsScopeTests,$(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsScopeTests.mm \
		$(HOST_ADAPTER_SCOPE_SRCS) $(HOST_ADAPTER_SESSION_SRCS) mac/SPDFMacCollectionStyle.mm -framework Cocoa -framework ImageIO)

# The same enforcement through the AI tool registry, the way the reader now runs it (SPDFMacFriendsToolProvider.h),
# with the time grant for all chats (SPDFMacFriendsGrantChecks.h) and the audit of every other path to chat content
# (SPDFMacFriendsExposureChecks.h): app_controls and the palette's rows are linked to show the assistant can't reach
# the grant's bar, the picker or a Friends excerpt in Cmd+K, and the source audit reads mac/ from portable/.
mac-friends-tool-provider-tests:
	$(call HOST_ADAPTER_RUN,SPDFMacFriendsToolProviderTests,$(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsToolProviderTests.mm \
		$(HOST_ADAPTER_SCOPE_SRCS) $(HOST_ADAPTER_SESSION_SRCS) mac/SPDFMacAIAppControls.mm \
		mac/SPDFMacPaletteAppearance.mm mac/SPDFMacCollectionStyle.mm $(HOST_ADAPTER_DIR)/SPDFMacFriendsPalette.mm \
		$(HOST_ADAPTER_FAKES) -framework Cocoa -framework ImageIO)

# friends_send_message through the registry and the real session, with a scripted helper (SPDFMacFriendsSendProvider.h).
HOST_ADAPTER_SEND_SRCS := $(addprefix $(HOST_ADAPTER_DIR)/,SPDFMacFriendsSendRules.mm SPDFMacFriendsSendText.mm \
	SPDFMacFriendsSendProvider.mm SPDFMacFriendsSendCards.mm SPDFMacFriendsRevision.mm)
mac-friends-send-tests:
	$(call HOST_ADAPTER_RUN,SPDFMacFriendsSendTests,$(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsSendTests.mm \
		$(HOST_ADAPTER_SEND_SRCS) $(HOST_ADAPTER_SCOPE_SRCS) $(HOST_ADAPTER_SESSION_SRCS) mac/SPDFMacCollectionStyle.mm -framework Cocoa -framework ImageIO)

# The waiting card as the AI chat draws it (SPDFMacAIChatActivityView.h, with the chat's Markdown renderer and the
# engine objects the workspace probe builds), so "every character Friends delivers is on the card" is checked on the
# drawn row, not only on the entry. $(sort) because the session and the chat view both list the activity model.
HOST_ADAPTER_CARD_VIEW_SRCS = $(sort $(HOST_ADAPTER_SEND_SRCS) $(HOST_ADAPTER_SCOPE_SRCS) $(HOST_ADAPTER_SESSION_SRCS) \
	$(filter-out $(HOST_ADAPTER_CHAT_VIEW_CATEGORIES),$(AI_CHAT_VIEW_SRCS)) mac/SPDFMacAIChatMarkdown.mm \
	mac/SPDFMacCollectionStyle.mm mac/SPDFMacGroupActionButton.mm)
# Categories of the assistant's chat view, which the card tests don't link: they need the view itself.
HOST_ADAPTER_CHAT_VIEW_CATEGORIES := mac/SPDFMacAIChatAttachments.mm mac/SPDFMacAIChatViewFollow.mm
mac-friends-send-card-tests: $$(MAC_CHAT_MARKDOWN_ENGINE)
	$(call HOST_ADAPTER_RUN,SPDFMacFriendsSendCardTests,$(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsSendCardTests.mm \
		$(HOST_ADAPTER_CARD_VIEW_SRCS) $(MAC_CHAT_MARKDOWN_ENGINE) -framework Cocoa -framework ImageIO \
		-framework QuartzCore)

# Friend messages as Markdown (SPDFMacFriendsMarkdown.h): the render pass allowance and kept tables, with the chat
# renderer and the engine. mac-chat-markdown-acceptance runs the same suite with the renderer's own; this runs it with
# the Friends suites, so a change to the host's budget fails friends-tests. The header path is the copy-key check.
mac-friends-markdown-tests: $$(MAC_CHAT_MARKDOWN_ENGINE)
	@mkdir -p "$(HOST_ADAPTER_BUILD)"
	rm -f "$(HOST_ADAPTER_BUILD)/SPDFMacFriendsMarkdownTests"
	clang++ $(HOST_ADAPTER_FLAGS) $(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsMarkdownTests.mm $(MAC_FRIENDS_MARKDOWN_SRCS) \
		$(MAC_CHAT_MARKDOWN_SRCS) $(MAC_CHAT_MARKDOWN_ENGINE) -framework Cocoa -framework ImageIO \
		-o "$(HOST_ADAPTER_BUILD)/SPDFMacFriendsMarkdownTests"
	"$(HOST_ADAPTER_BUILD)/SPDFMacFriendsMarkdownTests" friends/mac/SZFriendsHost.h

# `/` in a friend's composer through the real session (SPDFMacFriendsAssistant.h, SPDFMacFriendsSlashCommand.h).
mac-friends-slash-tests:
	$(call HOST_ADAPTER_RUN,SPDFMacFriendsSlashTests,$(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsSlashTests.mm \
		$(addprefix $(HOST_ADAPTER_DIR)/,SPDFMacFriendsAssistant.mm SPDFMacFriendsSlashCommand.mm) \
		$(HOST_ADAPTER_SEND_SRCS) $(HOST_ADAPTER_SCOPE_SRCS) $(HOST_ADAPTER_SESSION_SRCS) mac/SPDFMacCollectionStyle.mm $(HOST_ADAPTER_FAKES) \
		-framework Cocoa -framework ImageIO)

# app_controls (the reader's own file, needing no coordinator) over fixture windows holding Friends interface.
mac-friends-app-controls-tests:
	$(call HOST_ADAPTER_RUN,SPDFMacFriendsAppControlsTests,$(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsAppControlsTests.mm \
		mac/SPDFMacAIAppControls.mm $(addprefix $(HOST_ADAPTER_DIR)/,SPDFMacFriendsSettingsPane.mm \
		SPDFMacFriendsTitleBar.mm) mac/SPDFMacCollectionStyle.mm -framework Cocoa)

# File promises in the views' drop code (portable/friends/mac/SZFriendsDrops.m and SZFriendsPromiseCopies.m), linked
# on their own with the value class fakes: what a promise source writes is checked, and copied where the source
# cannot write, before anything is sent.
HOST_ADAPTER_PROMISE_OBJS = $(addprefix $(FRIENDS_VIEWS_BUILD)/,SZFriendsDrops.o SZFriendsPromiseCopies.o)
mac-friends-promise-tests: $$(HOST_ADAPTER_PROMISE_OBJS)
	$(call HOST_ADAPTER_RUN,SPDFMacFriendsPromiseTests,$(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsPromiseTests.mm \
		$(HOST_ADAPTER_PROMISE_OBJS) $(HOST_ADAPTER_FAKES) -framework Cocoa -framework UniformTypeIdentifiers)

# The release verifier's helper checks (release/verify-mac-artifact.sh) against bundles made in a temporary folder.
mac-friends-release-verify-tests:
	$(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsReleaseVerifyTests.sh

# Links (SPDFMacFriendsLinkURL.h, SPDFMacFriendsShareMenu.h): the scheme's strict check, the scheme in Info.plist, the
# Copy Download Link menus, and the drop panel's "Copy link instead" through the host with a fake bridge.
mac-friends-link-tests:
	@mkdir -p "$(HOST_ADAPTER_BUILD)"
	rm -f "$(HOST_ADAPTER_BUILD)/SPDFMacFriendsLinkTests"
	clang++ $(HOST_ADAPTER_FLAGS) $(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsLinkTests.mm $(HOST_ADAPTER_REVISION_SRCS) \
		$(addprefix $(HOST_ADAPTER_DIR)/,SPDFMacFriendsLinkURL.mm SPDFMacFriendsShareMenu.mm \
		SPDFMacFriendsAttachItems.mm SPDFMacFriendsHost.mm SPDFMacFriendsLaunch.mm SPDFMacFriendsSettings.mm) \
		$(HOST_ADAPTER_FAKES) -framework Cocoa -framework UniformTypeIdentifiers \
		-o "$(HOST_ADAPTER_BUILD)/SPDFMacFriendsLinkTests"
	"$(HOST_ADAPTER_BUILD)/SPDFMacFriendsLinkTests" mac/Info.plist

mac-friends-settings-tests:
	$(call HOST_ADAPTER_RUN,SPDFMacFriendsSettingsTests,$(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsSettingsTests.mm \
		$(addprefix $(HOST_ADAPTER_DIR)/,SPDFMacFriendsSettings.mm SPDFMacFriendsSettingsPane.mm SPDFMacFriendsPalette.mm \
		SPDFMacFriendsChatScope.mm SPDFMacFriendsSettingsPage.mm) mac/SPDFMacCollectionStyle.mm \
		mac/SPDFMacUnifiedSettings.mm mac/SPDFMacSearchablePicker.mm mac/SPDFMacGroupActionButton.mm \
		$(HOST_ADAPTER_FAKES) -framework Cocoa)

# The reader-facing categories need the whole coordinator to link, so they are compiled -fsyntax-only against the
# real reader and Friends headers with the app's include paths. The hook probe compiles the requested hook lines
# with the reader's include path alone, proving reader files can import the hook header without -Ifriends.
HOST_ADAPTER_READER_SRCS := $(addprefix $(HOST_ADAPTER_DIR)/,SPDFMacFriendsIntegration.mm \
	SPDFMacFriendsSettingsIntegration.mm SPDFMacFriendsAssistantIntegration.mm SPDFMacFriendsPaletteIntegration.mm \
	SPDFMacFriendsCollectionSource.mm SPDFMacFriendsLaunchDefault.mm SPDFMacFriendsToolProviderIntegration.mm \
	SPDFMacFriendsSendIntegration.mm SPDFMacFriendsLinkIntegration.mm SPDFMacFriendsMenuIntegration.mm)
HOST_ADAPTER_SYNTAX_FLAGS = $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -fsyntax-only \
	-Imac -Icore -I$(MUPDF_DIR)/include
mac-friends-host-adapter-syntax:
	for source in $(HOST_ADAPTER_READER_SRCS); do \
		clang++ $(HOST_ADAPTER_SYNTAX_FLAGS) -Ifriends -I$(HOST_ADAPTER_DIR) "$$source" || exit 1; done
	clang++ $(HOST_ADAPTER_SYNTAX_FLAGS) $(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsHookProbe.mm

# With the real views, client library and the protocol area's in-process fake helper (portable/friends/mac/views.mk
# names what a views client links), on loopback in a temporary SZFRIENDS_STATE_DIR. The send provider and the chat
# session it reports to are linked too, so a card is followed through the real link; $(sort) drops the sources both
# lists name.
mac-friends-integration-tests: $$(FRIENDS_VIEWS_LIB_OBJS) $$(FRIENDS_AVATARS_SET_OBJS) $$(FRIENDS_FAKE_HELPER_LIB) \
		$$(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ)
	$(call HOST_ADAPTER_RUN,SPDFMacFriendsIntegrationTests,$(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsIntegrationTests.mm \
		$(sort $(HOST_ADAPTER_REVISION_SRCS) $(addprefix $(HOST_ADAPTER_DIR)/,SPDFMacFriendsAttachItems.mm \
		SPDFMacFriendsHost.mm SPDFMacFriendsShareMenu.mm SPDFMacFriendsLaunch.mm SPDFMacFriendsSettings.mm \
		SPDFMacFriendsPalette.mm \
		SPDFMacFriendsTitleBar.mm SPDFMacFriendsAppearance.mm SPDFMacFriendsLinkSender.mm) \
		$(HOST_ADAPTER_SEND_SRCS) $(HOST_ADAPTER_SCOPE_SRCS) $(HOST_ADAPTER_SESSION_SRCS)) \
		mac/SPDFMacCollectionStyle.mm $(FRIENDS_VIEWS_LIB_OBJS) $(FRIENDS_AVATARS_SET_OBJS) \
		$(FRIENDS_FAKE_HELPER_LINK) $(FRIENDS_VIEWS_LIBS) -framework Cocoa -framework ImageIO)

# Received files into Collection (SPDFMacFriendsReceivedFiles.h) against real helpers: two-helper harness helpers in
# a temporary home each (SZFRIENDS_STATE_DIR, SZFRIENDS_DOWNLOADS_DIR, HOME), the reader's host and the views' link
# to one of them, and Collections at temporary roots. No window; nothing reaches the reader's real state.
HOST_ADAPTER_RECEIVED_BUILD := $(HOST_ADAPTER_BUILD)/received
mac-friends-received-tests: $$(FRIENDS_HELPER_OBJS) $(FRIENDS_SODIUM_LIB) $(FRIENDS_CJSON_OBJ) $$(FRIENDS_SERVICE_OBJS) \
		$$(FRIENDS_CLIENT_OBJS) $$(FRIENDS_VIEWS_LIB_OBJS) $$(FRIENDS_AVATARS_SET_OBJS) $(MAC_COLLECTION_PARSER_LIBS)
	@mkdir -p "$(HOST_ADAPTER_RECEIVED_BUILD)"
	rm -f "$(HOST_ADAPTER_RECEIVED_BUILD)/szfriends-e2e-helper" "$(HOST_ADAPTER_RECEIVED_BUILD)/SZFriendsE2EHarness.o" \
		"$(HOST_ADAPTER_RECEIVED_BUILD)/SPDFMacFriendsReceivedTests"
	clang $(FRIENDS_E2E_FLAGS) $(FRIENDS_E2E_HELPER_SRCS) $(FRIENDS_HELPER_OBJS) $(FRIENDS_SERVICE_OBJS) \
		$(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_SODIUM_LIB) $(FRIENDS_SERVICE_LIBS) \
		$(FRIENDS_HELPER_FRAMEWORKS) -Wl,-dead_strip -o "$(HOST_ADAPTER_RECEIVED_BUILD)/szfriends-e2e-helper"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) -I$(FRIENDS_E2E_DIR) -c $(FRIENDS_E2E_DIR)/SZFriendsE2EHarness.m \
		-o "$(HOST_ADAPTER_RECEIVED_BUILD)/SZFriendsE2EHarness.o"
	clang++ $(HOST_ADAPTER_FLAGS) -Wno-incomplete-implementation -Wno-objc-protocol-method-implementation \
		-I$(FRIENDS_E2E_DIR) $(HOST_ADAPTER_DIR)/tests/SPDFMacFriendsReceivedTests.mm \
		$(HOST_ADAPTER_DIR)/SPDFMacFriendsReceivedFiles.mm $(FRIENDS_UI_E2E_HOST_SRCS) \
		mac/SPDFMacCollectionStore*.mm mac/SPDFMacSearchFileCache.mm $(MAC_COLLECTION_PARSER_SRCS) \
		$(MAC_COLLECTION_PARSER_LIBS) "$(HOST_ADAPTER_RECEIVED_BUILD)/SZFriendsE2EHarness.o" $(FRIENDS_VIEWS_LIB_OBJS) \
		$(FRIENDS_AVATARS_SET_OBJS) $(FRIENDS_CLIENT_OBJS) $(FRIENDS_CJSON_OBJ) $(FRIENDS_VIEWS_LIBS) -framework Cocoa \
		-framework PDFKit -framework ImageIO -framework QuartzCore -lpthread \
		-o "$(HOST_ADAPTER_RECEIVED_BUILD)/SPDFMacFriendsReceivedTests"
	"$(HOST_ADAPTER_RECEIVED_BUILD)/SPDFMacFriendsReceivedTests" "$(HOST_ADAPTER_RECEIVED_BUILD)/szfriends-e2e-helper" \
		"$(CURDIR)/friends/avatars/animals/manifest.json"

mac-friends-host-adapter-tests: mac-friends-launch-tests mac-friends-title-bar-tests mac-friends-pasteboard-tests \
	mac-friends-attach-tests mac-friends-scope-tests mac-friends-settings-tests mac-friends-integration-tests \
	mac-friends-host-adapter-syntax mac-friends-app-controls-tests mac-friends-promise-tests \
	mac-friends-release-verify-tests mac-friends-tool-provider-tests mac-friends-send-tests mac-friends-slash-tests \
	mac-friends-send-card-tests mac-friends-markdown-tests mac-friends-link-tests mac-friends-received-tests
	@echo "mac-friends-host-adapter-tests passed"

# The name the build wave's instructions use for an area's suite.
friends-host-adapter-check: mac-friends-host-adapter-tests
