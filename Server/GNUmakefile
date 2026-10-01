# The server library (libODataHTTPServer: ODataServer.h), ois-serve, an
# example application of its own (catalog-server), and the loopback check.
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

# The server library: the listener, the pipeline and router around it, and
# the application that makes them from its settings.
SERVER_SOURCES = ODataServerMessage.m ODataServerPipeline.m ODataServerRouter.m ODataServerHandlers.m ODataHTTPServer.m ODataServerApplication.m
SERVER_HEADERS = ODataServer.h ODataServerMessage.h ODataServerPipeline.h ODataServerRouter.h ODataServerHandlers.h ODataHTTPServer.h ODataServerApplication.h

ifneq ($(GNUSTEP_MAKEFILES),)

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

FLAGS = -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions -Wall -Wno-unused-parameter

LIBRARY_NAME = libODataHTTPServer
libODataHTTPServer_OBJC_FILES = $(SERVER_SOURCES) $(GCDWebServer_OBJC_FILES)
libODataHTTPServer_HEADER_FILES = $(SERVER_HEADERS)
libODataHTTPServer_HEADER_FILES_INSTALL_DIR = ODataHTTPServer
libODataHTTPServer_INCLUDE_DIRS = -I. -I../Source/ODataKit/include -I../Source/ODataIncrementalStore/include -I../Source/ODataService/include -I../Source/ODataKit/include/ODataKit -I../Source/ODataIncrementalStore/include/ODataIncrementalStore -I../Source/ODataService/include/ODataService $(GCDWebServer_INCLUDE_DIRS)
libODataHTTPServer_OBJCFLAGS = $(FLAGS)
libODataHTTPServer_LIB_DIRS = -L../obj
libODataHTTPServer_LIBRARIES_DEPEND_UPON = -lODataService -lODataKit -lCoreData $(GCDWebServer_LIBS)

TOOL_NAME = ois-serve ois-serve-check catalog-server
ois-serve_OBJC_FILES = ois-serve.m
ois-serve-check_OBJC_FILES = Tests/ois-serve-check.m
catalog-server_OBJC_FILES = Examples/CatalogServer.m
ois-serve_INCLUDE_DIRS = -I. -I../Source/ODataKit/include -I../Source/ODataIncrementalStore/include -I../Source/ODataService/include -I../Source/ODataKit/include/ODataKit -I../Source/ODataIncrementalStore/include/ODataIncrementalStore -I../Source/ODataService/include/ODataService
catalog-server_INCLUDE_DIRS = -I. -I../Source/ODataKit/include -I../Source/ODataIncrementalStore/include -I../Source/ODataService/include -I../Source/ODataKit/include/ODataKit -I../Source/ODataIncrementalStore/include/ODataIncrementalStore -I../Source/ODataService/include/ODataService
ois-serve-check_INCLUDE_DIRS = -I. -I../Source/ODataKit/include -I../Source/ODataIncrementalStore/include -I../Source/ODataService/include -I../Source/ODataKit/include/ODataKit -I../Source/ODataIncrementalStore/include/ODataIncrementalStore -I../Source/ODataService/include/ODataService
ois-serve_OBJCFLAGS = $(FLAGS)
catalog-server_OBJCFLAGS = $(FLAGS)
ois-serve-check_OBJCFLAGS = $(FLAGS)
ois-serve_LIB_DIRS = -L./obj -L../obj
catalog-server_LIB_DIRS = -L./obj -L../obj
ois-serve-check_LIB_DIRS = -L./obj -L../obj
ois-serve_TOOL_LIBS = -lODataHTTPServer -lODataService -lODataKit -lCoreData $(GCDWebServer_LIBS)
catalog-server_TOOL_LIBS = -lODataHTTPServer -lODataService -lODataKit -lCoreData $(GCDWebServer_LIBS)
ois-serve-check_TOOL_LIBS = -lODataHTTPServer -lODataService -lODataKit -lCoreData $(GCDWebServer_LIBS)

include $(GNUSTEP_MAKEFILES)/library.make
include $(GNUSTEP_MAKEFILES)/tool.make

ODATAKIT_SCRIPTS = ../Scripts
# What an application builds against the installed libraries with: a
# fragment every GNUmakefile includes, and pkg-config files
# (Scripts/install-build-files.sh, docs/building.md).
ODATAKIT_VERSION ?= $(shell git -C "$(CURDIR)" describe --tags --always 2>/dev/null || echo 0.0.0)
ODATAKIT_BUILD_FILES = HEADERS_DIR="$(patsubst $(MAYBE_DESTDIR)%,%,$(GNUSTEP_HEADERS))" \
	LIBRARIES_DIR="$(patsubst $(MAYBE_DESTDIR)%,%,$(GNUSTEP_LIBRARIES))" MAKEFILES_DIR="$(GNUSTEP_MAKEFILES)" \
	DESTDIR="$(DESTDIR)" VERSION="$(ODATAKIT_VERSION)" \
	GNUSTEP_OBJC_FLAGS="$(shell gnustep-config --objc-flags 2>/dev/null)" GNUSTEP_BASE_LIBS="$(shell gnustep-config --base-libs 2>/dev/null)" \
	sh $(ODATAKIT_SCRIPTS)/install-build-files.sh

after-install::
	$(ODATAKIT_BUILD_FILES) install server

after-uninstall::
	$(ODATAKIT_BUILD_FILES) uninstall server

# FreeCoreData loads compiled models only.
obj/Catalog.momd: ../Examples/Catalog/Catalog.xcdatamodeld
	rm -rf $@ && momc $< $@

check:: all obj/Catalog.momd
	LD_LIBRARY_PATH="$(CURDIR)/obj:$(CURDIR)/../obj$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}" ./obj/ois-serve-check obj/Catalog.momd

else

CC = clang
BUILD_DIR = build
FLAGS = -fobjc-arc -fblocks -fobjc-exceptions -Wall -Wno-unused-parameter
INCLUDES = -I. -I../Source/ODataKit/include -I../Source/ODataIncrementalStore/include -I../Source/ODataService/include -I../Source/ODataKit/include/ODataKit -I../Source/ODataIncrementalStore/include/ODataIncrementalStore -I../Source/ODataService/include/ODataService $(GCDWebServer_INCLUDE_DIRS)
LIBS = -framework Foundation -framework CoreData -framework Security -framework SystemConfiguration -framework CoreServices -lz
LIBRARY_SOURCES = $(wildcard ../Source/*/*.m)
SOURCES = $(SERVER_SOURCES) $(LIBRARY_SOURCES) $(GCDWebServer_OBJC_FILES)
HEADERS = $(wildcard *.h ../Source/*/include/*/*.h ../Source/*/*.h)

all: $(BUILD_DIR)/ois-serve $(BUILD_DIR)/ois-serve-check $(BUILD_DIR)/catalog-server

$(BUILD_DIR)/ois-serve: ois-serve.m $(SOURCES) $(HEADERS)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(FLAGS) $(INCLUDES) ois-serve.m $(SOURCES) $(LIBS) -o $@

$(BUILD_DIR)/catalog-server: Examples/CatalogServer.m $(SOURCES) $(HEADERS)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(FLAGS) $(INCLUDES) Examples/CatalogServer.m $(SOURCES) $(LIBS) -o $@

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
