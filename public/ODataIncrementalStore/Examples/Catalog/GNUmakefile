# AppKit catalog on GNUstep. Requires FreeCoreData + gnustep-gui.
# The model is Catalog.xcdatamodeld (FreeCoreData reads that XML, and compiled .momd).
# UI is CatalogWindow.xib (GSXib5Loader / Apple IB).
ifeq ($(GNUSTEP_MAKEFILES),)
$(error Set GNUSTEP_MAKEFILES (source GNUstep.sh).)
endif

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

APP_NAME = Catalog
Catalog_OBJC_FILES = main.m CatalogController.m
Catalog_INCLUDE_DIRS = -I../../Source/include
Catalog_LIB_DIRS = -L../..
Catalog_OBJC_LIBS += -lODataIncrementalStore -lCoreData
Catalog_TOOL_LIBS += -lODataIncrementalStore -lCoreData
Catalog_RESOURCE_FILES = Catalog.xcdatamodeld CatalogWindow.xib

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions \
	-DCATALOG_MODEL_DIR=\"$(CURDIR)\"

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/application.make
-include GNUmakefile.postamble

# gnustep-make copies RESOURCE_FILES; a directory bundle needs an extra pass.
after-all::
	@dst="$(GNUSTEP_OBJ_DIR)/$(APP_NAME).app/Resources"; \
	if [ ! -d "$$dst" ]; then dst="./$(APP_NAME).app/Resources"; fi; \
	mkdir -p "$$dst"; \
	rm -rf "$$dst/Catalog.xcdatamodeld"; \
	cp -R Catalog.xcdatamodeld "$$dst/"; \
	cp -f CatalogWindow.xib "$$dst/"
