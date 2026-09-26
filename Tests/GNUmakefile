# XCTest bundle for ODataIncrementalStore.
# Snapshots in Tests/Snapshots — no live OData service.
#
#   make -C Tests run-tests
#   # or from the library root: make test
#
# Requires clang + libobjc2 + GNUstep XCTest
# (https://github.com/gnustep/libs-xctest) and FreeCoreData.

ifeq ($(GNUSTEP_MAKEFILES),)
$(error Set GNUSTEP_MAKEFILES (source GNUstep.sh).)
endif

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang
OBJC_RUNTIME_LIB = ng
RUNTIME_VERSION = gnustep-2.0
GS_WITH_ARC = 1

BUNDLE_NAME = ODataIncrementalStoreTests
ODataIncrementalStoreTests_NEEDS_GUI = no

ODataIncrementalStoreTests_OBJC_FILES = \
	OISCatalogModel.m \
	ODataSnapshotTransport.m \
	ODataPredicateTranslatorTests.m \
	ODataQueryBuilderTests.m \
	ODataValueTests.m \
	ODataResourceIdentifierTests.m \
	ODataSnapshotStoreTests.m

ODataIncrementalStoreTests_RESOURCE_FILES = Snapshots
ODataIncrementalStoreTests_INCLUDE_DIRS = -I../Source/include -I.
# gnustep-make builds the library into ../obj; `make -f Makefile` into ..
ODataIncrementalStoreTests_LIB_DIRS = -L../obj -L..
ODataIncrementalStoreTests_OBJC_LIBS += -lODataIncrementalStore -lXCTest -lCoreData

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions \
	-DOIS_CATALOG_MODEL_DIR=\"$(CURDIR)/../Examples/Catalog\"

XCTEST ?= xctest

.PHONY: check run-tests
run-tests: all $(BUNDLE_NAME).bundle
	LD_LIBRARY_PATH="$(CURDIR)/../obj:$(CURDIR)/..$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}" \
	OIS_SNAPSHOTS="$(CURDIR)/Snapshots" $(XCTEST) "$(BUNDLE_NAME).bundle"

# FreeCoreData loads compiled models only, so Catalog.xcdatamodeld is
# compiled to Catalog.momd by FreeCoreData's momc and lands in Resources.
# momc and coredata-model.make come from `make -C Tools/momc install` there.
ODataIncrementalStoreTests_XCDATAMODELD_FILES = Catalog.xcdatamodeld
vpath %.xcdatamodeld ../Examples/Catalog
include $(GNUSTEP_MAKEFILES)/coredata-model.make

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/bundle.make
-include GNUmakefile.postamble
