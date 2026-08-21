# clang + libobjc2 + gnustep-base + FreeCoreData.
# Does not need gnustep-make.
#
# Install FreeCoreData first: https://github.com/ashalkhakov/FreeCoreData
#
#   make
#   ./ois-filter 'unitPrice > 20 AND discontinued == NO'
#
# Without FreeCoreData (translator only):
#   make OIS_COREDATA=stub
#
# GCC's libobjc will not work. clang is required.

CC ?= clang
SRC_DIR = Source
INC = -I$(SRC_DIR)/include

ifeq ($(findstring gcc,$(CC)),gcc)
$(error OIS requires clang + libobjc2. GCC's libobjc is the old fragile runtime.)
endif

GNUSTEP_FLAGS := $(shell gnustep-config --objc-flags 2>/dev/null)
GNUSTEP_LIBS  := $(shell gnustep-config --base-libs 2>/dev/null)

ifeq ($(strip $(GNUSTEP_FLAGS)),)
  GNUSTEP_FLAGS = -I/usr/include/GNUstep -DGNUSTEP -DGNUSTEP_BASE_LIBRARY=1
  GNUSTEP_LIBS  = -lgnustep-base -lobjc -lpthread
endif

OBJCFLAGS = $(GNUSTEP_FLAGS) \
	-fobjc-runtime=gnustep-2.0 \
	-fobjc-arc \
	-fblocks \
	-fconstant-string-class=NSConstantString \
	-fobjc-exceptions \
	-fPIC \
	-Wall -Wno-unused-parameter \
	$(INC)

SRCS = \
	$(SRC_DIR)/ODataError.m \
	$(SRC_DIR)/ODataConfiguration.m \
	$(SRC_DIR)/ODataClient.m \
	$(SRC_DIR)/ODataPropertyMapper.m \
	$(SRC_DIR)/ODataResourceIdentifier.m \
	$(SRC_DIR)/ODataPredicateTranslator.m \
	$(SRC_DIR)/ODataQueryBuilder.m \
	$(SRC_DIR)/ODataIncrementalStore.m

ifneq ($(OIS_COREDATA),stub)
  GNUSTEP_LIBS += -lCoreData
else
  OBJCFLAGS += -DOIS_FORCE_STUB_COREDATA
  SRCS += $(SRC_DIR)/OISCoreDataStub.m
endif

OBJS = $(SRCS:.m=.o)

.PHONY: all clean

all: libODataIncrementalStore.so ois-filter

libODataIncrementalStore.so: $(OBJS)
	$(CC) -shared -o $@ $(OBJS) $(GNUSTEP_LIBS)

$(SRC_DIR)/%.o: $(SRC_DIR)/%.m
	$(CC) $(OBJCFLAGS) -c $< -o $@

ois-filter: Tools/ois-filter.m libODataIncrementalStore.so
	$(CC) $(OBJCFLAGS) -o $@ Tools/ois-filter.m -L. -lODataIncrementalStore $(GNUSTEP_LIBS)

clean:
	rm -f $(OBJS) libODataIncrementalStore.so ois-filter
