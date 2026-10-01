# GCDWebServer, vendored and ported

- Upstream: https://github.com/swisspol/GCDWebServer
- Tag: `3.5.4`
- Commit: `1c36bf07c848476111d523057a3a63b05328ce2a`
- License: BSD-3-Clause, see `LICENSE` (the upstream file, unchanged)

Only `GCDWebServer/Core`, `GCDWebServer/Requests` and `GCDWebServer/Responses`
are vendored. GCDWebDAVServer, GCDWebUploader, the apps, the tests and the Xcode
project are not.

The port builds with ARC on macOS (Apple Foundation) and on GNUstep on Linux
(clang, libobjc2 with the gnustep-2.0 runtime, gnustep-base, libdispatch).
Design and rationale: `docs/server-design.md`, "The HTTP adapter".

## Files

- `Core/`, `Requests/`, `Responses/`: upstream sources with the changes below.
- `Core/GCDWebServerHTTPMessage.{h,m}`: new, replaces CFHTTPMessage (private).
- `upstream.diff`: `diff -ruN` of the three directories, upstream against ported.
- `GCDWebServer.make`: source list, include dirs, flags and libraries for a
  gnustep-make target at the repository root.
- `GNUmakefile`: builds and runs the smoke test, with gnustep-make or plain clang.
- `Tests/gws-smoke.m`: smoke test over plain BSD sockets.
- `Tests/gws-cfcompare.m`: macOS only; compares the CFHTTPMessage replacement
  with CFNetwork.

## Updating to a new upstream release

1. Copy the new release's `Core`, `Requests` and `Responses` over these.
2. `patch -p1 < upstream.diff` from this directory, and fix the rejects.
3. Regenerate `upstream.diff` against the new pristine release, and run
   `make check` on macOS and on GNUstep.

Changes are marked `ODataStore port` in comments, or sit in the guards named below.

## Changes

HTTP message parsing and serialisation:

- CFHTTPMessage replaced by `GCDWebServerHTTPMessage`: incremental request-head
  parser (request line, header fields, CRLFCRLF) and response-head writer.
- Header names keep their wire spelling; lookups are case-insensitive
  (`GCDWebServerHeaderDictionary`). CFHTTPMessage canonicalised the common
  names instead; upstream's `objectForKey:@"Content-Type"` lookups still work.
- Repeated request header fields are joined with ", ", as CFHTTPMessage did.
- Rejected with 400: bare CR or LF, obs-fold, whitespace before the colon,
  control characters in values, malformed request line, an undecodable
  request target, conflicting or non-numeric Content-Length, and
  Content-Length together with Transfer-Encoding. Transfer-Encoding other than
  `chunked` gets 501; an HTTP major version other than 1 gets 505. Upstream
  answered most of these with 500, or not at all.
- Status lines use the RFC 9110 reason phrases (CFHTTPMessage's table was
  older, e.g. 431 was "Bad Request"). CR/LF in response header values are
  replaced by spaces.
- The request URL is built as CFHTTPMessageCopyRequestURL() did: relative to
  `http://<Host>/` (or `fake://host/` without Host); characters not allowed
  in URLs are percent-escaped, existing escapes are kept.
- `CFURLCopyPath()` / `CFURLCopyQueryString()` became
  `GCDWebServerCopyURLPath()` / `GCDWebServerCopyURLQueryString()`, which split
  the URL's own string, so escapes, trailing slashes and `;params` survive as
  before. `/svc/Products(1)?$filter=Name%20eq%20'x'` gives path
  `/svc/Products(1)` and query `$filter=Name%20eq%20'x'` on both platforms.
- `GCDWebServerEscapeURLString()` / `GCDWebServerUnescapeURLString()` use
  Foundation; unescaping is strict (a bad escape or invalid UTF-8 gives nil)
  because GNUstep's `-stringByRemovingPercentEncoding` is lenient.

`Tests/gws-cfcompare.m` (`make cfcompare`, macOS only) checks this against
CFHTTPMessage and CFURL for 17 request targets, with and without Host: method,
URL, path, query, header lookup and unescaping all match.

Platform:

- `TargetConditionals.h` only on Apple; elsewhere `TARGET_OS_IPHONE`,
  `TARGET_IPHONE_SIMULATOR` and `TARGET_OS_TV` are defined to 0.
- `CFUUID` → `NSUUID` (only in the compiled-out digest nonce).
- `CFSocketNativeHandle` → `GCDWebServerSocketHandle` (`int`).
- `sin_len`, `sin6_len`, `sa_len` only on Apple; elsewhere the length comes
  from the address family.
- `st_mtimespec` → `st_mtim` off Apple (File response Last-Modified and ETag).
- `SO_NOSIGPIPE` where it exists. Elsewhere `-startWithOptions:error:`
  sets SIGPIPE to SIG_IGN if it is still SIG_DFL: libdispatch does the writes,
  so `MSG_NOSIGNAL` is not an option. A handler the application installed is
  left alone.
- MIME types: UTType on Apple (deprecation warning silenced); elsewhere a small
  table (json, xml, txt, html, css, js, csv, png, jpg, gif, svg, ico, pdf, zip),
  `application/octet-stream` otherwise.
- Charset names: CFStringConvertIANACharSetNameToEncoding on Apple; elsewhere a
  table of the common IANA names, UTF-8 otherwise.
- Primary IP address (`serverURL` when not bound to localhost): SystemConfiguration
  on Apple; elsewhere the first interface that is up and not loopback.
