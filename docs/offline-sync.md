# Offline sync: design

**Status: the service's part (section 9) and the library's phases 1–4
(section 10) exist**: `Source/ODataSync` (`ODataSyncEngine`,
`ODataSyncPeerServer`), with down, up and both entities, the outbox and
set-aside changes, key reconciliation, conflicts (shadows with values,
RemoteWins, LocalWins, LastWriterWins on a hybrid logical clock,
MergeFields, custom resolvers), and peers (a peer server, relaying).
The Workbench pane (phase 5) is still to come.

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
or discards it (`-[ODataSyncEngine discardIssue:]`, which also reverts
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
hands a delete to its fallback; LastWriterWins lets the edit stand (a
delete carries no stamp of its own). That is with the service; between
peers a deletion is remembered and wins (section 7).

As built:

- `userInfo` names a rule with `ODataSync.conflicts`: `remote`, `local`,
  `lastwriter` or `merge`. Which applies, most specific first: a resolver
  set in code for the entity (`-setResolver:forEntityName:`, looked up
  through superentities), the `userInfo` rule, `engine.resolver`, then
  `engine.conflictPolicy`.
- `ODataSync.modified` names a string attribute. Every save not made by
  the engine stamps it with the replica's hybrid logical clock,
  `<milliseconds, 16 digits>.<counter, 4 digits>.<replica, 8>`, so
  stamps compare as strings; the clock moves past every stamp the engine
  reads from a remote. The replica's identifier is kept in the store's
  metadata (`-replicaID`).
- The shadow keeps the agreed version's JSON, so base, local and remote
  are compared in the service's names and values, and the conflict's
  dictionaries carry the model's attribute names.
- Keep local and merged both agree on the remote's version first (its
  ETag in the shadow), then the entry sends only what still differs from
  it; nothing, when the two already match.
- Defer sets the entry aside as an issue with status 409. Retrying it
  sends the local version over the remote's; discarding it turns it into
  a refresh, which reads the remote's version into the object at the next
  sync.
- A conflict met on upload (412) is settled at once: a GET of the row, the
  resolver, and the changed entry sent again, up to three rounds a sync.

## 7. Peers

Devices sync with each other the same way they sync with the service: a
device that offers its data runs an **ODataSyncPeerServer** (an
ODataService over its store, on HTTPServerKit), on the local network;
another device adds it as a remote, `+[ODataSyncRemote
peerWithServiceRoot:]`. So a phone that spent the day in a basement hands
its inspections to one with a signal, which sends them on.

```objc
// The device that offers its store:
ODataSyncPeerServer *peers = [[ODataSyncPeerServer alloc] initWithEngine:sync host:@"192.168.1.20" port:8642];
peers.service.authenticator = ...;               // who may sync
[peers start:&error];                            // advertise peers.serviceRoot
// A device that syncs with it:
[sync addRemote:[ODataSyncRemote peerWithServiceRoot:advertisedURL]];
```

How it goes:

