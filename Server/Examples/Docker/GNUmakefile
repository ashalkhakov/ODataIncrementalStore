# catalog-server (../CatalogServer.m), built against the installed ODataKit:
# the variables come from the fragment `make install` put in
# $(GNUSTEP_MAKEFILES)/Additional, which every GNUmakefile includes.
#
#   make                       in the odatakit-sdk image, or anywhere it is installed

include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = catalog-server
catalog-server_OBJC_FILES = CatalogServer.m
catalog-server_INCLUDE_DIRS = $(ODATASERVICE_INCLUDE_DIRS)
catalog-server_OBJCFLAGS = $(ODATAKIT_OBJCFLAGS)
catalog-server_TOOL_LIBS = $(ODATASERVICE_LIBS)

include $(GNUSTEP_MAKEFILES)/tool.make
