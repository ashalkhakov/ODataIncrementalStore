# AppKit workbench on GNUstep. Requires FreeCoreData + gnustep-gui.
# In-memory OData v4 behind ODataTransport — no network.
# UI is WorkbenchWindow.xib (GSXib5Loader / Apple IB).
ifeq ($(GNUSTEP_MAKEFILES),)
$(error Set GNUSTEP_MAKEFILES (source GNUstep.sh).)
endif

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

APP_NAME = Workbench
Workbench_OBJC_FILES = main.m WorkbenchController.m WorkbenchEngine.m
Workbench_INCLUDE_DIRS = -I../../Source/include
Workbench_LIB_DIRS = -L../..
Workbench_OBJC_LIBS += -lODataIncrementalStore -lCoreData
Workbench_TOOL_LIBS += -lODataIncrementalStore -lCoreData
Workbench_RESOURCE_FILES = WorkbenchWindow.xib

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions \
	-DWORKBENCH_MODEL_DIR=\"$(CURDIR)\"

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/application.make
-include GNUmakefile.postamble

after-all::
	@dst=\"$(GNUSTEP_OBJ_DIR)/$(APP_NAME).app/Resources\"; \
	if [ ! -d \"$$dst\" ]; then dst=\"./$(APP_NAME).app/Resources\"; fi; \
	mkdir -p \"$$dst\"; \
	rm -rf \"$$dst/Catalog.xcdatamodeld\"; \
	cp -R ../Catalog/Catalog.xcdatamodeld \"$$dst/\"; \
	cp -f WorkbenchWindow.xib \"$$dst/\"
