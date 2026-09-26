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
| 2 | MUST send `OData-Version` and `Content-Type` with a payload | ✅ | Sent on every request. `Content-Type` on a GET is harmless but should be dropped. |
| 3 | MUST be a conforming consumer of the JSON format | ⚠️ | See section 2. |
| 4 | MUST follow redirects (§9.1.5) | ⚠️ | Left to `NSURLSession` / `NSURLConnection`. GET redirects work; 307/308 on PATCH, POST and DELETE are untested on GNUstep. |
| 5 | MUST handle next links (§11.2.6.7) | ❌ **live** | `@odata.nextLink` is ignored. Northwind pages at 20, so a fetch of its 77 products returns 20, with no error. |
| 6 | MUST accept properties not in metadata (§11.2) | ✅ | Unknown properties are ignored. |
| 7 | MUST use PATCH for updates (§11.4.3) | ✅ | |
| 8 | MUST use the `$` prefix on system query options | ✅ | |
| 9 | MUST use case-sensitive options, operators, functions | ✅ | |
| 10 | SHOULD support Basic authentication over HTTPS | ✅ | Also Bearer tokens. |
| 11–15 | MAY: entity references, delta, async, `metadata=minimal`, streaming | — | Optional. The client asks for `metadata=minimal`; see 2.1. |

## 2. JSON format consumer (JSON Format §24)

| # | Requirement | Status | Notes |
|---|---|---|---|
| 1 | Understand `metadata=minimal`, or request `none` / `full` | ⚠️ | Requests `minimal`. Reads `@odata.etag`. Ignores `@odata.id` and `@odata.editLink`, so a service whose edit links do not follow the key convention is addressed wrongly. |
| 2 | Consume `metadata=full` responses | ✅ | Extra control information is ignored. |
| 3 | Receive every data type (§7.1) | ⚠️ | See section 5. Dates, Int64 and Decimal precision, and `INF` / `NaN` are the gaps. |
| 4 | Interpret control information per the payload's `OData-Version` | ⚠️ | Only `@odata.etag`, `@odata.nextLink` (not yet followed) and `value` matter today. |
| 5 | Accept unknown annotations and control information | ✅ | Ignored. |
| 6 | Not require `streaming=true` | ✅ | |
| 7a | Accept the `odata.` prefix on control information | ✅ | 4.0 payloads always carry it. |
| 7b | Accept `#` in `@odata.type` | — | `@odata.type` is not read yet; see 4.3. |
| 7c | Bind related entities with `@odata.bind` in POST / PATCH | ❌ | Relationship changes are never sent; see 4.2. |
| 7e | Accept `-INF`, `INF`, `NaN` strings for Single and Double | ❌ | The string is stored as-is in a numeric attribute. |
| 7f | Property annotations before or after the property | ✅ | Ignored. |

## 3. Protocol behaviour (Part 1)

