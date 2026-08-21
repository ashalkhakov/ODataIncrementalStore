import { createFileRoute, Link } from "@tanstack/react-router";
import { SourceBrowser } from "@/components/source-browser";

export const Route = createFileRoute("/workbench")({ component: WorkbenchPage });

function WorkbenchPage() {
  return (
    <main className="mx-auto max-w-6xl px-4 py-10 sm:px-6">
      <p className="text-xs font-medium uppercase tracking-[0.16em] text-muted">
        Cocoa · GNUstep · no website required
      </p>
      <h1 className="mt-2 font-display text-4xl tracking-tight text-fg">Workbench.app</h1>
      <p className="mt-3 max-w-2xl text-sm leading-relaxed text-muted">
        The workbench is a native AppKit app. It drives a real{" "}
        <code className="font-mono text-fg">ODataIncrementalStore</code> against an in-memory OData
        v4 service (<code className="font-mono text-fg">WorkbenchEngine</code>, an{" "}
        <code className="font-mono text-fg">ODataTransport</code>). No socket. Predicate →{" "}
        <code className="font-mono text-fg">$filter</code>, fetch, fault, expand, PATCH / POST /
        DELETE, wire log.
      </p>
      <pre className="mt-6 overflow-x-auto rounded-xl bg-surface p-4 font-mono text-[0.75rem] leading-relaxed text-wire shadow-[var(--shadow-border)]">{`. /usr/share/GNUstep/Makefiles/GNUstep.sh
make -C ../..
make -C Examples/Workbench
openapp ./Workbench.app`}</pre>
      <p className="mt-4 text-sm text-muted">
        <Link to="/source" className="text-wire hover:text-fg">
          Library source
        </Link>
        <span className="text-subtle"> · </span>
        <a href="/ODataIncrementalStore/Examples/Workbench/README.md" className="text-wire hover:text-fg">
          README
        </a>
      </p>
      <div className="mt-8">
        <SourceBrowser initialGroup="workbench" />
      </div>
    </main>
  );
}
