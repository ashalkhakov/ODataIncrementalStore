import { createFileRoute, Link } from "@tanstack/react-router";
import { ArrowRight } from "lucide-react";
import { LiveTranslate } from "@/components/live-translate";
import { StackDiagram } from "@/components/stack-diagram";
import { Button } from "@/components/ui/button";
import { SCHEMA } from "@/lib/odata/model";

export const Route = createFileRoute("/")({ component: Home });

function Home() {
  return (
    <main>
      <section className="mx-auto max-w-6xl px-4 pb-16 pt-12 sm:px-6 sm:pt-20">
        <p className="text-xs font-medium uppercase tracking-[0.18em] text-muted">
          GPL-3.0-or-later · Objective-C 2.0 · libobjc2 · FreeCoreData & Apple
        </p>
        <h1 className="mt-4 max-w-3xl font-display text-5xl leading-[1.05] tracking-tight text-fg sm:text-7xl">
          Core Data, over OData.
        </h1>
        <p className="mt-6 max-w-xl text-base leading-relaxed text-muted sm:text-lg">
          OIS is an <span className="text-fg">NSIncrementalStore</span> subclass that uses a remote OData service as
          the persistent store. Fetch requests become query options. Saves become POST, PATCH, and DELETE. ETags become
          optimistic locks. On GNUstep it subclasses{" "}
          <a href="https://github.com/ashalkhakov/FreeCoreData" className="text-wire hover:text-fg">
            FreeCoreData
          </a>
          .
        </p>
        <div className="mt-8 flex flex-wrap gap-3">
          <Button asChild>
            <Link to="/source">
              Open the Objective-C
              <ArrowRight className="size-4" />
            </Link>
          </Button>
          <Button asChild variant="secondary">
            <a href="/ODataIncrementalStore.zip">Download .m / .h zip</a>
          </Button>
          <Button asChild variant="secondary">
            <Link to="/workbench">Predicate workbench</Link>
          </Button>
        </div>
        <div className="mt-10 overflow-hidden rounded-xl bg-surface shadow-[var(--shadow-border)]">
          <div className="flex flex-wrap items-center justify-between gap-2 border-b border-border px-4 py-3">
            <p className="font-mono text-xs text-muted">ODataIncrementalStore.m</p>
            <Link to="/source" className="text-xs text-wire hover:text-fg">
              All 11 implementation files
            </Link>
          </div>
          <pre className="overflow-x-auto p-4 font-mono text-[0.75rem] leading-relaxed text-wire sm:p-5">{`- (id)executeRequest:(NSPersistentStoreRequest *)request
         withContext:(NSManagedObjectContext *)context
               error:(NSError **)error
{
  if (request.requestType == NSFetchRequestType)
    return [self executeFetch:(NSFetchRequest *)request
                      context:context error:error];
  if (request.requestType == NSSaveRequestType)
    return [self executeSave:(NSSaveChangesRequest *)request error:error];
  return nil;
}`}</pre>
        </div>
        <div className="mt-10 max-w-xl rounded-xl bg-surface px-4 py-4 shadow-[var(--shadow-border)] sm:px-5">
          <p className="text-xs font-medium uppercase tracking-[0.14em] text-muted">clang · libobjc2</p>
          <pre className="mt-3 overflow-x-auto font-mono text-[0.75rem] leading-relaxed text-wire">
            {`clang -fobjc-runtime=gnustep-2.0 -fobjc-arc -fblocks
      -fconstant-string-class=NSConstantString`}
          </pre>
          <p className="mt-3 text-xs leading-relaxed text-muted">
            GCC’s <span className="font-mono text-fg">libobjc</span> is the fragile ABI: no ARC, no non-fragile ivars, no
            zeroing weak. The headers refuse it. Use clang.
          </p>
        </div>
      </section>

      <section className="mx-auto max-w-6xl px-4 pb-16 sm:px-6">
        <LiveTranslate />
      </section>

      <section className="mx-auto grid max-w-6xl gap-10 px-4 pb-16 sm:px-6 lg:grid-cols-2">
        <div>
          <h2 className="font-display text-3xl tracking-tight text-fg">Why it exists</h2>
          <p className="mt-4 text-sm leading-relaxed text-muted">
            Microsoft’s OData4ObjC client was archived in 2013. AFIncrementalStore taught Core Data to speak REST, but
            never OData. SAP’s SDK is proprietary. If you have an OData v4 service and a Core Data model, there has not
            been a free, honest store in years.
          </p>
          <p className="mt-3 text-sm leading-relaxed text-muted">
            OIS is that store: GPL, Objective-C 2.0 on libobjc2, sitting on Apple Core Data or{" "}
            <a href="https://github.com/ashalkhakov/FreeCoreData" className="text-wire hover:text-fg">
              FreeCoreData
            </a>{" "}
            on GNUstep. The workbench on this site is the same translation the{" "}
            <span className="text-fg">.m</span> files perform.
          </p>
        </div>
        <StackDiagram />
      </section>

      <section className="mx-auto max-w-6xl px-4 pb-20 sm:px-6">
        <h2 className="font-display text-3xl tracking-tight text-fg">Name mapping</h2>
        <p className="mt-3 max-w-2xl text-sm text-muted">
          Core Data likes camelCase. Northwind likes PascalCase. The mapper uses{" "}
          <code className="font-mono text-fg">userInfo</code> overrides, then PascalCase, then the attribute name.
        </p>
        <div className="mt-6 overflow-x-auto rounded-xl bg-surface shadow-[var(--shadow-border)]">
          <table className="w-full min-w-[36rem] text-left text-sm">
            <thead className="border-b border-border text-xs uppercase tracking-wide text-muted">
              <tr>
                <th className="px-4 py-3 font-medium">Entity</th>
                <th className="px-4 py-3 font-medium">Attribute</th>
                <th className="px-4 py-3 font-medium">OData property</th>
                <th className="px-4 py-3 font-medium">EDM</th>
              </tr>
            </thead>
            <tbody>
              {SCHEMA.entities
                .flatMap((e) => e.attributes.filter((a) => a.key || a.name === "name" || a.name === "unitPrice").map((a) => ({ e, a })))
                .map(({ e, a }) => (
                  <tr key={`${e.name}-${a.name}`} className="border-b border-border/70">
                    <td className="px-4 py-2.5 font-mono text-xs text-fg">{e.name}</td>
                    <td className="px-4 py-2.5 font-mono text-xs text-muted">{a.name}</td>
                    <td className="px-4 py-2.5 font-mono text-xs text-wire">{a.odata}</td>
                    <td className="px-4 py-2.5 font-mono text-xs text-subtle">{a.type}</td>
                  </tr>
                ))}
            </tbody>
          </table>
        </div>
      </section>
    </main>
  );
}