| Area | Section | Status | Notes |
|---|---|---|---|
| Service root and `$metadata` fetch | §11.1 | ❌ **live** | The client asks for XML, but the shared header code overwrites `Accept` with JSON. Northwind answers `415`, so **the store cannot be opened**. |
| `$metadata` use | §11.1.2 | ❌ | Fetched and discarded. The model is never checked against it, and entity sets, keys and types are not discovered from it. |
| Status codes and error bodies | §9, JSON §21 | ⚠️ | Non-2xx becomes an `NSError`, but the OData error JSON is not parsed into code and message. |
| **Errors surfaced from fetches** | | ❌ **live** | A failed collection fetch returns an empty array. On Apple's Core Data a rejected query looks like "no rows". |
| Content negotiation for `$count` | §11.2.10 | ❌ **live** | Same header bug: `Accept: text/plain` is overwritten, and Northwind answers `415`. |
| Server-driven paging | §11.2.6.7 | ❌ **live** | See 1.5. Also applies to to-many navigation. |
| `Prefer: odata.maxpagesize` | §8.2.8.3 | ❌ | Would let `fetchBatchSize` shape pages. |
| `Prefer: return=representation` | §8.2.8.7 | ❌ | POST parses the body for the new key. A service that answers `204` with a `Location` header breaks inserts. |
| Create | §11.4.2 | ⚠️ | POST works when the service returns the entity. Keys the client must supply (string keys like TripPin's `UserName`) are omitted from the body. |
| Update | §11.4.3 | ⚠️ | PATCH sends changed attributes only; see 4.2. |
| Delete | §11.4.5 | ✅ | |
| **ETags / optimistic concurrency** | §11.4.1.1 | ❌ **live** | The client keeps only the digits of an ETag and sends back `W/"<digits>"`. TripPin answers `412` for every update or delete of an entity with an ETag; the real ETag is accepted. Objects with no ETag get an invented `W/"1"`. |
| Relationship changes (`@odata.bind`, `$ref`) | §11.4.2.2, §11.4.6 | ❌ | Setting or clearing a relationship is never sent. |
| Atomic saves (`$batch` change sets) | §11.7 | ❌ | One request per object. A failure part-way leaves the service partly updated. |
| Redirects | §9.1.5 | ⚠️ | See 1.4. |
| Key-as-segment URLs (`Products/1`) | §4.3.6 | ❌ | Parentheses only. Needed only where a service requires it. |
| Percent-encoding of key values in paths | Part 2 §4.3.1 | ❌ | A string key with a space, `/`, `#` or non-ASCII text makes an invalid URL. |
| Deep insert | §11.4.2.2 | — | Optional. `$batch` covers the same need. |
| Delta, async, streams, actions, functions | | — | No Core Data equivalent in a fetch or save. |

## 4. Core Data mapping

### 4.1 Fetching

| Core Data | OData | Status | Notes |
|---|---|---|---|
| Fetch an entity | `GET EntitySet` | ⚠️ **live** | First page only. |
| Fault an object | `GET EntitySet(key)` | ✅ **live** | |
| `predicate` | `$filter` | ⚠️ | See 4.4. |
| `sortDescriptors` | `$orderby` | ⚠️ **live** | Attributes work. A path through a relationship (`category.name`) becomes `Category.name`, which is a type cast; should be `Category/CategoryName`. Northwind answers `400`. |
| `fetchLimit`, `fetchOffset` | `$top`, `$skip` | ✅ **live** | |
| `countForFetchRequest:` | `/$count` | ❌ **live** | Header bug; correct after the fix. |
| `propertiesToFetch` (dictionary results) | `$select` | ⚠️ | Only for `NSDictionaryResultType`. Could also trim managed-object fetches. |
| `relationshipKeyPathsForPrefetching` | `$expand` | ⚠️ | Requested, then the inline entities are thrown away. Every relationship access is another request. |
| `fetchBatchSize` | `Prefer: odata.maxpagesize` | ❌ | |
| To-one fault | `GET Entity(key)/Nav` | ✅ **live** | |
| To-many fault | `GET Entity(key)/Nav` | ⚠️ | First page only. Rows are not cached, so each object faults again. |
| Refreshing | | ❌ | Cached rows are never refreshed for the life of the store. |

### 4.2 Saving

| Core Data | OData | Status | Notes |
|---|---|---|---|
| Insert | `POST EntitySet` | ⚠️ | See Create above. |
| Update attributes | `PATCH Entity(key)` | ⚠️ | Broken by ETags where the service uses them. |
| Update a to-one relationship | `PATCH` with `Nav@odata.bind`, or `PUT Entity(key)/Nav/$ref` | ❌ | |
| Update a to-many relationship | `POST` / `DELETE Entity(key)/Nav/$ref` | ❌ | |
| Insert with relationships | `POST` with `@odata.bind` | ❌ | Relationships are dropped. |
| Delete | `DELETE Entity(key)` | ✅ | |
| Save atomicity | `$batch` change set | ❌ | |
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
| `rel == %@` with a managed object | `Nav/Key eq …` | ❌ **live** | The object's `description` is written into the URL. Northwind answers `500`. |
| `self == %@`, `self IN %@` | key comparison | ❌ | Same root cause. |
| `ANY` / `ALL` on to-many | `any()` / `all()` | ❌ **live** | The modifier is dropped. |
| `SUBQUERY(…).@count` | `Nav/any(…)`, `Nav/$count` | ❌ | |
| `rel.@count` | `Nav/$count` | ❌ | |
| `LIKE`, `MATCHES` | `matchesPattern` (4.01 only) | — | Not expressible in 4.0. Should be an error, and is. |
| Arithmetic (`+ - * /`, `modulus:by:`) | `add`, `sub`, `mul`, `div`, `mod` | ❌ | |
| Date literals | `2024-01-01T00:00:00Z` | ⚠️ | Whole seconds only. |
| UUID literals | unquoted Guid | ✅ | |
| Decimal and Int64 literals | | ⚠️ | Written through `stringValue`, which can use exponent notation for large or tiny decimals. |

## 5. Data types (JSON Format §7.1)

| Edm type | Core Data | Status | Notes |
|---|---|---|---|
| `Boolean` | Boolean | ✅ **live** | |
| `Byte`, `SByte`, `Int16`, `Int32` | Integer 16/32 | ✅ | |
| `Int64` | Integer 64 | ⚠️ | Parsed by `NSJSONSerialization`. Values past 2^53 may lose precision on some Foundations; `IEEE754Compatible=true` makes the service send them as strings, which would then need coercion. |
| `Decimal` | Decimal | ⚠️ | Arrives as a JSON number, parsed through `double`. Precision loss beyond about 15 digits. Same `IEEE754Compatible` fix. |
| `Single`, `Double` | Float, Double | ⚠️ | `INF`, `-INF`, `NaN` strings are not converted. |
| `String` | String | ✅ | |
| `DateTimeOffset` | Date | ⚠️ | Parses `yyyy-MM-ddTHH:mm:ssZ` only. Fractional seconds (up to 12 digits) and offsets like `+02:00` fail, and the raw string ends up in a Date attribute. Writes drop sub-second precision. |
| `Date` | Date | ❌ | `2024-01-01` is not parsed. |
| `TimeOfDay`, `Duration` | | ❌ | No mapping. `Duration` could map to a Double of seconds. |
| `Guid` | UUID | ✅ | |
| `Binary` | Binary Data | ❌ | Base64url strings are not decoded or encoded. |
| `Stream`, media entities | | — | |
| Geography, geometry | | — | |
| Enumerations | | ❌ | See 4.3. |

## 6. Transport and platforms

| Area | Status | Notes |
|---|---|---|
| HTTPS | ✅ **live** | `NSURLSession` on Apple, `NSURLConnection` on GNUstep (gnutls). |
| Basic and Bearer authentication | ✅ | Static credentials; no token refresh hook. |
| Timeouts | ✅ | |
| SAP Gateway CSRF token | ❌ | Vendor-specific: fetch `X-CSRF-Token` before writes. Needed only for SAP services. |
| Tests that exercise headers | ❌ | The snapshot transport ignores request headers, which is how the `415` went unnoticed. |
| Live smoke test in CI | ❌ | Northwind (read) and TripPin (write) are public. Should run without gating merges, since they are not ours. |

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

1. **Can connect and read correctly:** request headers, errors from
   fetches, next links (collections and to-many), `$orderby` through
   relationships, managed objects in predicates, `ANY` / `ALL`. Make the
   snapshot transport check headers, and add the live smoke test.
2. **Can write correctly:** keep the real ETag and send it back unchanged
   (and send none when there is none); send relationships with
   `@odata.bind`; `Prefer: return=representation`; client-supplied keys
   in POST.
3. **Types:** `DateTimeOffset` in full, `Date`, `IEEE754Compatible` for
   Int64 and Decimal, `INF` / `NaN`, Binary.
4. **Robustness:** `$batch` change sets for atomic saves, OData error
   bodies, percent-encoded keys, `@odata.editLink`, cache refresh,
   `Prefer: odata.maxpagesize` from `fetchBatchSize`.
5. **Model:** read `$metadata`: validate the Core Data model against it,
   discover keys, then derived types and enums.
6. **XML, for XForms:** JSON-to-XML mapping on the client first, since it
   works with every service; then Atom as a second wire format where a
   service offers it (section 7). Parsing CSDL XML in step 5 builds the
   XML reading this needs.
