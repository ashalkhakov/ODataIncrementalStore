# AppKit workbench on GNUstep. Requires FreeCoreData + gnustep-gui.
# Try out an OData v4 service: the built-in in-memory one, Northwind,
# TripPin, or any other.
# UI is WorkbenchWindow.xib (GSXib5Loader).
ifeq ($(GNUSTEP_MAKEFILES),)
$(error Set GNUSTEP_MAKEFILES (source GNUstep.sh).)
endif

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

APP_NAME = Workbench
Workbench_OBJC_FILES = main.m WorkbenchController.m WorkbenchEngine.m
Workbench_INCLUDE_DIRS = -I../../Source/ODataKit/include -I../../Source/ODataIncrementalStore/include -I../../Source/ODataService/include -I../../Source/ODataKit/include/ODataKit -I../../Source/ODataIncrementalStore/include/ODataIncrementalStore -I../../Source/ODataService/include/ODataService
Workbench_LIB_DIRS = -L../../obj -L../..
Workbench_OBJC_LIBS += -lODataService -lODataIncrementalStore -lODataKit -lCoreData -ldispatch
Workbench_TOOL_LIBS += -lODataService -lODataIncrementalStore -lODataKit -lCoreData -ldispatch
Workbench_RESOURCE_FILES = WorkbenchWindow.xib Workbench.png
Workbench_APPLICATION_ICON = Workbench.png

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions \
	-DWORKBENCH_MODEL_DIR=\"$(CURDIR)\"

# FreeCoreData loads compiled models only, so Catalog.xcdatamodeld is
# compiled to Catalog.momd by FreeCoreData's momc and lands in Resources.
# momc and coredata-model.make come from `make -C Tools/momc install` there.
Workbench_XCDATAMODELD_FILES = Catalog.xcdatamodeld
vpath %.xcdatamodeld ../Catalog
include $(GNUSTEP_MAKEFILES)/coredata-model.make

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/application.make
-include GNUmakefile.postamble
