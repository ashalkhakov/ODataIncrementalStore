# GNU Makefile for ODataIncrementalStore on GNUstep.
# Requires clang + libobjc2 (the modern runtime). GCC's libobjc will not do.
#
# Core Data on GNUstep is FreeCoreData:
#   https://github.com/ashalkhakov/FreeCoreData
# Install that framework first, then:
#
#   export GNUSTEP_MAKEFILES=/usr/share/GNUstep/Makefiles
#   . /usr/share/GNUstep/Makefiles/GNUstep.sh
#   make
#   make install
#
# Without gnustep-make, use the sibling Makefile (gnustep-config + clang).

ifeq ($(GNUSTEP_MAKEFILES),)
$(error Set GNUSTEP_MAKEFILES (source GNUstep.sh). Or run `make -f Makefile` with gnustep-config.)
endif

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

ifeq ($(findstring gcc,$(CC)),gcc)
$(error OIS requires clang + libobjc2. GCC's libobjc is the old fragile runtime.)
endif

LIBRARY_NAME = ODataIncrementalStore
ODataIncrementalStore_NEEDS_GUI = no

ODataIncrementalStore_OBJC_FILES = \
	Source/ODataError.m \
	Source/ODataConfiguration.m \
	Source/ODataClient.m \
	Source/ODataPropertyMapper.m \
	Source/ODataValue.m \
	Source/ODataBatch.m \
	Source/ODataSchema.m \
	Source/ODataOperationCall.m \
	Source/ODataLexer.m \
	Source/ODataExpression.m \
	Source/ODataHistory.m \
	Source/ODataClassWriter.m \
	Source/ODataFunctionExpression.m \
	Source/ODataModelBuilder.m \
	Source/ODataResourceIdentifier.m \
	Source/ODataPredicateTranslator.m \
	Source/ODataQueryBuilder.m \
	Source/ODataIncrementalStore.m \
	Source/ODataPredicateBuilder.m \
	Source/ODataMetadataWriter.m \
	Source/ODataOperationCatalog.m \
	Source/ODataService.m \
	Source/ODataServiceBatch.m \
	Source/ODataAuthentication.m \
	Source/OISSignature.m

ODataIncrementalStore_HEADER_FILES = \
	ODataIncrementalStore.h \
	OISRuntime.h \
	OISCoreData.h \
	ODataError.h \
	ODataConfiguration.h \
	ODataClient.h \
	ODataPropertyMapper.h \
	ODataValue.h \
	ODataBatch.h \
	ODataSchema.h \
	ODataOperationCall.h \
	ODataExpression.h \
	ODataHistory.h \
	ODataClassWriter.h \
	ODataFunctionExpression.h \
	ODataModelBuilder.h \
	ODataResourceIdentifier.h \
	ODataPredicateTranslator.h \
	ODataQueryBuilder.h \
	ODataPredicateBuilder.h \
	ODataMetadataWriter.h \
	ODataService.h \
	ODataAuthentication.h

ODataIncrementalStore_HEADER_FILES_DIR = Source/include
ODataIncrementalStore_HEADER_FILES_INSTALL_DIR = ODataIncrementalStore
ODataIncrementalStore_INCLUDE_DIRS = -ISource/include
ODataIncrementalStore_LIBRARIES_DEPEND_UPON += -lCoreData -ldispatch -lgnutls

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions -Wall -Wno-unused-parameter
ODataIncrementalStore_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions -Wall -Wno-unused-parameter
ODataIncrementalStore_CFLAGS += -fblocks

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/library.make
-include GNUmakefile.postamble

.PHONY: test
test: all
	$(MAKE) -C Tests run-tests
