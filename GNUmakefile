# GNU Makefile for the ODataKit libraries on GNUstep:
#   ODataKit               what a client and a service share
#   ODataIncrementalStore  the client: a Core Data store over an OData service
#   ODataService           the server: a Core Data store served over OData
# (the HTTP adapter, ODataHTTPServer, and ois-serve are in Server/).
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

# Each library's headers by <Library/Header.h>, and in the tree by name.
OIS_INCLUDE_DIRS = -ISource/ODataKit/include -ISource/ODataIncrementalStore/include -ISource/ODataService/include \
	-ISource/ODataKit/include/ODataKit -ISource/ODataIncrementalStore/include/ODataIncrementalStore \
	-ISource/ODataService/include/ODataService
OIS_OBJCFLAGS = -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions -Wall -Wno-unused-parameter
ADDITIONAL_OBJCFLAGS += $(OIS_OBJCFLAGS)

# In the order they depend on each other.
LIBRARY_NAME = ODataKit ODataIncrementalStore ODataService

ODataKit_NEEDS_GUI = no
ODataKit_OBJC_FILES = \
	Source/ODataKit/ODataApply.m \
	Source/ODataKit/ODataBatch.m \
	Source/ODataKit/ODataCSDL.m \
	Source/ODataKit/ODataError.m \
	Source/ODataKit/ODataExpression.m \
	Source/ODataKit/ODataLexer.m \
	Source/ODataKit/ODataPropertyMapper.m \
	Source/ODataKit/ODataSchema.m \
	Source/ODataKit/ODataTransport.m \
	Source/ODataKit/ODataValue.m

ODataKit_HEADER_FILES = \
	ODataApply.h \
	ODataBatch.h \
	ODataCSDL.h \
	ODataError.h \
	ODataExpression.h \
	ODataKit.h \
	ODataPropertyMapper.h \
	ODataSchema.h \
	ODataTransport.h \
	ODataValue.h \
	OISCoreData.h \
	OISRuntime.h

ODataKit_HEADER_FILES_DIR = Source/ODataKit/include/ODataKit
ODataKit_HEADER_FILES_INSTALL_DIR = ODataKit
ODataKit_INCLUDE_DIRS = $(OIS_INCLUDE_DIRS)
ODataKit_LIB_DIRS = -L./obj
ODataKit_LIBRARIES_DEPEND_UPON += -lCoreData -ldispatch
ODataKit_OBJCFLAGS += $(OIS_OBJCFLAGS)
ODataKit_CFLAGS += -fblocks

ODataIncrementalStore_NEEDS_GUI = no
ODataIncrementalStore_OBJC_FILES = \
	Source/ODataIncrementalStore/ODataClassWriter.m \
	Source/ODataIncrementalStore/ODataClient.m \
	Source/ODataIncrementalStore/ODataConfiguration.m \
	Source/ODataIncrementalStore/ODataFunctionExpression.m \
	Source/ODataIncrementalStore/ODataHistory.m \
	Source/ODataIncrementalStore/ODataIncrementalStore.m \
	Source/ODataIncrementalStore/ODataModelBuilder.m \
	Source/ODataIncrementalStore/ODataOperationCall.m \
	Source/ODataIncrementalStore/ODataStreamTransfer.m \
	Source/ODataIncrementalStore/ODataSearchPredicate.m \
	Source/ODataIncrementalStore/ODataPredicateTranslator.m \
	Source/ODataIncrementalStore/ODataQueryBuilder.m \
	Source/ODataIncrementalStore/ODataResourceIdentifier.m

ODataIncrementalStore_HEADER_FILES = \
	ODataClassWriter.h \
	ODataClient.h \
	ODataConfiguration.h \
	ODataFunctionExpression.h \
	ODataHistory.h \
	ODataIncrementalStore.h \
	ODataModelBuilder.h \
	ODataOperationCall.h \
	ODataStreamTransfer.h \
	ODataSearchPredicate.h \
	ODataPredicateTranslator.h \
	ODataQueryBuilder.h \
	ODataResourceIdentifier.h

ODataIncrementalStore_HEADER_FILES_DIR = Source/ODataIncrementalStore/include/ODataIncrementalStore
ODataIncrementalStore_HEADER_FILES_INSTALL_DIR = ODataIncrementalStore
ODataIncrementalStore_INCLUDE_DIRS = $(OIS_INCLUDE_DIRS)
ODataIncrementalStore_LIB_DIRS = -L./obj
ODataIncrementalStore_LIBRARIES_DEPEND_UPON += -lODataKit -lCoreData
ODataIncrementalStore_OBJCFLAGS += $(OIS_OBJCFLAGS)
ODataIncrementalStore_CFLAGS += -fblocks

ODataService_NEEDS_GUI = no
ODataService_OBJC_FILES = \
	Source/ODataService/ODataAuthentication.m \
	Source/ODataService/ODataMetadataWriter.m \
	Source/ODataService/ODataOperationCatalog.m \
	Source/ODataService/ODataPredicateBuilder.m \
	Source/ODataService/ODataService.m \
	Source/ODataService/ODataServiceBatch.m \
	Source/ODataService/OISSignature.m

ODataService_HEADER_FILES = \
	ODataAuthentication.h \
	ODataMetadataWriter.h \
	ODataPredicateBuilder.h \
	ODataService.h

ODataService_HEADER_FILES_DIR = Source/ODataService/include/ODataService
ODataService_HEADER_FILES_INSTALL_DIR = ODataService
ODataService_INCLUDE_DIRS = $(OIS_INCLUDE_DIRS)
ODataService_LIB_DIRS = -L./obj
ODataService_LIBRARIES_DEPEND_UPON += -lODataKit -lCoreData -ldispatch -lgnutls
ODataService_OBJCFLAGS += $(OIS_OBJCFLAGS)
ODataService_CFLAGS += -fblocks

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/library.make
-include GNUmakefile.postamble

.PHONY: test
test: all
	$(MAKE) -C Tests run-tests
