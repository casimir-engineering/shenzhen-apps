# Shenzhen Friends avatars: the bundled animal set and the picture pipeline (owner: avatars).
# Included by friends/friends.mk; make runs with cwd portable/.
#
# Two object lists, because the views and the helper need different halves:
#   FRIENDS_AVATARS_SET_OBJS       SZFriendsPicture, SZFriendsAnimalSet, initials, placeholder colors and the
#                                  error words; Foundation only. The views link these to draw animals.
#   FRIENDS_AVATARS_PIPELINE_OBJS  the ImageIO pipeline and set_picture parsing; helper only, never an app, so a
#                                  hostile image is only ever decoded in the helper. Needs the set objects too.
# Both go to FRIENDS_SERVICE_OBJS; the views area adds FRIENDS_AVATARS_SET_OBJS to its own links.

FRIENDS_AVATARS_BUILD := $(FRIENDS_BUILD)/avatars
FRIENDS_AVATARS_HDRS := $(wildcard friends/avatars/*.h)

FRIENDS_AVATARS_SET_OBJS := $(addprefix $(FRIENDS_AVATARS_BUILD)/,\
	SZFriendsPicture.o SZFriendsAnimalSet.o SZFriendsPictureErrors.o)
FRIENDS_AVATARS_PIPELINE_OBJS := $(addprefix $(FRIENDS_AVATARS_BUILD)/,\
	SZFriendsPicturePipeline.o SZFriendsPictureIntent.o SZFriendsJPEG.o SZFriendsImageEnds.o)
FRIENDS_AVATARS_OBJS := $(FRIENDS_AVATARS_SET_OBJS) $(FRIENDS_AVATARS_PIPELINE_OBJS)
FRIENDS_AVATARS_LIBS := -framework Foundation -framework ImageIO -framework CoreGraphics

FRIENDS_SERVICE_OBJS += $(FRIENDS_AVATARS_OBJS)
FRIENDS_SERVICE_LIBS += -framework ImageIO -framework CoreGraphics

# Every object depends on every avatars header: there are few, and a stale object after a header edit costs more
# than the second it takes to rebuild them all.
$(FRIENDS_AVATARS_BUILD)/%.o: friends/avatars/%.m $(FRIENDS_AVATARS_HDRS) friends/avatars/avatars.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) -c "$<" -o "$@"

$(FRIENDS_AVATARS_BUILD)/%.o: friends/avatars/%.c $(FRIENDS_AVATARS_HDRS) friends/avatars/avatars.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(FRIENDS_C_FLAGS) -c "$<" -o "$@"

FRIENDS_AVATARS_TEST := $(FRIENDS_AVATARS_BUILD)/SZFriendsAvatarsTests
FRIENDS_AVATARS_TEST_SRCS := $(sort $(wildcard friends/avatars/tests/*.m))

# Compiled inside the phony target, like tests/tests.mk, so a rerun never trusts a binary make thought current.
# -lz only for the tests: they write 1-bit PNGs byte by byte (bombs, oversized headers), which ImageIO cannot write.
FRIENDS_TEST_TARGETS += friends-avatars-check
.PHONY: friends-avatars-check friends-avatars-pdfs friends-avatars-preview
friends-avatars-check: $(FRIENDS_AVATARS_OBJS)
	@mkdir -p "$(FRIENDS_AVATARS_BUILD)"
	@rm -f "$(FRIENDS_AVATARS_TEST)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) -Ifriends/avatars/tests $(FRIENDS_AVATARS_TEST_SRCS) \
		$(FRIENDS_AVATARS_OBJS) $(FRIENDS_AVATARS_LIBS) -lz -o "$(FRIENDS_AVATARS_TEST)"
	"$(FRIENDS_AVATARS_TEST)" friends/avatars/animals/manifest.json friends/fixtures

# Maintenance only, never part of a build or a suite: regenerating needs rsvg-convert (tools/regenerate-pdfs.sh).
friends-avatars-pdfs:
	bash friends/avatars/tools/regenerate-pdfs.sh

FRIENDS_AVATARS_SHEET := $(FRIENDS_AVATARS_BUILD)/SZFriendsContactSheet
friends-avatars-preview: $(FRIENDS_AVATARS_SET_OBJS)
	@mkdir -p "$(FRIENDS_AVATARS_BUILD)"
	@rm -f "$(FRIENDS_AVATARS_SHEET)"
	clang $(PORTABLE_TEST_OPTFLAGS) $(FRIENDS_OBJC_FLAGS) friends/avatars/tools/SZFriendsContactSheet.m \
		$(FRIENDS_AVATARS_SET_OBJS) $(FRIENDS_AVATARS_LIBS) -framework CoreText -o "$(FRIENDS_AVATARS_SHEET)"
	"$(FRIENDS_AVATARS_SHEET)" friends/avatars/animals/manifest.json friends/avatars/preview/contact-sheet.png
