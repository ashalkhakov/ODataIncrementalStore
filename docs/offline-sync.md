# Offline sync: design

**Status: proposed.** Nothing here is built yet except where it says
*exists*. The server's part (section 9) comes first.

An app that works offline keeps its data in a Core Data store on the device
and syncs it with an OData service when it can: entities the service owns
come down, entities the app collects go up, and entities both edit are
reconciled by rules the app can choose. Devices can also sync with each
other, so that one that reaches the service carries the others' work.

ODataSync is a library for that, on top of what ODataKit already is: the
OData client (`ODataClient`, the property mapper, the value coder), the
service (`ODataService`) and its delta links, and Core Data's persistent
history (Apple's, and FreeCoreData's). An app that serves its data with
ODataService gets the server half by configuration; the client half is
the library.

## 1. Goals

- The app works against **one local store** (SQLite, persistent history),
  online or not. The UI never waits for the network and never sees an
  `ODataIncrementalStore`.
- **Down**: entities the service owns (assets, price lists, users) are
  copied to the device and kept current by delta links. The app reads
  them; it does not edit them.
- **Up**: entities the app owns (inspections, readings, photos' records)
  are created on the device with UUID keys and sent to the service by
  upsert, so sending one twice is harmless.
- **Both**: entities either side may change are reconciled by a conflict
  rule: the service wins, the device wins, last writer wins, a merge by
  field, or the app's own.
- **Peers**: devices sync with each other the same way, so changes travel
  device to device and on to the service.
- **Crash-safe**: whatever is interrupted is done again, never twice in
  effect: what was applied and how far it got are saved together.
- **Little to integrate**: annotate the model, add the library's
  bookkeeping entities, start the engine.

Not goals, at first: syncing schema changes (both ends share a model
version), partial replication by arbitrary query per user beyond what the
service's row scoping gives, and real-time push (the engine pulls).

## 2. The shape

```
 the app's contexts
        │
 ┌──────▼────────────────────────────┐
 │  local store (SQLite, history)    │◄────── ODataSyncEngine
 │  app entities + ODataSync's own   │          │  remotes:
 └───────────────────────────────────┘          ├─ the service (ODataClient)
                                                └─ peers (the same, over the LAN)
```

- **ODataSyncEngine** owns the sync: one per local store, with one or more
  **remotes**. A remote is a service root URL with its credentials; a
  peer is a remote too.
- Per remote, a **downloader** (section 4) and an **uploader** (section 5)
  run in a context of their own on the local coordinator, so the app's
  contexts merge their saves as any other.
- The library adds a few **bookkeeping entities** of its own to the app's
  model (section 3.3), in the same store, so its state is saved in the
  same transactions as the data it describes.

ODataSync links ODataKit and ODataIncrementalStore (for `ODataClient`,
`ODataConfiguration` and credentials) and OTelKit (each sync a trace); it
does not use `ODataIncrementalStore` as a store.

## 3. The model

### 3.1 Directions

Each synced entity says which way it goes, in its `userInfo`:

| `ODataSync.direction` | Owner | The device | Sent as |
|---|---|---|---|
| `down` | the service | reads | nothing: never sent |
| `up` | the device | creates, edits, deletes | upsert (PATCH to its key), DELETE |
| `both` | either | edits | upsert with If-Match, DELETE with If-Match |
| (none) | the device | anything | nothing: local only |

A `down` entity changed locally is an error the engine reports (and, in
debug builds, a save that changes one fails); an `up` entity changed at
the service is overwritten by the device's next upsert unless it is
`both`.

The entity set and keys are the service's, as the mapper reads them
(`OData.entitySet`, `OData.key`): an entity syncs with the set its
`userInfo` names.

### 3.2 Keys

- `up` and `both` entities have a **UUID key**, made on the device when the
  object is inserted (the library offers `-[NSManagedObject
  ods_assignKey]`, or a default value in the model). Its identity is the
  same everywhere, so no key is ever mapped back, and a record relayed by
  a peer is the same record.
- `down` entities have the **service's keys**, whatever they are.
- Relationships are ordinary, across directions: an inspection (`up`)
  points to its asset (`down`). On the wire, a to-one is `@odata.bind` to
  the related entity's key.

### 3.3 The library's entities

Added to the app's model by `+[ODataSyncEngine addBookkeepingToModel:]`
(before the coordinator is made), all in the same store:

- **ODSRemoteState**: per remote, its delta links (one per entity set),
  the history token the uploader has read up to, and for peers the peer
  vector (section 7).
- **ODSOutboxEntry**: one per object with changes not yet accepted by a
  remote: entity, key, what changed (insert, the changed property names,
  delete), the base ETag it was edited from, attempts, the last error,
  and `quarantined` when a remote refused it for good (section 5.4).
- **ODSShadow**: per `both` object, the last version a remote confirmed:
  its ETag, and its values (for a three-way merge, section 6). Only for
  `both` entities, and only their synced properties.

## 4. Down

Per remote, per `down` and `both` entity set:

1. **First time**: GET the set with `Prefer: odata.track-changes` (and
   `$filter` when the app gives one: a set's rows for this user, by the
   service's row scoping or an explicit filter), following next links.
   Each row is applied by key; the final page's `@odata.deltaLink` is kept.
2. **After**: GET the delta link. Each entry is applied by key; `@removed`
   entries delete the local object; the new delta link is kept.
3. **410 Gone** (the service no longer has the history from there): read
   the set again as in 1, and delete the local objects of the set it did
   not return (mark and sweep).
4. **Applying**: in the downloader's context, with transaction author
   `ODataSync.down.<remote>`: update or insert by key (a key index makes
   this a lookup); to-one navigation values (`@odata.bind`-shaped
   references, or the foreign key properties the model maps) resolve to
   local objects by key, inserting a fault-like placeholder when the
   related row has not come yet (filled when it does).
5. **Saving**: the changes and the new delta link (in ODSRemoteState)
   in one save. A crash before it loses nothing: the old link is read
   again.

A removed `down` row that local `up` records still point to: the
relationship's delete rule decides (Nullify keeps the records; Deny makes
the downloader keep the row and report it). A `both` object with an
outbox entry is not overwritten: the incoming version is a conflict
(section 6).

### 4.1 When what a user may see changes

A set's rows are often scoped to the user (the handler's
`predicateForVisibleObjectsInRequest:`: their region, their team, rows
assigned to them). A delta link reports what changed among the rows, by
persistent history; what a user may see can change otherwise:

