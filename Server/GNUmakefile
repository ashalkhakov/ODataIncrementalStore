# The HTTP adapter (ODataHTTPServer), ois-serve, and the loopback check.
# Build the library at the repository root first.
#
# GNUstep, with gnustep-make:
#   . /path/to/GNUstep.sh
#   make -C .. && make          # libODataHTTPServer, ois-serve, ois-serve-check
#   make check                  # the loopback check over the Catalog model
#
# macOS (Apple Foundation and Core Data), without gnustep-make:
#   make && make check          # plain clang; the library's sources are
#                               # compiled into the tools

GCDWebServer_DIR = ../ThirdParty/GCDWebServer
include $(GCDWebServer_DIR)/GCDWebServer.make

ifneq ($(GNUSTEP_MAKEFILES),)

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

FLAGS = -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions -Wall -Wno-unused-parameter

LIBRARY_NAME = libODataHTTPServer
libODataHTTPServer_OBJC_FILES = ODataHTTPServer.m $(GCDWebServer_OBJC_FILES)
libODataHTTPServer_HEADER_FILES = ODataHTTPServer.h
libODataHTTPServer_HEADER_FILES_INSTALL_DIR = ODataHTTPServer
libODataHTTPServer_INCLUDE_DIRS = -I. -I../Source/include $(GCDWebServer_INCLUDE_DIRS)
libODataHTTPServer_OBJCFLAGS = $(FLAGS)
libODataHTTPServer_LIB_DIRS = -L../obj
libODataHTTPServer_LIBRARIES_DEPEND_UPON = -lODataIncrementalStore -lCoreData $(GCDWebServer_LIBS)

TOOL_NAME = ois-serve ois-serve-check
ois-serve_OBJC_FILES = ois-serve.m
ois-serve-check_OBJC_FILES = Tests/ois-serve-check.m
ois-serve_INCLUDE_DIRS = -I. -I../Source/include
ois-serve-check_INCLUDE_DIRS = -I. -I../Source/include
ois-serve_OBJCFLAGS = $(FLAGS)
ois-serve-check_OBJCFLAGS = $(FLAGS)
ois-serve_LIB_DIRS = -L./obj -L../obj
ois-serve-check_LIB_DIRS = -L./obj -L../obj
ois-serve_TOOL_LIBS = -lODataHTTPServer -lODataIncrementalStore -lCoreData $(GCDWebServer_LIBS)
ois-serve-check_TOOL_LIBS = -lODataHTTPServer -lODataIncrementalStore -lCoreData $(GCDWebServer_LIBS)

include $(GNUSTEP_MAKEFILES)/library.make
include $(GNUSTEP_MAKEFILES)/tool.make

# FreeCoreData loads compiled models only.
obj/Catalog.momd: ../Examples/Catalog/Catalog.xcdatamodeld
	rm -rf $@ && momc $< $@

check:: all obj/Catalog.momd
	LD_LIBRARY_PATH="$(CURDIR)/obj:$(CURDIR)/../obj$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}" ./obj/ois-serve-check obj/Catalog.momd

else

CC = clang
BUILD_DIR = build
FLAGS = -fobjc-arc -fblocks -fobjc-exceptions -Wall -Wno-unused-parameter
INCLUDES = -I. -I../Source/include $(GCDWebServer_INCLUDE_DIRS)
LIBS = -framework Foundation -framework CoreData -framework Security -framework SystemConfiguration -framework CoreServices -lz
LIBRARY_SOURCES = $(wildcard ../Source/*.m)
SOURCES = ODataHTTPServer.m $(LIBRARY_SOURCES) $(GCDWebServer_OBJC_FILES)
HEADERS = $(wildcard *.h ../Source/include/*.h ../Source/*.h)

all: $(BUILD_DIR)/ois-serve $(BUILD_DIR)/ois-serve-check

$(BUILD_DIR)/ois-serve: ois-serve.m $(SOURCES) $(HEADERS)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(FLAGS) $(INCLUDES) ois-serve.m $(SOURCES) $(LIBS) -o $@

$(BUILD_DIR)/ois-serve-check: Tests/ois-serve-check.m $(SOURCES) $(HEADERS)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(FLAGS) $(INCLUDES) Tests/ois-serve-check.m $(SOURCES) $(LIBS) -o $@

$(BUILD_DIR)/Catalog.momd: ../Examples/Catalog/Catalog.xcdatamodeld
	@mkdir -p $(BUILD_DIR)
	rm -rf $@ && xcrun momc $< $(abspath $@)

check: all $(BUILD_DIR)/Catalog.momd
	./$(BUILD_DIR)/ois-serve-check $(BUILD_DIR)/Catalog.momd

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all check clean

endif
