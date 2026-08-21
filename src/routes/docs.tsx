import { createFileRoute } from "@tanstack/react-router";
import { SCHEMA } from "@/lib/odata/model";

export const Route = createFileRoute("/docs")({ component: DocsPage });

function DocsPage() {
  return (
    <main className="mx-auto max-w-3xl px-4 py-10 sm:px-6">
      <p className="text-xs font-medium uppercase tracking-[0.16em] text-muted">Implementation notes</p>
      <h1 className="mt-2 font-display text-4xl tracking-tight text-fg">How the store talks</h1>
      <article className="mt-8 space-y-8 text-sm leading-relaxed text-muted">
        <section>
          <h2 className="font-display text-2xl text-fg">Required overrides</h2>
          <p className="mt-3">
            Apple requires five methods on an NSIncrementalStore subclass. Everything else is optional. OIS implements
            exactly those, plus the mapping layer they need.
          </p>
          <ul className="mt-3 space-y-2">
            <li>
              <code className="font-mono text-fg">loadMetadata:</code> — GET $metadata, set store UUID and type.
            </li>
            <li>
              <code className="font-mono text-fg">executeRequest:withContext:error:</code> — fetch becomes GET; save
              becomes POST / PATCH / DELETE.
            </li>
            <li>
              <code className="font-mono text-fg">newValuesForObjectWithID:withContext:error:</code> — fault fulfillment,
              GET EntitySet(key).
            </li>
            <li>
              <code className="font-mono text-fg">newValueForRelationship:forObjectWithID:withContext:error:</code> — GET
              navigation property.
            </li>
            <li>
              <code className="font-mono text-fg">obtainPermanentIDsForObjects:error:</code> — POST inserted objects so
              the server can assign keys.
            </li>
          </ul>
        </section>
        <section>
          <h2 className="font-display text-2xl text-fg">XCTest snapshots</h2>
          <p className="mt-3">
            Tests never open a socket. <code className="font-mono text-fg">ODataSnapshotTransport</code> replays JSON
            tapes under <code className="font-mono text-fg">Tests/Snapshots</code>, each citing the OData v4 protocol
            section it pins ($filter ABNF, /$count, POST, PATCH + If-Match, 412, DELETE).{" "}
            <code className="font-mono text-fg">make test</code> on GNUstep runs the XCTest bundle;{" "}
            <code className="font-mono text-fg">swift test</code> on Apple. The workbench is a Cocoa
            app under <code className="font-mono text-fg">Examples/Workbench</code> — in-memory OData,
            real store, no website.
          </p>
        </section>
        <section>
          <h2 className="font-display text-2xl text-fg">Predicate translation</h2>
          <p className="mt-3">
            NSComparisonPredicate and NSCompoundPredicate walk into OData operators. CONTAINS / BEGINSWITH / ENDSWITH
            become functions. The [c] modifier wraps both sides in tolower(). Dotted key paths become navigation
            segments. ANY/ALL become lambda any/all.
          </p>
        </section>
        <section>
          <h2 className="font-display text-2xl text-fg">Threading</h2>
          <p className="mt-3">
            Incremental store callbacks are synchronous. On GNUstep the client uses{" "}
            <code className="font-mono text-fg">NSURLConnection</code> send-synchronous (no libdispatch). On Apple it
            waits on an <code className="font-mono text-fg">NSCondition</code>. Attach this store to a private-queue
            context.
          </p>
        </section>
        <section>
          <h2 className="font-display text-2xl text-fg">GNUstep / FreeCoreData</h2>
          <p className="mt-3">
            Built for the modern Objective-C runtime — clang,{" "}
            <code className="font-mono text-fg">-fobjc-runtime=gnustep-2.0</code>, ARC, blocks, non-fragile ABI. GCC’s old
            runtime is rejected at compile time by <code className="font-mono text-fg">OISRuntime.h</code>.
          </p>
          <p className="mt-3">
            On GNUstep the store subclasses{" "}
            <a href="https://github.com/ashalkhakov/FreeCoreData" className="text-wire hover:text-fg">
              FreeCoreData
            </a>
            — a Cocotron-based Core Data that actually implements{" "}
            <code className="font-mono text-fg">NSIncrementalStore</code> and{" "}
            <code className="font-mono text-fg">NSIncrementalStoreNode</code>. Install that framework, then{" "}
            <code className="font-mono text-fg">make</code>. OIS is ARC; FreeCoreData is MRC;{" "}
            <code className="font-mono text-fg">new…</code> methods return +1 on both sides.
          </p>
          <p className="mt-3">
            Without FreeCoreData, <code className="font-mono text-fg">make OIS_COREDATA=stub</code> compiles the in-tree
            shim so <code className="font-mono text-fg">ois-filter</code> can still walk NSPredicate. That is not a
            persistent store.
          </p>
        </section>
        <section>
          <h2 className="font-display text-2xl text-fg">Optimistic locking</h2>
          <p className="mt-3">
            @odata.etag is stored as NSIncrementalStoreNode.version. Updates send If-Match. HTTP 412 becomes an
            optimistic locking error Core Data can merge.
          </p>
        </section>
        <section>
          <h2 className="font-display text-2xl text-fg">Demo model</h2>
          <p className="mt-3">
            Catalog and the Cocoa workbench load <code className="font-mono text-fg">Catalog.xcdatamodeld</code>:
          </p>
          <ul className="mt-3 space-y-1 font-mono text-xs text-fg">
            {SCHEMA.entities.map((e) => (
              <li key={e.name}>
                {e.name} → {e.entitySet} ({e.attributes.length} attrs, {e.relationships.length} rels)
              </li>
            ))}
          </ul>
        </section>
        <section>
          <h2 className="font-display text-2xl text-fg">What is out of scope</h2>
          <p className="mt-3">
            $batch change sets, an offline SQLite mirror, delta tokens, unbound functions, and NSBatchDeleteRequest.
            Those are the next honest increments — not stubs.
          </p>
        </section>
      </article>
    </main>
  );
}
