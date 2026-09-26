# ois-live: the store against Microsoft's public reference services,
# Northwind v4 (read) and TripPin (write).
#
#   make -C Tests/Live live
#
# Needs the library built first (make at the root), network access, and
# FreeCoreData's momc for the model.
ifeq ($(GNUSTEP_MAKEFILES),)
$(error Set GNUSTEP_MAKEFILES (source GNUstep.sh).)
endif

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

TOOL_NAME = ois-live
ois-live_OBJC_FILES = ois-live.m
ois-live_INCLUDE_DIRS = -I../../Source/include
ois-live_LIB_DIRS = -L../../obj -L../..
ois-live_TOOL_LIBS += -lODataIncrementalStore -lCoreData

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions

MOMC ?= momc

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/tool.make
-include GNUmakefile.postamble

.PHONY: live Catalog.momd Northwind.momd TripPin.momd
Catalog.momd: ../../Examples/Catalog/Catalog.xcdatamodeld
	$(MOMC) $< $@

TripPin.momd: TripPin.xcdatamodeld
	$(MOMC) $< $@

Northwind.momd: Northwind.xcdatamodeld
	$(MOMC) $< $@

live: all Catalog.momd Northwind.momd TripPin.momd
	LD_LIBRARY_PATH="$(CURDIR)/../../obj$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}" \
	./$(GNUSTEP_OBJ_DIR_NAME)/ois-live .

after-clean::
	rm -rf Catalog.momd Northwind.momd TripPin.momd