| # | What happened | What the user's delta says today | Right? |
|---|---|---|---|
| A | a visible row edited, still in scope and filter | the row | yes |
| B | a visible row edited out of the request's `$filter` | removed | yes |
| C | a row edited out of the user's scope (reassigned) | nothing | no: the device keeps it |
| D | a row deleted | removed, to every user | yes for those who had it; it tells the others the key of a row they never saw |
| E | a row the user never sees edited | nothing | yes |
| F | the user's own scope changed (role, region, team), no row did | nothing | no: rows left out stay, rows let in never come |
| G | a row let in by a change elsewhere (joining a team) | nothing | no: missing rows |

The service cannot tell C from E: whether the row was in this user's
scope when the link was made needs its values then, and history keeps
which properties changed, not what they were. Reporting every changed
row the user cannot see would send everyone the keys of everyone else's
changes. F and G leave nothing in history at all.

So:

1. **Key reconciliation** (the library; covers C, F, G). Now and then the
   downloader reads only the keys of a scoped set, with the app's filter
   (`GET Set?$select=<key>&$filter=...`, paged), deletes the local rows
   the service did not name, and reads the ones it lacks by key. When: on
   sign-in or a change of user, after a 410, when the service says the
   scope changed (2), and on a schedule the app sets (daily, say). It
   costs one read of keys per scoped set: for ten thousand rows, a few
   hundred kilobytes before gzip.
