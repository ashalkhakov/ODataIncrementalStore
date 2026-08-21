# AppKit catalog on GNUstep. Requires FreeCoreData + gnustep-gui.
ifeq ($(GNUSTEP_MAKEFILES),)
$(error Set GNUSTEP_MAKEFILES (source GNUstep.sh).)
endif

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

APP_NAME = Catalog
Catalog_OBJC_FILES = main.m CatalogController.m CatalogModel.m
Catalog_INCLUDE_DIRS = -I../../Source/include
Catalog_LIB_DIRS = -L../..
Catalog_OBJC_LIBS += -lODataIncrementalStore -lCoreData
Catalog_TOOL_LIBS += -lODataIncrementalStore -lCoreData

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/application.make
-include GNUmakefile.postamble
