ifndef SPDF_CHAT_MARKDOWN_TESTS_INCLUDED
SPDF_CHAT_MARKDOWN_TESTS_INCLUDED := 1
# Markdown in chats (mac/SPDFMacChatMarkdown.h): the renderer AI chat and Friends messages share, and its suites.
# Included from mac/tests/ai-reader-tests.mk, whose chat view suite links the same sources. Make runs in portable/.
include mac/tests/workspace-probe.mk
MAC_CHAT_MARKDOWN_SRCS := mac/SPDFMacChatMarkdown.mm mac/SPDFMacCollectionStyle.mm mac/SPDFMacChatMarkdownBlocks.mm mac/SPDFMacChatMarkdownBudget.mm \
	mac/SPDFMacChatMarkdownCells.mm mac/SPDFMacChatMarkdownDiagrams.mm mac/SPDFMacChatMarkdownImages.mm \
	mac/SPDFMacChatMarkdownLinks.mm mac/SPDFMacChatMarkdownStyle.mm mac/SPDFMacChatMarkdownView.mm \
	mac/SPDFMacMarkdownSessionImageLoader.mm mac/SPDFMacMarkdownCache.mm
# The engine objects the workspace probe builds (mac/tests/workspace-probe.mk), and what they link against.
MAC_CHAT_MARKDOWN_ENGINE = $(patsubst %.mm,$(BUILD)/workspace-probe/%.o,$(MAC_MARKDOWN_SRCS)) $(MAC_MD4C_OBJ) \
	$(MAC_GUMBO_OBJS) $(CORE_RECOLOR_OBJ)
MAC_CHAT_MARKDOWN_FLAGS = $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror
# The Friends host method links the adapter's host and what it needs, with the views' value classes faked
# (mac/friends/friends-host-adapter.mk does the same for its own suites).
MAC_FRIENDS_MARKDOWN_SRCS = mac/friends/SPDFMacFriendsMarkdown.mm mac/friends/SPDFMacFriendsHost.mm \
	mac/friends/SPDFMacFriendsAttachItems.mm mac/friends/SPDFMacFriendsLaunch.mm mac/friends/SPDFMacFriendsSettings.mm \
	mac/friends/SPDFMacFriendsRevision.mm mac/friends/SPDFMacFriendsTabPasteboard.mm \
	mac/friends/SPDFMacFriendsShareMenu.mm mac/friends/tests/SPDFMacFriendsViewFakes.mm

# Every binary is removed and rebuilt inside the phony target, so a stale one sharing its source's mtime second is
# never mistaken for a fresh pass. Renders go to $SPDF_CHAT_MARKDOWN_RENDERS when it is set.
.PHONY: mac-chat-markdown-acceptance
mac-chat-markdown-acceptance: $(MAC_CHAT_MARKDOWN_ENGINE) | $(BUILD)
	rm -f "$(BUILD)/SPDFMacChatMarkdownTests" "$(BUILD)/SPDFMacFriendsMarkdownTests"
	clang++ $(MAC_CHAT_MARKDOWN_FLAGS) -Imac mac/tests/SPDFMacChatMarkdownTests.mm $(MAC_CHAT_MARKDOWN_SRCS) \
		mac/SPDFMacAIChatMarkdown.mm mac/SPDFMacAICitations.mm $(MAC_CHAT_MARKDOWN_ENGINE) -framework Cocoa \
		-framework ImageIO -o "$(BUILD)/SPDFMacChatMarkdownTests"
	"$(BUILD)/SPDFMacChatMarkdownTests"
	clang++ $(MAC_CHAT_MARKDOWN_FLAGS) -Imac -Ifriends -Imac/friends -Imac/friends/tests \
		mac/friends/tests/SPDFMacFriendsMarkdownTests.mm $(MAC_FRIENDS_MARKDOWN_SRCS) $(MAC_CHAT_MARKDOWN_SRCS) \
		$(MAC_CHAT_MARKDOWN_ENGINE) -framework Cocoa -framework ImageIO -o "$(BUILD)/SPDFMacFriendsMarkdownTests"
	"$(BUILD)/SPDFMacFriendsMarkdownTests" friends/mac/SZFriendsHost.h
endif
