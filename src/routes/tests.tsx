import { useEffect, useMemo, useState } from "react";
import { createFileRoute, Link } from "@tanstack/react-router";
import { entityByName } from "@/lib/odata/model";
import { parsePredicate, toODataFilter } from "@/lib/odata/predicate";

export const Route = createFileRoute("/tests")({ component: TestsPage });

type IndexFile = {
  spec: string;
  snapshots: { id: string; file: string; spec?: string; predicate?: string }[];
};

type Snapshot = {
  comment?: string;
  spec?: string;
  predicate?: string;
  request: {
    method: string;
    path: string;
    query?: Record<string, string>;
    headers?: Record<string, string>;
    body?: unknown;
  };
  response: { status: number; headers?: Record<string, string>; body?: unknown; bodyXML?: string };
};

export function TestsPage() {
  const [index, setIndex] = useState<IndexFile | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const [snap, setSnap] = useState<Snapshot | null>(null);

  useEffect(() => {
    fetch("/ODataIncrementalStore/Tests/Snapshots/index.json")
      .then((r) => r.json())
      .then(setIndex);
  }, []);

  useEffect(() => {
    if (!open) {
      setSnap(null);
      return;
    }
    fetch(`/ODataIncrementalStore/Tests/Snapshots/${open}`)
      .then((r) => r.json())
      .then(setSnap);
  }, [open]);

  return (
    <main className="mx-auto max-w-6xl px-4 py-10 sm:px-6">
      <p className="text-xs font-medium uppercase tracking-[0.16em] text-muted">XCTest · no network</p>
      <h1 className="mt-2 font-display text-4xl tracking-tight text-fg">Snapshots</h1>
      <p className="mt-3 max-w-2xl text-sm leading-relaxed text-muted">
        The Objective-C suite talks to a tape of OData v4 request/response pairs, not a live service. Each card is one
        file under <span className="font-mono text-fg">Tests/Snapshots</span>. Open{" "}
        <Link to="/source" className="text-wire hover:text-fg">
          Objective-C
        </Link>{" "}
        and switch to XCTest for the <span className="font-mono text-fg">.m</span> cases.
      </p>
      <p className="mt-2 max-w-2xl text-xs text-subtle">{index?.spec}</p>
      <div className="mt-8 grid gap-3">
        {(index?.snapshots ?? []).map((item) => (
          <button
            key={item.file}
            type="button"
            onClick={() => setOpen(open === item.file ? null : item.file)}
            className="rounded-xl bg-surface px-4 py-3 text-left shadow-[var(--shadow-border)]"
          >
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <p className="font-mono text-sm text-fg">{item.file}</p>
              <p className="font-mono text-[0.6875rem] text-wire">{item.spec}</p>
            </div>
            {item.predicate && <p className="mt-1 font-mono text-xs text-muted">{item.predicate}</p>}
            {open === item.file && snap && <SnapshotBody snapshot={snap} predicate={item.predicate} />}
          </button>
        ))}
      </div>
    </main>
  );
}

function SnapshotBody({ snapshot, predicate }: { snapshot: Snapshot; predicate?: string }) {
  const check = useMemo(() => {
    if (!predicate || !snapshot.request.query?.$filter) return null;
    try {
      const entity = entityByName("Product");
      const got = toODataFilter(parsePredicate(predicate), entity);
      const want = snapshot.request.query.$filter;
      return { got, want, ok: got === want };
    } catch (err) {
      return { got: err instanceof Error ? err.message : String(err), want: snapshot.request.query.$filter, ok: false };
    }
  }, [predicate, snapshot]);

  return (
    <div className="mt-3 grid gap-3 border-t border-border pt-3 lg:grid-cols-2">
      <pre className="overflow-x-auto font-mono text-[0.7rem] leading-relaxed text-muted">
        {`${snapshot.request.method} ${snapshot.request.path}${queryString(snapshot.request.query)}\n`}
        {snapshot.request.headers ? `headers ${JSON.stringify(snapshot.request.headers)}\n` : ""}
        {snapshot.request.body ? JSON.stringify(snapshot.request.body, null, 2) : ""}
      </pre>
      <pre className="overflow-x-auto font-mono text-[0.7rem] leading-relaxed text-wire">
        {`HTTP ${snapshot.response.status}\n`}
        {snapshot.response.bodyXML
          ? snapshot.response.bodyXML.trim()
          : JSON.stringify(snapshot.response.body ?? "", null, 2)}
      </pre>
      {check && (
        <p className={`lg:col-span-2 font-mono text-xs ${check.ok ? "text-wire" : "text-danger"}`}>
          $filter {check.ok ? "matches" : "differs"}: {check.got}
        </p>
      )}
    </div>
  );
}

function queryString(query?: Record<string, string>) {
  if (!query || !Object.keys(query).length) return "";
  const q = Object.entries(query)
    .map(([k, v]) => `${k}=${v}`)
    .join("&");
  return `?${q}`;
}
