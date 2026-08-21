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
# Translator-only (no FreeCoreData, in-tree stub):
#   make OIS_COREDATA=stub
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
	Source/ODataResourceIdentifier.m \
	Source/ODataPredicateTranslator.m \
	Source/ODataQueryBuilder.m \
	Source/ODataIncrementalStore.m

ODataIncrementalStore_HEADER_FILES = \
	ODataIncrementalStore.h \
	OISRuntime.h \
	OISCoreData.h \
	OISCoreDataStub.h \
	ODataError.h \
	ODataConfiguration.h \
	ODataClient.h \
	ODataPropertyMapper.h \
	ODataResourceIdentifier.h \
	ODataPredicateTranslator.h \
	ODataQueryBuilder.h

ODataIncrementalStore_HEADER_FILES_DIR = Source/include
ODataIncrementalStore_HEADER_FILES_INSTALL_DIR = ODataIncrementalStore
ODataIncrementalStore_INCLUDE_DIRS = -ISource/include

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions -Wall -Wno-unused-parameter
ODataIncrementalStore_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions -Wall -Wno-unused-parameter
ODataIncrementalStore_CFLAGS += -fblocks

# FreeCoreData is the default GNUstep Core Data. OIS_USE_SYSTEM_COREDATA=yes
# is kept as a synonym. OIS_COREDATA=stub compiles the in-tree shim.
ifneq ($(OIS_COREDATA),stub)
ODataIncrementalStore_LIBRARIES_DEPEND_UPON += -lCoreData
else
ODataIncrementalStore_CPPFLAGS += -DOIS_FORCE_STUB_COREDATA
ODataIncrementalStore_OBJC_FILES += Source/OISCoreDataStub.m
endif

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/library.make
-include GNUmakefile.postamble
