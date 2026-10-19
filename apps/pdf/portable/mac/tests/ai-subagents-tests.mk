ifndef SPDF_AI_SUBAGENTS_TESTS_INCLUDED
SPDF_AI_SUBAGENTS_TESTS_INCLUDED := 1
# run_subagents (mac/SPDFMacAISubagents.h): parallel read-only tasks in one assistant request. Included from
# portable/Makefile, which names mac-ai-subagents-tests itself so the release sweep finds it (the pattern
# mac-ai-reader-tests follows); uses its MAC_AI_SESSION_SRCS, the chat session and tool seam the tasks run on.
#
# The app globs mac/*.mm, so these sources need no listing there. The registration category needs the whole
# coordinator to link, so it is compiled -fsyntax-only here, as the Friends host adapter does with its categories.
# The binary is removed first so a stale one sharing the source's mtime second is never mistaken for a fresh pass.
.PHONY: mac-ai-subagents-tests mac-ai-subagents-acceptance
MAC_AI_SUBAGENTS_SRCS := mac/SPDFMacAISubagents.mm mac/SPDFMacAISubagentsRun.mm mac/SPDFMacAISubagentsResults.mm
mac-ai-subagents-acceptance: | $(BUILD)
	rm -f "$(BUILD)/SPDFMacAISubagentsTests"
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -fsyntax-only -Imac -Icore \
		-I$(MUPDF_DIR)/include mac/SPDFMacAISubagentsIntegration.mm
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacAISubagentsTests.mm \
		$(MAC_AI_SUBAGENTS_SRCS) $(MAC_AI_SESSION_SRCS) mac/SPDFMacAISettings.mm -framework Cocoa -framework ImageIO \
		-o "$(BUILD)/SPDFMacAISubagentsTests"
	"$(BUILD)/SPDFMacAISubagentsTests"
mac-ai-subagents-tests: mac-ai-subagents-acceptance
endif
