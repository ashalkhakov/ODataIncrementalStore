# GCDWebServer.make: the ported GCDWebServer sources, for a gnustep-make
# target elsewhere in the repository. Paths are relative to the repository
# root; set GCDWebServer_DIR first to include it from somewhere else.
#
#   include ThirdParty/GCDWebServer/GCDWebServer.make
#   MyServer_OBJC_FILES         += $(GCDWebServer_OBJC_FILES)
#   MyServer_INCLUDE_DIRS       += $(GCDWebServer_INCLUDE_DIRS)
#   MyServer_OBJCFLAGS          += $(GCDWebServer_OBJCFLAGS)
#   MyServer_LIBRARIES_DEPEND_UPON += $(GCDWebServer_LIBS)   # library target
#   MyServer_TOOL_LIBS          += $(GCDWebServer_LIBS)      # tool target
#
# The sources require clang, ARC and blocks (libobjc2, gnustep-2.0 runtime).

GCDWebServer_DIR ?= ThirdParty/GCDWebServer

GCDWebServer_OBJC_FILES = \
	$(GCDWebServer_DIR)/Core/GCDWebServer.m \
	$(GCDWebServer_DIR)/Core/GCDWebServerConnection.m \
	$(GCDWebServer_DIR)/Core/GCDWebServerFunctions.m \
	$(GCDWebServer_DIR)/Core/GCDWebServerHTTPMessage.m \
	$(GCDWebServer_DIR)/Core/GCDWebServerRequest.m \
	$(GCDWebServer_DIR)/Core/GCDWebServerResponse.m \
	$(GCDWebServer_DIR)/Requests/GCDWebServerDataRequest.m \
	$(GCDWebServer_DIR)/Requests/GCDWebServerFileRequest.m \
	$(GCDWebServer_DIR)/Requests/GCDWebServerMultiPartFormRequest.m \
	$(GCDWebServer_DIR)/Requests/GCDWebServerURLEncodedFormRequest.m \
	$(GCDWebServer_DIR)/Responses/GCDWebServerDataResponse.m \
	$(GCDWebServer_DIR)/Responses/GCDWebServerErrorResponse.m \
	$(GCDWebServer_DIR)/Responses/GCDWebServerFileResponse.m \
	$(GCDWebServer_DIR)/Responses/GCDWebServerStreamedResponse.m

# Public headers (GCDWebServerPrivate.h and GCDWebServerHTTPMessage.h are internal)
GCDWebServer_HEADER_FILES = \
	$(GCDWebServer_DIR)/Core/GCDWebServer.h \
	$(GCDWebServer_DIR)/Core/GCDWebServerConnection.h \
	$(GCDWebServer_DIR)/Core/GCDWebServerFunctions.h \
	$(GCDWebServer_DIR)/Core/GCDWebServerHTTPStatusCodes.h \
	$(GCDWebServer_DIR)/Core/GCDWebServerRequest.h \
	$(GCDWebServer_DIR)/Core/GCDWebServerResponse.h \
	$(GCDWebServer_DIR)/Requests/GCDWebServerDataRequest.h \
	$(GCDWebServer_DIR)/Requests/GCDWebServerFileRequest.h \
	$(GCDWebServer_DIR)/Requests/GCDWebServerMultiPartFormRequest.h \
	$(GCDWebServer_DIR)/Requests/GCDWebServerURLEncodedFormRequest.h \
	$(GCDWebServer_DIR)/Responses/GCDWebServerDataResponse.h \
	$(GCDWebServer_DIR)/Responses/GCDWebServerErrorResponse.h \
	$(GCDWebServer_DIR)/Responses/GCDWebServerFileResponse.h \
	$(GCDWebServer_DIR)/Responses/GCDWebServerStreamedResponse.h

GCDWebServer_INCLUDE_DIRS = \
	-I$(GCDWebServer_DIR)/Core \
	-I$(GCDWebServer_DIR)/Requests \
	-I$(GCDWebServer_DIR)/Responses

GCDWebServer_OBJCFLAGS = -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions -Wall

GCDWebServer_LIBS = -ldispatch -lz