2. **A scope version in delta links** (the service; F and G at the next
   sync). The handler may say what version of the caller's scope a
   request has (`-scopeVersionForRequest:`: one made of the principal's
   claims that decide it, or a counter the application moves when a
   membership changes). Delta links carry it, and one followed with
   another answers 410: the client reconciles (1). Nothing changes for a
   handler that says none.
3. **Deletions checked against what they kept** (the service; D's leak).
   The attributes the visibility predicate reads are kept in history on
   deletion (`preservesValueInHistoryOnDeletion`, as the key must be
   already), and a deletion is reported only to a caller the predicate,
   evaluated on those values, lets see it. A predicate that reads
   anything not kept (a relationship, a property not preserved) reports
   it to every caller, as now.
4. **Reassignments** (the service, if ever: C at the next sync rather than
   the next reconciliation). A handler names the attributes that decide
   scope; a changed row whose history shows one of them changed, and that
   the caller cannot see now, is reported removed to the caller. It still
   tells every caller the key of a reassigned row (fewer than every
   change, but some), so it would be a handler's choice. Not planned
   until an app needs reassignments faster than reconciliation gives them.

## 5. Up

### 5.1 From history to the outbox

The uploader reads the local store's persistent history after the token
in ODSRemoteState, skipping transactions by any `ODataSync.down.*` author
(what came down is not sent back) and changes to entities that are not
`up` or `both`. Each change becomes or updates the object's
ODSOutboxEntry: an insert followed by updates stays an insert, changed
property names accumulate, a delete after an insert removes the entry
(never sent), a delete otherwise replaces it. The entries and the new
token are saved together. The outbox is the queue; history is how it is
filled, so the uploader never needs to read history twice.

With several remotes, each has its own token, and an entry records which
remotes still need it.

### 5.2 Sending

Entries go in dependency order (an object before those whose to-ones point
to it), as one `$batch` with `Prefer: odata.continue-on-error`, at most a
configured number per batch:

| Entry | `up` | `both` |
|---|---|---|
| insert | PATCH `Set(key)`: all synced properties, to-ones as `@odata.bind` | the same, with `If-None-Match: *` |
| update | PATCH `Set(key)`: the changed properties | the same, with `If-Match: <base ETag>` |
| delete | DELETE `Set(key)` | DELETE with `If-Match` |

PATCH to a key is an **upsert** (section 9.1): it creates the entity if
there is none, and otherwise updates it. An `up` insert and an `up` update
are the same request with more or fewer properties, so a repeat, after a
crash or by a peer that relayed it, ends as the first did.

### 5.3 Answers

| Answer | What the uploader does |
|---|---|
| 2xx | the entry is done (removed, or this remote crossed off); a `both` object's shadow takes the new ETag and values |
| DELETE 404 | done: it is already gone |
| 412 (`both`) | a conflict (section 6) |
| 400, 403, 409, 422 | refused: the entry is quarantined with the error, the app told; the rest go on |
| 401 | credentials (the remote's credential provider), then again |
| 5xx, no answer | left as it is, sent again later (backoff) |

### 5.4 Quarantine

A refused entry stays in the outbox, marked, with the service's error (an
OData error, its target and details): the app shows it, and the user
fixes the record (the next change clears the mark and it is sent again)
or discards it (`-[ODataSyncEngine discardEntry:]`, which also reverts
the local object to its shadow, or deletes it when it never reached the
service).

## 6. Conflicts

A conflict is a `both` object changed on the device (an outbox entry) and
at the remote (an ETag other than the base) since the version both last
agreed on (the shadow). It is found in two places: on upload (412 to an
If-Match), and on download (an incoming version of an object with an
outbox entry).

The engine then has three versions: **base** (the shadow), **local** (the
object now), **remote** (the remote's now: the incoming entry, or a GET
after the 412), and the properties each side changed since the base. A
**resolver** decides:

```objc
@protocol ODataSyncResolving <NSObject>
- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict;
@end
```

`ODataSyncConflict` has the entity, key, the three versions as property
dictionaries, the changed names on each side, and for deletes which side
deleted. `ODataSyncResolution` is one of: **take remote** (the local
object becomes the remote version; the entry is dropped), **keep local**
(the entry is sent again with If-Match of the remote's ETag), **merged**
(these values: applied locally, and sent with If-Match of the remote's
ETag), or **defer** (quarantined for the user).

Rules that come with the library, per entity (`ODataSync.conflicts` in
`userInfo`, or set in code), or one for all:

- **RemoteWins** (default): the service's version stands. Safe, and what a
  `down` entity does anyway.
- **LocalWins**: the device's edit is sent again over the remote's.
- **LastWriterWins**: by a timestamp property the model names
  (`ODataSync.modified`), which both sides set on every change; ties go to
  the remote. Across devices a wall clock is not enough: the library sets
  the property to a hybrid logical clock (section 7), which orders
  changes causally and stays near real time.
- **MergeFields**: three-way by property: what only one side changed is
  taken from it; a property both changed falls back to another rule
  (RemoteWins unless given).
- **Custom**: any object conforming to `ODataSyncResolving`, per entity or
  for all; given the three versions, it can do anything, including defer.

Deletes: an edit against a delete goes by the rule's notion of winner
(RemoteWins: deleted; LocalWins: re-created by the upsert); MergeFields
treats a delete as changing every property.

## 7. Peers

Devices sync with each other the same way they sync with the service: a
device that offers its data runs an **ODataSyncPeerServer**, which is
HTTPServerKit with an ODataService over the local store (both exist), on
the local network; another device adds it as a remote. So a phone that
spent the day in a basement hands its inspections to one with a signal,
which sends them on.

What that needs beyond a single service:

- **Who changed what**: each store has a replica ID (a UUID in its
  metadata), and each history transaction an author naming where the
  change came from (`ODataSync.down.<remote>`, the app's own, or a peer's
  replica). A change that came from a remote is not sent back to it.
- **Relaying**: a device keeps changes that came from a peer in its
  outbox for the service too (an entry lists the remotes that still need
  it). Because `up` entities are sent by upsert and are the same record
  everywhere (UUID keys), the service gets each change once in effect,
  whoever brings it.
- **Ordering**: last-writer-wins between devices uses a hybrid logical
  clock per change (a wall time and a counter, bumped past any time
  seen from a peer), so a device with a wrong clock cannot win forever.
- **Peer vectors**: per peer, the last history token of theirs this device
  has (their delta link, in effect). A peer's delta links come from its
  own ODataService, which keeps them from its store's persistent history,
  as the service does.
- **Deletes**: kept as tombstones in history (keys preserved on deletion:
  `preservesValueInHistoryOnDeletion`, which ODataService's delta links
  already require) for as long as peers may still ask.
- **`down` entities between peers**: a peer may serve them too (read-only),
  so a device that missed the service gets them from one that did; the
  service's version still wins when the device reaches it.
- **Out of scope here**: discovery (Bonjour, Multipeer Connectivity) and
  how peers trust each other (a token the service issued to each, checked
  by the peer server's authenticator); the engine takes a remote's URL and
  credentials, however found.

Peers come after the service sync works (section 10), but the state above
(replica ID, authors, per-remote tokens, clocks) is part of the first
version, so they need no migration.

## 8. Integrating

On the device:

```objc
NSManagedObjectModel *model = ...;                 // annotated: ODataSync.direction, keys
[ODataSyncEngine addBookkeepingToModel:model];
// the store: SQLite, with NSPersistentHistoryTrackingKey
ODataSyncEngine *sync = [[ODataSyncEngine alloc] initWithCoordinator:coordinator];
ODataSyncRemote *service = [ODataSyncRemote remoteWithServiceRoot:url];
service.credentialProvider = auth;                 // ODataCredentialProviding
[sync addRemote:service];
sync.resolver = [ODataSyncMergeFields resolverFallingBackTo:[ODataSyncRemoteWins resolver]];
sync.delegate = self;                              // progress, quarantine, conflicts deferred
[sync syncWithTarget:self action:@selector(syncDidFinish:)];   // or on a schedule, when online
```

On the service (ODataKit's server): the store keeps persistent history
(delta links), and the entity sets the devices write allow upsert
(section 9.1). `ois-serve` does it by settings; an `ODataServerApplication`
the same.

## 9. The service's part

What ODataService needs, and what it has:

1. **Upsert** (OData 4.01 Part 1, 11.4.4): a PATCH or PUT to an entity's
   key where there is none creates it, through the set handler's insert
   (with the key from the URL, which the body need not repeat, and must
   not contradict), and answers 201 (or 204 with `Prefer:
   return=minimal`); where there is one, it updates it as now.
   `If-None-Match: *` makes it create only (412 when the entity exists);
   `If-Match` makes it update only (412 when it does not). On by default
   for a set whose handler allows insert, off by a handler property
   (`allowsUpsert`), and said in `$metadata` (Capabilities.UpdateRestrictions,
   `Upsertable`). *Exists*, for entity sets' keys (not through a navigation
   property).
2. **Binds in an upsert's body**: `@odata.bind` on to-ones (and to-many,
   4.01) as in an insert. *Exists*: the create path is the insert's.
3. **Continue-on-error in $batch**: *exists* (`Prefer:
   odata.continue-on-error`).
4. **ETags and If-Match** on update and delete: *exist*, with 412.
5. **Delta links** from persistent history, with `$filter`: *exist*;
   `Capabilities.ChangeTracking` in `$metadata`: *exists*. Scope changes:
   section 4.1; the service's part is the scope version (4.1, 2) and
   deletions checked against what they kept (4.1, 3).
6. **History retention**: how long the store keeps history before delta
   links answer 410. *To be settled*: a setting for how far back history
   is kept (pruned by date), and 410 for links older than that (*exists*:
   the client side handles 410 already).
7. **Key uniqueness**: an upsert must find the one entity a key names; the
   store's key attribute is indexed and unique (a uniqueness constraint in
   the model). *Recommended in the docs; checked by the service at start,
   with a warning when missing.*

## 10. Order of work

1. The service: upsert (9.1, 9.2), its `$metadata`, tests (*done*); the
   scope version and deletions checked against what they kept (4.1);
   history retention (9.6).
2. ODataSync: model annotations, bookkeeping entities, the downloader
   (with key reconciliation, 4.1), the uploader with the outbox and quarantine, RemoteWins and LocalWins;
   tracing (each sync a trace: a span per remote, per set, per batch).
3. Conflicts: shadows, MergeFields, LastWriterWins with hybrid logical
   clocks, custom resolvers.
4. Peers: the peer server, relaying, peer vectors; discovery and trust left
   to the app.
5. The Workbench: a sync pane (an offline store over the built-in service,
   the outbox, conflicts), as the self-test's ground.

## 11. Open questions

- Large binaries (photos): streams have their own upload
  (`ODataStreamTransfer`); the outbox could carry a stream entry after its
  record, retried the same way.
- Per-user subsets beyond row scoping: an app-given `$filter` per set is
  enough for most; a set whose filter changes (a user moves region) needs
  a re-read, which the engine can do when the filter differs from the one
  the delta link was made with.
- Ordering across entities in one upload: dependency order covers to-ones;
  an app that needs several objects to arrive together could ask for a
  change set per group (all or nothing), at the price of one refusal
  holding the group.
- Schema versions: a device and a service on different model versions; at
  first, the engine refuses to sync when `$metadata` and the local model
  disagree on a synced entity (the mapper's problems).