- **Who changed what**: each store has a replica ID (a UUID in its
  metadata). A peer server's root is `http://<host>:<port>/sync/<replica
  ID>/`, and a peer remote's identifier is that replica ID. What the
  engine downloads from a remote is written by author
  `ODataSync.down.<identifier>`; what a device sends to a peer server
  names its replica (`ODataSync-Replica` header) and is written there by
  author `ODataSync.down.<its replica>`. So every change in a store says
  where it came from, whichever way it travelled.
- **Relaying**: a change is never sent back to where it came from. It is
  passed on to the other remotes when the source or the destination is a
  peer (a peer's work to the service, the service's data to a peer);
  between two services nothing is passed on. Up entities are sent by
  upsert and have UUID keys, so the service gets each change once in
  effect, whoever brings it.
- **Nothing goes round**: an incoming row is applied only where it
  differs (an equal value is no change, so no history), and a change for
  a remote is dropped when it equals the version that remote last agreed
  to (its shadow). A change that went A → B → service → A stops at A.
- **A peer is no authority**: with a peer, up entities are treated as
  both (shadows, If-Match, conflicts and resolvers); from a peer come
  changes of up and both entities, and of down entities only what is
  missing here, or newer by the service's version counter (below). What a
  peer reads deletes nothing here (neither its removals nor the rows it
  lacks): a peer's set may be scoped or filtered differently, and no
  peer's view is complete. A peer that lacks an object this device sends
  gets it whole.
- **The service's version, through a peer**: a down entity with a version
  attribute (an integer that `OData.etag` names, which ODataService
  increments on each update it makes, and which the server app's own
  writes must increment too) has ordered ETags. Its copy from a peer
  replaces this device's when its version is higher: it is the service's,
  only newer. Without one, a peer only fills in what is missing (ETags of
  hashed values cannot be ordered). Peers cannot change it: down sets are
  read only on a peer server.
- **Which deletions travel**: a device's own deletion is sent to every
  remote, peers included. One that a peer sent here is passed on to the
  other remotes: an engine sends a peer only deletions made on its device
  (or passed on so), and a peer's reads delete nothing, so it is a real
  one. One that came down from a service is not passed on: it may be the
  service's scope, not the object's end (a device out of scope keeps no
  copy; each device learns that from the service).
- **Relayed changes are checked**: an up entity's change that came from
  elsewhere is sent to the service as a both entity's (If-Match of the
  version it agreed to, `*` when none; If-None-Match for a new one), not
  by a plain upsert. A stale copy, or an edit of what the service has
  since deleted, meets a 412 and goes to the resolver, instead of
  overwriting a newer version or making a deleted object again. A change
  made on this device is sent by upsert as before: its own work.
- **Ordering**: last writer wins compares the `ODataSync.modified`
  stamps of a hybrid logical clock. A peer server keeps the stamps it is
  sent (its writes are the engine's, not the app's, so they are not
  stamped again) and moves its own clock past them, like a download.
- **Peer vectors**: per peer, the delta links of its sets (in the remote's
  state, as for the service); a peer's ODataService makes them from its
  store's persistent history. A new peer reads everything once.
- **What a peer serves**: the synced entities only, not the engine's
  bookkeeping nor local-only entities: `+addBookkeepingToModel:` adds a
  model configuration listing them (`ODataSyncPeerConfiguration`, which no
  store need use), and the peer server serves that configuration. Down
  sets are read only.
- **Conflicts with a peer are settled the same way on both sides**: each
  peer asks in turn, so a rule must choose the same version whichever
  side asks, or the two swap for ever. The remote's or this side's are
  not such: with a peer, RemoteWins and LocalWins (and MergeFields falling
  back to either) become LastWriterWins, whose ties (or missing stamps) go
  to the version whose values sort last. `ODataSyncConflict.withPeer` tells
  a custom resolver, which must be as even-handed.
- **Never an older version over a newer one**: a peer's row older (by the
  stamps) than this side's copy is not applied; it is agreed on as the
  peer's, and this side's is sent to it (a peer a step behind would
  otherwise pass its old copy round again). A change older than the
  version a remote last agreed to is not sent; the remote's is taken. A
  change of a version never agreed on with that remote (an object that
  came from elsewhere) goes with an `If-Match` that matches nothing, so it
  meets the remote's version (412, the resolver) instead of overwriting it
  unseen; a deletion goes with `*`.
- **Deletions remembered**: each device keeps the keys of synced objects
  deleted in its store (`ODSTombstone`), whoever deleted them. A peer
  server refuses an insert of such a key (410 Gone), and the sender takes
  the deletion (its copy deleted, and that passed on); a download from a
  peer does not make such an object again. So between peers a deletion
  wins over a change made without knowing of it, as in Ensembles, and an
  insert and a deletion cannot chase each other round a ring of peers. An
  object made again here, or by a service, is not deleted any more.
  Tombstones are kept `tombstoneRetention` (30 days by default).
- **Remotes in turn**: a sync goes through the remotes in the order they
  were added. That decides how soon a change travels (a peer added before
  the service has its work passed on in the same sync), not what the
  stores end up with: the checks above catch a copy that comes late.
- **Compared with others**: Ensembles (Core Data sync over a shared
  file store, or Multipeer Connectivity) has every device publish only its
  own change logs, and every device read every other's; peers forward the
  raw log files, so no one re-authors another's change, and a deletion
  spreads with its author's log. Ordering is by a vector clock and a
  global count, so arrival order does not matter; a delete beats a
  concurrent update; all devices are equal, with no read-only data.
  Couchbase Lite keeps "deleted" (a tombstone, replicated) apart from "no
  longer visible to you" (purged locally, never replicated), which is the
  distinction behind which deletions travel here; its server is the
  authority through access control, as the service is here.
- **Out of scope here**: discovery (Bonjour, Multipeer Connectivity, a QR
  code) and how peers trust each other (a token the service issued to
  each, checked by the peer server's authenticator); the engine takes a
  remote's URL and credentials, however found.

### 7.1 Known issue: an insert passed on late makes a deleted object again

A device makes an object and gives it to a peer; the service gets it
(from either), and later deletes it. If the peer passes the *insert* on
to the service only after that (it had not synced since), the insert goes
with `If-None-Match: *`, finds nothing, and the object is made again. An
update passed on late is caught (`If-Match` finds nothing: a 412, and the
resolver), but an insert cannot tell "deleted" from "never there".
Ensembles has the same hole: an insert of the same global ID brings an
object back.

Between devices it is closed: a peer server remembers deletions and
refuses the insert (410), so only the service is left. Closing it there
needs the service to remember deleted keys too: a set that keeps
its tombstones (persistent history already does, for delta links, as long
as history is retained) could answer an upsert of a deleted key with 409
or 410 instead of making it, and the engine would take that as the
object's end. Until then, an app that deletes at the service what devices
collected should expect the odd one back, and can delete it again.

### 7.2 How it is tested

Data that syncs must end the same everywhere, and stay so; peers make the
orders in which changes meet too many to think through. Besides tests of
each behaviour (Tests/ODataSyncTests.m), Tests/ODataSyncConvergenceTests.m
tests reconciliation as a whole:

- **Every conflict under every rule**: a both object agreed on, then each
  side's change (none, an edit, an edit of another property, a delete)
  against each of the other's, under RemoteWins, LocalWins,
  LastWriterWins (either side later) and MergeFields, met on download and
  on upload (412). Each case checks what both sides end with against the
  rule, that nothing is left to send, and that another sync changes
  nothing.
- **Convergence**: four devices (two reach the service, the others reach
  them as peers, and some offer themselves back), and the service, making
  changes at random (tasks, inspections, assets; made, edited, deleted)
  and syncing in random orders, whole or half. Then every device reaches
  the service and syncs until nothing changes. It checks that this ends
  (within eight rounds), that every device has what the service has,
  that nothing is left to send and no change set aside, that every
  inspection no one deleted reached the service as last written, and
  (under last writer wins) that each task left has its last version.
  Odd seeds settle by last writer wins, even ones by the default. Eight
  seeds by default; `ODATASYNC_SEEDS=1000` for a long run (about ten
  minutes), `ODATASYNC_SEED=n` for one (stamps follow the wall clock, so a
  seed replays the same steps, not always the same timing).

What it found, and what changed for it: a delta that did not tell of an
object made and deleted since its link (section 9, 5); a change of a
version never agreed on overwriting a newer one (`If-Match: *`); peers
swapping versions for ever under a one-sided rule; a peer a step behind
passing its old copy round; and an insert and a deletion chasing each
other round three peers (tombstones).

## 8. Integrating

On the device:

```objc
NSManagedObjectModel *model = ...;                 // annotated: ODataSync.direction, keys
[ODataSyncEngine addBookkeepingToModel:model configuration:nil];
// the store: SQLite, with NSPersistentHistoryTrackingKey
ODataSyncEngine *sync = [[ODataSyncEngine alloc] initWithCoordinator:coordinator];
ODataSyncRemote *service = [ODataSyncRemote remoteWithServiceRoot:url];
service.configuration.credentialProvider = auth;   // ODataCredentialProviding
service.filters = @{ @"Asset": @"Region eq 'North'" };
[sync addRemote:service];
sync.resolver = [[ODataSyncMergeFields alloc] init];   // or per entity: -setResolver:forEntityName:, userInfo ODataSync.conflicts
sync.delegate = self;                              // changes set aside, local edits of down entities
[sync syncWithTarget:self action:@selector(syncDidFinish:error:)];   // or -syncWithError: off the main thread
```

What exists, and how it goes (`ODataSyncEngine.h`):

- A sync, per remote: the store's history after the remote's token
  folded into the outbox (so what the device has not sent is known), then
  each down and both set read (whole the first time, by its delta link
  after, whole again after a 410 or a change of filter, with what the
  remote no longer has swept), then the outbox sent.
- The outbox goes as JSON `$batch` requests that stand or fall alone
  (`odata.continue-on-error`), one at a time where a service takes no
  JSON batch; upserts parents first, deletions children first.
- Refused changes are set aside (`-issues`, the delegate), sent again
  when the object changes or the app retries them, or discarded.
- `-reconcileWithRemote:error:` reads each set's keys again (4.1).
- Each sync is a trace (OTelKit): `sync`, `download <Entity>`, `upload batch`.
- A both entity keeps, per object, the version both last agreed on
  (`ODSShadow`: its ETag, for If-Match, and its values, for merges);
  conflicts go to the resolver (section 6).
- Peers (section 7): `ODataSyncPeerServer.h` serves the store;
  `+[ODataSyncRemote peerWithServiceRoot:]` syncs with one. Remotes sync
  in the order they were added, so a device that adds its peers before the
  service passes their work on in the same sync.

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
   deletions checked against what they kept (4.1, 3). An object made and
   deleted since the link is told as deleted all the same: the client may
   have it (one that made it after reading the link, as an offline device
   does by its upload); one that never had it finds nothing to remove.
6. **History retention**: how long the store keeps history before delta
   links answer 410: `historyRetention` (`HistoryRetention` for
   `ois-serve`), pruned by date in the background as requests come, and
   410 for links from before it. *Exists*; the client side handles 410
   already. A device offline longer than that reads its sets again.
7. **Key uniqueness**: an upsert must find the one entity a key names; the
   store's key attribute is indexed and unique (a uniqueness constraint in
   the model). *Recommended in the docs; checked by the service at start,
   with a warning when missing.*

## 10. Order of work

1. The service: upsert (9.1, 9.2), its `$metadata`, tests (*done*); the
   scope version and deletions checked against what they kept (4.1);
   history retention (9.6). *Done.*
2. ODataSync: model annotations, bookkeeping entities, the downloader
   (with key reconciliation, 4.1), the uploader with the outbox and quarantine, RemoteWins and LocalWins;
   tracing (each sync a trace: a span per remote, per set, per batch).
   *Done* (Tests/ODataSyncTests.m against an ODataService in the process;
   Server/Tests/ois-serve-check.m over HTTP, on both platforms).
3. Conflicts: shadows, MergeFields, LastWriterWins with hybrid logical
   clocks, custom resolvers. *Done* (Tests/ODataSyncTests.m).
4. Peers: the peer server, relaying, peer vectors; discovery and trust left
   to the app. *Done* (Tests/ODataSyncTests.m in the process;
   Server/Tests/ois-serve-check.m over HTTP, on both platforms).
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