- The disconnect-coalescing timer is a dispatch source on the main queue
  instead of a CFRunLoopTimer (all platforms).
- `-runWithOptions:` and its helper use NSRunLoop instead of CFRunLoop off Apple.
- The typed `NSDictionary<NSString*, NSString*>*` for Basic auth accounts,
  which GNUstep's block signature for `-enumerateKeysAndObjectsUsingBlock:` needs.

Compiled out (`__GCDWEBSERVER_ENABLE_BONJOUR_NAT__`,
`__GCDWEBSERVER_ENABLE_DIGEST_AUTH__`, both 0 in `GCDWebServerPrivate.h`; the
code is kept only to keep this diff small):

- Bonjour (CFNetService) and NAT port mapping (dns_sd). The options are accepted
  and ignored; `bonjourName`, `bonjourType`, `bonjourServerURL` and
  `publicServerURL` return nil; the delegate callbacks never fire.
- Digest authentication (CommonCrypto MD5). Asking for it makes
  `-startWithOptions:error:` fail instead of running unauthenticated. Basic
  authentication still works.
- iOS background suspension stays under `TARGET_OS_IPHONE`, which is 0 on both
  supported platforms. iOS is not a target of the port.
- The `__GCDWEBSERVER_ENABLE_TESTING__` recording and replay code still uses
  CFHTTPMessage and builds on Apple only. It was never enabled here.

Logging:

- The built-in logger is the default on both platforms, at level Warning
  (upstream: Info, or Debug with `DEBUG`). It logs with NSLog, also when stderr
  is not a terminal (upstream logged only to a tty). `+setLogLevel:` and
  `+setBuiltInLogger:` work as before.

Added:

- `GCDWebServerOption_MaxHeadSize` (default 64 KiB): larger request heads get 431.
- `GCDWebServerOption_MaxBodySize` (default 64 MiB, 0 means no limit): a larger
  Content-Length gets 413 before the body is read (also before
  `100 Continue`); a chunked body gets 413 as soon as a chunk size goes over.
- `GCDWebServerOption_ReadTimeout` (default 60 s, 0 disables): the time from
  accept to the end of the request body. When it runs out the read side is
  shut down and the server answers 408.
- Chunked bodies: the chunk-size line is limited to 4 KiB and the trailer
  section to the head size limit.

Fixed along the way:

- A chunked body whose last chunk and trailer arrived in separate reads spun
  forever re-scanning the same bytes; now it waits for more data.
- A request body that could not be read completely (client gone, timeout,
  bad chunk) was still passed to the handler, truncated. Now the request is
  aborted with 400, 408 or 413.
- A request path that does not unescape (`/%FF`) got 500 and, in `DEBUG`
  builds, `abort()`. Now it gets 400.
- The socket is closed as soon as the last byte of the response is written
  (`-_finish`), rather than when the connection object is deallocated.
  `-close` and the delegate's disconnect bookkeeping run at the same point.
- Listening on every address (not bound to localhost) failed on Linux: the
  IPv6 wildcard socket also takes IPv4 there unless `IPV6_V6ONLY` is set,
  so binding it after the IPv4 one gave EADDRINUSE. The IPv6 socket is now
  IPv6 only. A host without IPv6 (EAFNOSUPPORT, EPROTONOSUPPORT,
  EADDRNOTAVAIL, as in many containers) is served over IPv4 alone instead
  of failing to start.

## libobjc2 and stack blocks

libobjc2's `objc_retain()` copies a stack block to the heap and returns the
copy (`retain()` in `arc.mm` calls `Block_copy` on any block); Apple's
runtime returns a stack block unchanged. LLVM's ARC optimiser treats
`objc_retain` as returning its argument, so at `-O1` and above (and
`gnustep-config --objc-flags` says `-O2`) the result goes unused: the retain
ARC makes of a block parameter creates a heap copy that nothing refers to,
the matching release goes to the stack block, which the runtime ignores,
and the copy leaks along with everything it captured. It shows whenever a
block literal is passed to a function or method that captures the
parameter in another block (a completion handler, `dispatch_async`). Seen
with clang 18.1.3 and libobjc2 v2.2-92-gaca3916 in the `ois-dev`
container; macOS is not affected. For GCDWebServer the leaked object was
the connection: its socket stayed open until the client hung up.

Workaround here: every method that takes a block and keeps or captures it
starts with `block = [block copy];`, so what it captures is already a heap
block, which is retained in place. The smoke test's `no-leaked-connections`
check counts live connection objects.

The fix belongs in libobjc2: `retain()` should return a stack block
unchanged and leave moving it to the heap to `objc_retainBlock()`. It is
`libobjc2/stack-block-retain` in gnustep-patches. Until the runtime carries it, application code built on
this toolchain that captures block parameters in other blocks leaks too.

## Behaviour that differs from upstream

- The header dictionary implements fast enumeration itself: gnustep-base
  leaves `-countByEnumeratingWithState:objects:count:` to `NSDictionary`'s
  subclasses, so `for (name in request.headers)` raised on GNUstep.
- Header dictionaries keep wire spelling instead of CFHTTPMessage's
  canonical names (lookups are case-insensitive, so upstream code is unaffected).
- `-[NSURL absoluteString]` of the request URL can differ between macOS and
  GNUstep for odd targets (`//`, `/a?`). Path and query, which the server uses,
  do not.
- Stricter parsing, the new limits and the status codes listed above.
- Keep-alive is still not supported (`Connection: Close`), as upstream.
