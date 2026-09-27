# clang + libobjc2 + gnustep-base + FreeCoreData.
# Does not need gnustep-make.
#
# Install FreeCoreData first: https://github.com/ashalkhakov/FreeCoreData
#
#   make
#   ./ois-filter 'unitPrice > 20 AND discontinued == NO'
#
# GCC's libobjc will not work. clang is required.

# `?=` would never fire: make predefines CC as cc.
ifeq ($(origin CC),default)
CC = clang
endif
SRC_DIR = Source
LIBS_ = ODataKit ODataIncrementalStore ODataService
INC = $(foreach l,$(LIBS_),-I$(SRC_DIR)/$(l)/include -I$(SRC_DIR)/$(l)/include/$(l))

ifeq ($(findstring gcc,$(CC)),gcc)
$(error OIS requires clang + libobjc2. GCC's libobjc is the old fragile runtime.)
endif

GNUSTEP_FLAGS := $(shell gnustep-config --objc-flags 2>/dev/null)
GNUSTEP_LIBS  := $(shell gnustep-config --base-libs 2>/dev/null)

ifeq ($(strip $(GNUSTEP_FLAGS)),)
  GNUSTEP_FLAGS = -I/usr/include/GNUstep -DGNUSTEP -DGNUSTEP_BASE_LIBRARY=1
  GNUSTEP_LIBS  = -lgnustep-base -lobjc -lpthread
endif

GNUSTEP_LIBS += -lCoreData -ldispatch -lgnutls

OBJCFLAGS = $(GNUSTEP_FLAGS) \
	-fobjc-runtime=gnustep-2.0 \
	-fobjc-arc \
	-fblocks \
	-fconstant-string-class=NSConstantString \
	-fobjc-exceptions \
	-fPIC \
	-Wall -Wno-unused-parameter \
	$(INC)

KIT_SRCS = $(wildcard $(SRC_DIR)/ODataKit/*.m)
CLIENT_SRCS = $(wildcard $(SRC_DIR)/ODataIncrementalStore/*.m)
SERVICE_SRCS = $(wildcard $(SRC_DIR)/ODataService/*.m)
SRCS = $(KIT_SRCS) $(CLIENT_SRCS) $(SERVICE_SRCS)

OBJS = $(SRCS:.m=.o)

.PHONY: all clean test

all: libODataKit.so libODataIncrementalStore.so libODataService.so ois-filter ois-model Catalog.momd

libODataKit.so: $(KIT_SRCS:.m=.o)
	$(CC) -shared -o $@ $^ $(GNUSTEP_LIBS)

libODataIncrementalStore.so: $(CLIENT_SRCS:.m=.o) libODataKit.so
	$(CC) -shared -o $@ $(CLIENT_SRCS:.m=.o) -L. -lODataKit $(GNUSTEP_LIBS)

libODataService.so: $(SERVICE_SRCS:.m=.o) libODataKit.so
	$(CC) -shared -o $@ $(SERVICE_SRCS:.m=.o) -L. -lODataKit $(GNUSTEP_LIBS)

$(SRC_DIR)/%.o: $(SRC_DIR)/%.m
	$(CC) $(OBJCFLAGS) -c $< -o $@

ois-filter: Tools/ois-filter.m libODataIncrementalStore.so
	$(CC) $(OBJCFLAGS) -o $@ Tools/ois-filter.m -L. -lODataIncrementalStore -lODataKit $(GNUSTEP_LIBS)

# A Core Data model from a service's $metadata:
#   ./ois-model https://services.odata.org/V4/Northwind/Northwind.svc/ Northwind.xcdatamodeld
ois-model: Tools/ois-model.m libODataIncrementalStore.so
	$(CC) $(OBJCFLAGS) -o $@ Tools/ois-model.m -L. -lODataIncrementalStore -lODataKit $(GNUSTEP_LIBS)

# FreeCoreData's model compiler (make -C Tools/momc install there).
MOMC ?= momc

# Rebuilt every time: a directory's mtime does not follow its contents.
.PHONY: Catalog.momd
Catalog.momd: Examples/Catalog/Catalog.xcdatamodeld
	$(MOMC) $< $@

# XCTest bundle needs gnustep-make. This target documents the entry point.
test:
	$(MAKE) -C Tests run-tests

clean:
	rm -f $(OBJS) libODataKit.so libODataIncrementalStore.so libODataService.so ois-filter ois-model
	rm -rf Catalog.momd
