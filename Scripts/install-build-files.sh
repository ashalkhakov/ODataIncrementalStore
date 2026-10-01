#!/bin/sh
# What an application builds against the installed libraries with: a
# gnustep-make fragment (in $GNUSTEP_MAKEFILES/Additional, which every
# GNUmakefile includes by itself) and pkg-config files. Run by `make install`
# (and `make uninstall`) of the libraries:
#
#   install-build-files.sh install|uninstall libraries
#
# with, from the makefile, the installation domain's directories as they
# will be (HEADERS_DIR, LIBRARIES_DIR, MAKEFILES_DIR), DESTDIR (written
# under it, never named in what is written), VERSION, and the GNUstep flags
# a build outside gnustep-make needs (GNUSTEP_OBJC_FLAGS, GNUSTEP_BASE_LIBS).
set -eu

action=$1 component=$2
: "${HEADERS_DIR:?}" "${LIBRARIES_DIR:?}" "${MAKEFILES_DIR:?}"
DESTDIR=${DESTDIR:-}
VERSION=${VERSION:-0.0.0}
VERSION=${VERSION#v}
GNUSTEP_OBJC_FLAGS=${GNUSTEP_OBJC_FLAGS:-}
GNUSTEP_BASE_LIBS=${GNUSTEP_BASE_LIBS:-}

fragments="$DESTDIR$MAKEFILES_DIR/Additional"
pkgconfig="$DESTDIR$LIBRARIES_DIR/pkgconfig"

# The flags a build needs beyond gnustep-config's own (which also adds
# dependency files, warnings and optimization: those are the caller's).
objc_flags="-fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 -fconstant-string-class=NSConstantString -fobjc-exceptions"
kept_flags() {
  for flag in $GNUSTEP_OBJC_FLAGS; do
    case "$flag" in
      -MMD|-MP|-I.|-g|-O*|-W*) ;;
      *) printf '%s ' "$flag" ;;
    esac
  done
}
gnustep_flags=$(kept_flags)

pc() {  # name requires description cflags libs
  cat > "$pkgconfig/$1.pc" <<EOF
includedir=$HEADERS_DIR
libdir=$LIBRARIES_DIR

Name: $1
Description: $3
Version: $VERSION
Requires: $2
Cflags: $4
Libs: $5
EOF
}

case "$action:$component" in
  install:libraries)
    mkdir -p "$fragments" "$pkgconfig"
    cat > "$fragments/httpserverkit.make" <<EOF
# HTTPServerKit, installed (Scripts/install-build-files.sh): an HTTP server
# for APIs. What an application's GNUmakefile names to build with it:
#
#   TOOL_NAME = myserver
#   myserver_OBJC_FILES = main.m
#   myserver_INCLUDE_DIRS += \$(HTTPSERVERKIT_INCLUDE_DIRS)
#   myserver_OBJCFLAGS += \$(HTTPSERVERKIT_OBJCFLAGS)
#   myserver_TOOL_LIBS += \$(HTTPSERVERKIT_LIBS)
HTTPSERVERKIT_VERSION = $VERSION
HTTPSERVERKIT_OBJCFLAGS = $objc_flags
HTTPSERVERKIT_INCLUDE_DIRS = -I$HEADERS_DIR -I$HEADERS_DIR/HTTPServerKit
HTTPSERVERKIT_LIBS = -L$LIBRARIES_DIR -lHTTPServerKit -ldispatch -lgnutls -lz
EOF
    cat > "$fragments/odatakit.make" <<EOF
# ODataKit, installed (Scripts/install-build-files.sh): what an
# application's GNUmakefile names to build with it.
#
#   TOOL_NAME = myserver
#   myserver_OBJC_FILES = main.m
#   myserver_INCLUDE_DIRS += \$(ODATASERVICE_INCLUDE_DIRS)
#   myserver_OBJCFLAGS += \$(ODATAKIT_OBJCFLAGS)
#   myserver_TOOL_LIBS += \$(ODATASERVICE_LIBS)
#
# ODATAKIT_*, ODATAINCREMENTALSTORE_* (the client) and ODATASERVICE_* (the
# service, on its own or on the network with HTTPServerKit: ODataServer.h,
# and httpserverkit.make).
ODATAKIT_VERSION = $VERSION
ODATAKIT_OBJCFLAGS = $objc_flags
ODATAKIT_INCLUDE_DIRS = -I$HEADERS_DIR -I$HEADERS_DIR/ODataKit
ODATAKIT_LIBS = -L$LIBRARIES_DIR -lODataKit -lCoreData -ldispatch
ODATAINCREMENTALSTORE_INCLUDE_DIRS = \$(ODATAKIT_INCLUDE_DIRS) -I$HEADERS_DIR/ODataIncrementalStore
ODATAINCREMENTALSTORE_LIBS = -lODataIncrementalStore \$(ODATAKIT_LIBS)
ODATASERVICE_INCLUDE_DIRS = \$(ODATAKIT_INCLUDE_DIRS) -I$HEADERS_DIR/HTTPServerKit -I$HEADERS_DIR/ODataService
ODATASERVICE_LIBS = -lODataService \$(HTTPSERVERKIT_LIBS) \$(ODATAKIT_LIBS)
EOF
    pc httpserverkit "" "An HTTP server for APIs: a pipeline, a router, sign-in and observability" \
       "-I\${includedir} -I\${includedir}/HTTPServerKit $objc_flags $gnustep_flags" \
       "-L\${libdir} -lHTTPServerKit -ldispatch -lgnutls -lz $GNUSTEP_BASE_LIBS"
    pc odatakit "" "OData for Objective-C: what a client and a service share" \
       "-I\${includedir} -I\${includedir}/ODataKit $objc_flags $gnustep_flags" \
       "-L\${libdir} -lODataKit -lCoreData -ldispatch $GNUSTEP_BASE_LIBS"
    pc odataincrementalstore "odatakit" "A Core Data store over an OData service" \
       "-I\${includedir}/ODataIncrementalStore" "-L\${libdir} -lODataIncrementalStore"
    pc odataservice "odatakit httpserverkit" "A Core Data store served over OData, on its own or as an HTTPServerKit application's API" \
       "-I\${includedir}/ODataService" "-L\${libdir} -lODataService"
    ;;
  uninstall:libraries)
    rm -f "$fragments/httpserverkit.make" "$fragments/odatakit.make" "$pkgconfig/httpserverkit.pc" "$pkgconfig/odatakit.pc" \
      "$pkgconfig/odataincrementalstore.pc" "$pkgconfig/odataservice.pc"
    ;;
  *)
    echo "usage: install-build-files.sh install|uninstall libraries" >&2
    exit 2
    ;;
esac
