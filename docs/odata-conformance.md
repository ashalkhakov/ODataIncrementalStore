# OData v4 conformance

What ODataIncrementalStore must support to work against real OData v4
services, and where it stands. Section numbers refer to the OData 4.01
OASIS specifications:
[Part 1: Protocol](https://docs.oasis-open.org/odata/odata/v4.01/odata-v4.01-part1-protocol.html),
[Part 2: URL Conventions](https://docs.oasis-open.org/odata/odata/v4.01/odata-v4.01-part2-url-conventions.html),
[JSON Format](https://docs.oasis-open.org/odata/odata-json-format/v4.01/odata-json-format-v4.01.html).

The client targets **OData 4.0**: it sends `OData-MaxVersion: 4.0`, so
services answer in 4.0 and the 4.01-only client requirements (Part 1
§13.3, items 16–20) do not apply yet.

| Mark | Meaning |
|---|---|
| ✅ | Supported |
| ⚠️ | Partly supported, or works only in the common case |
| ❌ | Missing or broken |
| — | Out of scope, with the reason given |
| **live** | Checked against Microsoft's public reference services (Northwind v4, TripPin RW) on macOS and GNUstep |

## 1. Interoperable client requirements (Part 1 §13.3)

These are the spec's own list. Everything marked ❌ here is a blocker for
calling the client conformant.

| # | Requirement | Status | Notes |
|---|---|---|---|
| 1 | MUST send `OData-MaxVersion` | ✅ | `4.0` on every request. |
| 2 | MUST send `OData-Version` and `Content-Type` with a payload | ✅ | `OData-Version` on every request; `Content-Type` only with a body. |
| 3 | MUST be a conforming consumer of the JSON format | ⚠️ | See section 2. |
| 4 | MUST follow redirects (§9.1.5) | ✅ **live** | `NSURLSession` follows them, on Apple and on GNUstep, where the client uses it whenever gnustep-base was built with libcurl. TripPin's entry URL redirects with a relative `Location`. gnustep-base's `NSURLConnection`, the fallback, does not follow a relative `Location` (`NSURLProtocol` builds the new URL without the request URL, and the request times out); a fix belongs in gnustep-patches. |
| 5 | MUST handle next links (§11.2.6.7) | ✅ **live** | Followed, relative or absolute, for collections and to-many relationships, until the collection ends or `fetchLimit` is reached. Northwind pages at 20; all 77 products arrive. |
| 6 | MUST accept properties not in metadata (§11.2) | ✅ | Unknown properties are ignored. |
| 7 | MUST use PATCH for updates (§11.4.3) | ✅ | |
| 8 | MUST use the `$` prefix on system query options | ✅ | |
| 9 | MUST use case-sensitive options, operators, functions | ✅ | |
| 10 | SHOULD support Basic authentication over HTTPS | ✅ | Also Bearer tokens. |
| 11–15 | MAY: entity references, delta, async, `metadata=minimal`, streaming | — | Optional. The client asks for `metadata=minimal`; see 2.1. |

## 2. JSON format consumer (JSON Format §24)

| # | Requirement | Status | Notes |
|---|---|---|---|
| 1 | Understand `metadata=minimal`, or request `none` / `full` | ✅ | Requests `minimal`. Reads `@odata.etag`, `@odata.nextLink` and `@odata.editLink` (writes go to the edit link where one is given). `@odata.id` is not needed: the key is in the row. |
| 2 | Consume `metadata=full` responses | ✅ | Extra control information is ignored. |
| 3 | Receive every data type (§7.1) | ⚠️ **live** | Every primitive type the store can map; see section 5. Enumerations, complex types, collections and spatial types are not mapped. |
| 4 | Interpret control information per the payload's `OData-Version` | ⚠️ | Only `@odata.etag`, `@odata.nextLink` (not yet followed) and `value` matter today. |
| 5 | Accept unknown annotations and control information | ✅ | Ignored. |
| 6 | Not require `streaming=true` | ✅ | |
| 7a | Accept the `odata.` prefix on control information | ✅ | 4.0 payloads always carry it. |
| 7b | Accept `#` in `@odata.type` | — | `@odata.type` is not read yet; see 4.3. |
| 7c | Bind related entities with `@odata.bind` in POST / PATCH | ✅ | Inserts bind (`Nav@odata.bind`). Updates use the `$ref` operations instead; see 4.2. |
| 7e | Accept `-INF`, `INF`, `NaN` strings for Single and Double | ✅ | Read into Float and Double attributes, and written that way, since JSON has no NaN or infinity. |
| 7f | Property annotations before or after the property | ✅ | Ignored. |

## 3. Protocol behaviour (Part 1)

| Area | Section | Status | Notes |
|---|---|---|---|
| Service root and `$metadata` fetch | §11.1 | ✅ **live** | Requested as XML. (It used to be sent with a JSON `Accept`, and Northwind refused to open.) |
| `$metadata` use | §11.1.2 | ❌ | Fetched and discarded. The model is never checked against it, and entity sets, keys and types are not discovered from it. |
| Status codes and error bodies | §9, JSON §21 | ✅ **live** | The service's message is the `NSError`'s description; its code, target, details, the HTTP status and the body are in `userInfo` (`ODataErrorCodeKey` and friends). XML error bodies too, for `$metadata`. A `412` is `ODataIncrementalStoreErrorOptimisticLocking`, alone or inside a change set. |
| Errors surfaced from fetches | | ✅ **live** | A failed request fails the fetch with its `NSError`, for collections and relationships alike; it is never an empty result. |
| Content negotiation for `$count` | §11.2.10 | ✅ **live** | Requested as `text/plain`. |
| Server-driven paging | §11.2.6.7 | ✅ **live** | See 1.5. `$orderby` always ends with the key, because a service resumes a page after its last row's sort values: sorted by category name alone, Northwind skips 17 of 77 products. |
| `Prefer: odata.maxpagesize` | §8.2.8.3 | ✅ | From `fetchBatchSize`. |
| `Prefer: return=representation` | §8.2.8.7 | ✅ | Sent with entity POSTs and PATCHes. A `204` anyway: the new entity is read from `Location` (or `OData-EntityId`), a new ETag from the `ETag` header. |
| Create | §11.4.2 | ✅ **live** | Keys go in the body when the client set them (non-zero, non-empty), so TripPin's `UserName` works and server-assigned integer keys stay unset. |
| Update | §11.4.3 | ✅ **live** | PATCH with the changed attributes; relationships per 4.2. |
| Delete | §11.4.5 | ✅ | |
| ETags / optimistic concurrency | §11.4.1.1 | ✅ **live** | Kept exactly as sent (`@odata.etag` or the `ETag` header) and sent back in `If-Match`; none is sent when the service gave none. A write's response updates it, and after `$ref` requests the entity is read back, since they can change the ETag without returning it. A changed ETag bumps the node version, so Core Data sees a conflict before the service does. |
| Relationship changes (`@odata.bind`, `$ref`) | §11.4.2.2, §11.4.6 | ✅ **live** | See 4.2. |
| Atomic saves (`$batch` change sets) | §11.7 | ✅ **live** | A save of two or more requests is one multipart change set, with absolute URLs (TripPin rejects relative ones in a batch). A service that refuses `$batch` (400, 404, 405, 415 or 501 to the batch request) gets the requests one at a time from then on; any other failure fails the save, since TripPin shows a service can apply part of a batch and then answer 500. Inserts whose keys the service assigns are posted before the rest, because Core Data needs their object IDs first; assign keys on the client (`postOnObtainPermanentIDs` off) for a save that is atomic whole. `ODataIncrementalStoreBatchSavesOption` turns batching off. |
| Redirects | §9.1.5 | ⚠️ | See 1.4. |
| Key-as-segment URLs (`Products/1`) | §4.3.6 | ❌ | Parentheses only. Needed only where a service requires it. |
| Percent-encoding of key values in paths | Part 2 §4.3.1 | ✅ | Everything but what a path segment allows and OData's key syntax uses: `Customers('Smith%20%26%20Co%2F2')`. |
| Deep insert | §11.4.2.2 | — | Optional. `$batch` covers the same need. |
| Delta, async, streams, actions, functions | | — | No Core Data equivalent in a fetch or save. |

## 4. Core Data mapping

### 4.1 Fetching

| Core Data | OData | Status | Notes |
|---|---|---|---|
| Fetch an entity | `GET EntitySet` | ✅ **live** | Every page. |
| Fault an object | `GET EntitySet(key)` | ✅ **live** | |
| `predicate` | `$filter` | ⚠️ | See 4.4. |
| `sortDescriptors` | `$orderby` | ✅ **live** | Paths through relationships use `/` (`Category/CategoryName`); the key is appended as a tiebreaker. |
| `fetchLimit`, `fetchOffset` | `$top`, `$skip` | ✅ **live** | |
| `countForFetchRequest:` | `/$count` | ✅ **live** | |
| `propertiesToFetch` (dictionary results) | `$select` | ⚠️ | Only for `NSDictionaryResultType`. Could also trim managed-object fetches. |
| `relationshipKeyPathsForPrefetching` | `$expand` | ⚠️ | Inline entities are cached, and a to-one's object ID goes in the row. A prefetched to-many's membership is not, so reading the relationship is still a request. |
| `fetchBatchSize` | `Prefer: odata.maxpagesize` | ❌ | |
| To-one fault | `GET Entity(key)/Nav` | ✅ **live** | |
| To-many fault | `GET Entity(key)/Nav` | ✅ **live** | Every page; the rows are cached. |
| Firing faults | | ✅ | Every fetched row is cached, and each to-one relationship is expanded to its key (`Nav($select=Key)`), because Core Data asks for every to-one as soon as a fault fires. Firing N faults used to cost N or 2N requests; it costs none. Northwind ignores the nested `$select` and sends the whole related entity, which is cached as well. |
| Refreshing | | ✅ | Every fetch and relationship read refreshes the rows it returns. `-discardCachedRowsForObjectIDs:` drops kept rows, so the next fault reads the service; `refreshObject:mergeChanges:` alone refills from what the store kept. Core Data asks the store for a row during every save, so rows cannot simply expire after one use. |

### 4.2 Saving

| Core Data | OData | Status | Notes |
|---|---|---|---|
| Insert | `POST EntitySet` | ✅ **live** | New objects are posted each after the new objects they refer to, so a new Product can bind to a new Category in the same save; a cycle is closed by a `$ref` after the inserts. |
| Update attributes | `PATCH Entity(key)` | ✅ **live** | |
| Update a to-one relationship | `PUT Entity(key)/Nav/$ref`; `DELETE` it to clear | ✅ **live** | Not a bind in the PATCH: TripPin answers `204` to one and ignores it. |
| Update a to-many relationship | `POST` / `DELETE Entity(key)/Nav/$ref?$id=…` | ✅ **live** | Written from one side only: never from a to-many whose inverse is to-one (that side's reference says it), and for many-to-many from the side whose entity name sorts first. |
| Insert with relationships | `POST` with `@odata.bind` | ✅ | The only way to create an entity whose relationship is required. TripPin answers `500` to a POST with binds, in breach of JSON Format §24 item 7c. |
| Delete | `DELETE Entity(key)` | ✅ | |
| Save atomicity | `$batch` change set | ✅ **live** | See section 3. |
| Merge conflicts | `412` → `NSMergeConflict` | ⚠️ | `412` becomes an error, but not one Core Data's merge policies understand. |

### 4.3 Model

| Feature | Status | Notes |
|---|---|---|
| Entity set names from `userInfo` or by pluralising | ✅ | |
| Property names from `userInfo` or PascalCase | ✅ | |
| Single and compound keys | ✅ | |
| Key discovery from `$metadata` | ❌ | Keys come from `userInfo` or an `id` / `<Entity>ID` attribute. |
| Derived types (`@odata.type`, type casts) ↔ sub-entities | ❌ | |
| Complex types | ❌ | No Core Data equivalent short of flattening or a transformable. |
| Collections of primitives | ❌ | Same. |
| Enumeration types | ❌ | Filters also need the qualified literal form `Ns.Enum'Member'`. |

### 4.4 Predicates → `$filter` (Part 2 §5.1.1)

| `NSPredicate` | `$filter` | Status | Notes |
|---|---|---|---|
| `==`, `!=`, `<`, `<=`, `>`, `>=` | `eq`, `ne`, `lt`, `le`, `gt`, `ge` | ✅ | |
| `AND`, `OR`, `NOT` | `and`, `or`, `not` | ✅ | |
| `IN` | `in` | ✅ | |
| `BETWEEN` | `ge` … `and` … `le` | ✅ | gnustep-base rewrites it before translation. |
| `BEGINSWITH`, `ENDSWITH`, `CONTAINS` | `startswith`, `endswith`, `contains` | ✅ | |
| `[c]` | `tolower(…)` on both sides | ✅ | |
| `[d]` | | ❌ | Ignored silently. OData has no diacritic-insensitive comparison, so this should be an error. |
| `lowercase:`, `uppercase:` | `tolower`, `toupper` | ✅ | |
| `nil` | `null` | ✅ | |
| Key paths through to-one relationships | `Nav/Prop` | ✅ | |
| `rel == %@`, `!=`, `IN` with managed objects or object IDs | `Nav/Key eq …`, `not (…)`, `Nav/Key in (…)` | ✅ **live** | Compares keys through the to-one path; a compound key compares each part. An unsaved object is an error. |
| `self == %@`, `self IN %@` | `Key eq …`, `Key in (…)` | ✅ | Inside a lambda, against the lambda variable. |
| `ANY` / `ALL` on to-many | `Nav/any(x0:…)`, `Nav/all(x0:…)` | ✅ **live** | Split at the first to-many step; a further to-many step nests another lambda. `ANY` over a to-one path is the plain comparison. |
| `SUBQUERY(…).@count` | `Nav/any(…)`, `Nav/$count` | ❌ | |
| `rel.@count` | `Nav/$count` | ❌ | |
| `LIKE`, `MATCHES` | `matchesPattern` (4.01 only) | — | Not expressible in 4.0. Should be an error, and is. |
| Arithmetic (`+ - * /`, `modulus:by:`) | `add`, `sub`, `mul`, `div`, `mod` | ❌ | |
| Date literals | `2024-01-01T12:00:00.5Z`, `2024-01-01` | ✅ **live** | Typed by the attribute compared with: a DateTimeOffset to the microsecond, an `Edm.Date` as the day. |
| UUID literals | unquoted Guid | ✅ | |
| Decimal and Int64 literals | `32.38`, `639260022539945567` | ✅ **live** | Every digit, never an exponent (gnustep-base writes `1E-10` for a small `NSDecimalNumber`; the literal is `0.0000000001`). A Boolean attribute compared with `@0` is `false`. |

## 5. Data types (JSON Format §7.1)

| Edm type | Core Data | Status | Notes |
|---|---|---|---|
| `Boolean` | Boolean | ✅ **live** | |
| `Byte`, `SByte`, `Int16`, `Int32` | Integer 16/32 | ✅ | |
| `Int64` | Integer 64 | ✅ **live** | The store asks for `IEEE754Compatible=true` (JSON Format §3.2), so Int64 travels as a string both ways and keeps every digit: TripPin's `Concurrency`, past 2^53, reads exactly. Numbers are read too. `ODataIncrementalStoreIEEE754CompatibleOption` turns the parameter off for a service that rejects it. An Int64 key read as `"1"` is the same object as `1`. |
| `Decimal` | Decimal | ✅ **live** | As Int64: a string both ways (`"32.3800"`), exact, and never written with an exponent. |
| `Single`, `Double` | Float, Double | ✅ | Including `INF`, `-INF`, `NaN`. Literals are the shortest exact form (`0.1`). |
| `String` | String | ✅ | |
| `DateTimeOffset` | Date | ✅ **live** | Any fraction and any offset read (`2024-03-01T14:34:56.1234567+02:00`); written in UTC to the microsecond. Parsed and written without `NSDateFormatter`, so both platforms agree whatever the locale. A value that is not a date is left out of the row rather than stored as a string. |
| `Date` | Date with `OData.type` `Edm.Date` | ✅ | Midnight UTC of the day, written back as the day. Without `OData.type` a Date attribute is a DateTimeOffset; step 5 learns this from `$metadata` instead. |
| `TimeOfDay`, `Duration` | String / Double with `OData.type` | ✅ | `TimeOfDay` stays a string (`13:20:00`) with an unquoted literal; `Duration` is seconds in a Double (`P1DT2H3M4.5S` is 93784.5), written `PT93784.5S`, with the literal `duration'…'`. |
| `Guid` | UUID, or String with `OData.type` `Edm.Guid` | ✅ | Unquoted in literals and in key paths. |
| `Binary` | Binary Data | ✅ **live** | Written as base64url, the spec's form; both base64url and plain base64 read, since Northwind sends plain base64. Literal `binary'…'`. |
| `Stream`, media entities | | — | |
| Geography, geometry | | — | |
| Enumerations | | ❌ | See 4.3. |

## 6. Transport and platforms

| Area | Status | Notes |
|---|---|---|
| HTTPS | ✅ **live** | `NSURLSession`, on Apple and on GNUstep (libcurl, gnutls). gnustep-base's `NSURLConnection` is only the fallback for a gnustep-base built without libcurl: besides relative redirects, it returns an empty body for a multipart response, which every `$batch` answer is. |
| Basic and Bearer authentication | ✅ | Static credentials; no token refresh hook. |
| Timeouts | ✅ | |
| SAP Gateway CSRF token | ❌ | Vendor-specific: fetch `X-CSRF-Token` before writes. Needed only for SAP services. |
| Tests that exercise headers | ✅ | The snapshot transport refuses what a service would: no `OData-MaxVersion`, a body without a JSON `Content-Type` or `OData-Version`, an `Accept` that rules out the response (`406`). |
| Live smoke test in CI | ✅ | `Tests/Live/ois-live` reads Northwind and writes to TripPin, in a session of its own, on both platforms in CI, reported without failing the build. |

## 7. XML format (Atom)

Needed later for XForms 1.1, whose instance data is XML.

OData v4 defines two separate XML formats, and they have different
standing:

- **CSDL XML** is the `$metadata` document. It is part of the OData 4.0
  and 4.01 OASIS Standards, and every service provides it. The client
  already downloads it and does not parse it; see section 3.
- **The Atom format** (`application/atom+xml`) carries entities, feeds and
  errors as XML. It is specified in
  [OData Atom Format Version 4.0](https://docs.oasis-open.org/odata/odata-atom-format/v4.0/cs02/odata-atom-format-v4.0-cs02.html),
  which stopped at Committee Specification 02 in November 2013: it never
  became an OASIS Standard, and there is no 4.01 version. Part 1 §13.3
  requires clients to speak JSON only.

Server support is split along the same line. Microsoft's WCF Data Services
stack serves Atom: Northwind answers `Accept: application/atom+xml` with a
feed (**live**). The newer ODataLib / ASP.NET OData stack does not: TripPin
answers `415` (**live**). Northwind also answers `415` to
`Accept: application/xml` for a feed, so the media type has to be exact.

That gives XForms two routes, which can coexist:

1. **Map JSON to XML on the client.** The store and the wire stay JSON,
   and the XForms layer builds its instance from the managed objects, or
   from the JSON, and back again. This works with every OData v4 service.
2. **Speak Atom to services that offer it.** A second payload format in the
   client, used only where a service advertises it.

Route 1 needs nothing from this client beyond what the sections above
already require. Route 2 is the checklist below. Both platforms can do the
parsing: `NSXMLParser` and `NSXMLDocument` exist on Apple and in
gnustep-base (through libxml2).

| Area | Atom §§ | Status | Notes |
|---|---|---|---|
| Content negotiation: `Accept: application/atom+xml`, fall back to JSON on `406` / `415` | §3, §4.1 | ❌ | |
| Service document (`app:service`, `app:collection`) | §5 | ❌ | Lists the entity sets; optional for the store. |
| Entity (`atom:entry`, `atom:id`, `atom:category` for the type, `atom:link rel="edit"`) | §6 | ❌ | |
| ETag (`metadata:etag` on the entry) | §6.1.1 | ❌ | Same rules as JSON: keep it verbatim. |
| Properties (`metadata:properties`, `data:Name`, `metadata:type`, `metadata:null`) | §7.1–7.4 | ❌ | Values use the same ABNF literals as the JSON format's strings, so the type work in section 5 carries over. |
| Complex properties and collections (`metadata:element`) | §7.5–7.7 | ❌ | Same model gap as JSON; see 4.3. |
| Navigation links, association links | §8.1–8.2 | ❌ | |
| Expanded navigation (`metadata:inline`) | §8.3 | ❌ | |
| Bind operations in POST / PATCH | §8.5 | ❌ | Same need as `@odata.bind`. |
| Feeds (`atom:feed`, `metadata:count`, `atom:link rel="next"`) | §12 | ❌ | Next links: same paging rules as JSON. |
| Entity references (`metadata:ref`) | §13 | ❌ | For `$ref` relationship updates. |
| Individual property values (`metadata:value`) | §11 | — | Not used by the store. |
| Errors (`metadata:error`, `code`, `message`, `details`, `innererror`) | §19 | ❌ | |
| Request bodies in Atom (POST, PATCH) | §6, §8.4–8.5 | ❌ | |
| Stream properties, media entities | §9–10 | — | As for JSON. |
| Delta responses, bound functions and actions, instance annotations | §14–18 | — | As for JSON. |

For the server described in [server-design.md](server-design.md), Atom is
an output format like any other, and serving it would give XForms clients
route 2 against our own services, whatever third-party services do.

## Order of work

1. ~~**Can connect and read correctly:** request headers, errors from
   fetches, next links (collections and to-many), `$orderby` through
   relationships, managed objects in predicates, `ANY` / `ALL`. Make the
   snapshot transport check headers, and add the live smoke test.~~
   Done.
2. ~~**Can write correctly:** keep the real ETag and send it back unchanged
   (and send none when there is none); send relationships with
   `@odata.bind`; `Prefer: return=representation`; client-supplied keys
   in POST.~~ Done.
3. ~~**Types:** `DateTimeOffset` in full, `Date`, `IEEE754Compatible` for
   Int64 and Decimal, `INF` / `NaN`, Binary.~~ Done, with `TimeOfDay` and
   `Duration` as well.
4. ~~**Robustness:** `$batch` change sets for atomic saves, OData error
   bodies, percent-encoded keys, `@odata.editLink`, cache refresh,
   `Prefer: odata.maxpagesize` from `fetchBatchSize`.~~ Done.
5. **Model:** read `$metadata`: validate the Core Data model against it,
   discover keys, then derived types and enums.
6. **XML, for XForms:** JSON-to-XML mapping on the client first, since it
   works with every service; then Atom as a second wire format where a
   service offers it (section 7). Parsing CSDL XML in step 5 builds the
   XML reading this needs.
