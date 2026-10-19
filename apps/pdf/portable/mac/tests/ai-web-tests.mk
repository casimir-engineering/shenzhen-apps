ifndef SPDF_AI_WEB_TESTS_INCLUDED
SPDF_AI_WEB_TESTS_INCLUDED := 1
# Web search and pages for the assistant (mac/SPDFMacAIWebToolProvider.h). Headless: a scripted resolver, connector,
# OpenRouter transport and model; the real connector and resolver run on loopback only. Run it with
#   make -C portable mac-ai-web-tests
# portable/Makefile includes this file and names mac-ai-web-tests itself so the release sweep finds it, the pattern
# mac-ai-reader-tests follows. The chat file check writes into its own temporary folder and removes it. The reader
# category needs the whole coordinator to link, so it is compiled -fsyntax-only against the real headers.
MAC_AI_WEB_SRCS := $(sort $(filter-out mac/SPDFMacAIWebIntegration.mm,$(wildcard mac/SPDFMacAIWeb*.mm)))
MAC_AI_WEB_TEST := $(BUILD)/SPDFMacAIWebTests
.PHONY: mac-ai-web-tests mac-ai-web-acceptance mac-ai-web-syntax
mac-ai-web-syntax:
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -fsyntax-only -Imac -Icore \
		-I$(MUPDF_DIR)/include mac/SPDFMacAIWebIntegration.mm
mac-ai-web-acceptance: mac-ai-web-syntax | $(BUILD)
	rm -f "$(MAC_AI_WEB_TEST)"
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacAIWebTests.mm \
		$(MAC_AI_WEB_SRCS) $(MAC_AI_SESSION_SRCS) mac/SPDFMacAISettings.mm -framework Cocoa -framework ImageIO \
		-framework Network -framework Security -o "$(MAC_AI_WEB_TEST)"
	"$(MAC_AI_WEB_TEST)"
mac-ai-web-tests: mac-ai-web-acceptance
endif
