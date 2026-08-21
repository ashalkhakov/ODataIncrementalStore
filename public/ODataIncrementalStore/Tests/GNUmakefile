# XCTest bundle for ODataIncrementalStore.
# Snapshots in Tests/Snapshots — no live OData service.
#
#   make -C Tests run-tests
#   # or from the library root: make test
#
# Requires clang + libobjc2 + GNUstep XCTest
# (https://github.com/gnustep/libs-xctest) and FreeCoreData, unless
# OIS_COREDATA=stub.

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
	ODataResourceIdentifierTests.m \
	ODataSnapshotStoreTests.m

ODataIncrementalStoreTests_RESOURCE_FILES = Snapshots
ODataIncrementalStoreTests_INCLUDE_DIRS = -I../Source/include -I.
ODataIncrementalStoreTests_LIB_DIRS = -L..
ODataIncrementalStoreTests_OBJC_LIBS += -lODataIncrementalStore -lXCTest
ifneq ($(OIS_COREDATA),stub)
ODataIncrementalStoreTests_OBJC_LIBS += -lCoreData
endif

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions \
	-DOIS_CATALOG_MODEL_DIR=\"$(CURDIR)/../Examples/Catalog\"
ifeq ($(OIS_COREDATA),stub)
ADDITIONAL_OBJCFLAGS += -DOIS_FORCE_STUB_COREDATA
endif

XCTEST ?= xctest

.PHONY: check run-tests
run-tests: all $(BUNDLE_NAME).bundle
	OIS_SNAPSHOTS="$(CURDIR)/Snapshots" $(XCTEST) "$(BUNDLE_NAME).bundle"

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/bundle.make
-include GNUmakefile.postamble

after-all::
	@dst="$(GNUSTEP_OBJ_DIR)/$(BUNDLE_NAME).bundle/Resources"; \
	if [ ! -d "$$dst" ]; then dst="./$(BUNDLE_NAME).bundle/Resources"; fi; \
	mkdir -p "$$dst"; \
	rm -rf "$$dst/Catalog.xcdatamodeld"; \
	cp -R ../Examples/Catalog/Catalog.xcdatamodeld "$$dst/"
