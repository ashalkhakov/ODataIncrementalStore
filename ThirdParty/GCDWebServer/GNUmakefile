# Builds and runs the GCDWebServer smoke test (Tests/gws-smoke.m).
#
# GNUstep, with gnustep-make:
#   . /path/to/GNUstep.sh
#   make            # builds obj/gws-smoke via tool.make and GCDWebServer.make
#   make check
#
# macOS (Apple Foundation), or GNUstep without gnustep-make:
#   make            # plain clang; gnustep-config supplies the flags on GNUstep
#   make check
#   make cfcompare  # macOS only: compare the CFHTTPMessage replacement with CFNetwork

ifneq ($(GNUSTEP_MAKEFILES),)

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

GCDWebServer_DIR = .
include GCDWebServer.make

TOOL_NAME = gws-smoke
gws-smoke_OBJC_FILES = Tests/gws-smoke.m $(GCDWebServer_OBJC_FILES)
gws-smoke_INCLUDE_DIRS = $(GCDWebServer_INCLUDE_DIRS)
gws-smoke_OBJCFLAGS = $(GCDWebServer_OBJCFLAGS)
gws-smoke_TOOL_LIBS = $(GCDWebServer_LIBS)

include $(GNUSTEP_MAKEFILES)/tool.make

check:: all
	./obj/gws-smoke

else

GCDWebServer_DIR = .
include GCDWebServer.make

CC = clang
BUILD_DIR = build
UNAME := $(shell uname -s)

ifeq ($(UNAME),Darwin)
SMOKE_OBJCFLAGS = -fobjc-arc -fblocks -fobjc-exceptions -Wall
SMOKE_LIBS = -framework Foundation -framework SystemConfiguration -framework CoreServices -lz
else
SMOKE_OBJCFLAGS = $(shell gnustep-config --objc-flags) $(GCDWebServer_OBJCFLAGS)
SMOKE_LIBS = $(shell gnustep-config --base-libs) $(GCDWebServer_LIBS)
endif

all: $(BUILD_DIR)/gws-smoke

$(BUILD_DIR)/gws-smoke: Tests/gws-smoke.m $(GCDWebServer_OBJC_FILES) $(wildcard Core/*.h Requests/*.h Responses/*.h)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(SMOKE_OBJCFLAGS) $(GCDWebServer_INCLUDE_DIRS) Tests/gws-smoke.m $(GCDWebServer_OBJC_FILES) $(SMOKE_LIBS) -o $@

check: all
	./$(BUILD_DIR)/gws-smoke

# macOS only: compare the CFHTTPMessage replacement with CFNetwork
cfcompare: Tests/gws-cfcompare.m $(GCDWebServer_OBJC_FILES)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(SMOKE_OBJCFLAGS) $(GCDWebServer_INCLUDE_DIRS) Tests/gws-cfcompare.m $(GCDWebServer_OBJC_FILES) $(SMOKE_LIBS) -framework CFNetwork -o $(BUILD_DIR)/gws-cfcompare
	./$(BUILD_DIR)/gws-cfcompare

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all check cfcompare clean

endif
