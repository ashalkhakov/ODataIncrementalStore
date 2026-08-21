import { Link } from "@tanstack/react-router";
import { useMemo, useState } from "react";
import { ChevronRight, Play, RotateCcw } from "lucide-react";
import { ODataEngine } from "@/lib/odata/engine";
import { FETCH_PRESETS, SCHEMA, entityByName } from "@/lib/odata/model";
import {
  executeFetch,
  fulfillFault,
  fulfillRelationship,
  saveDelete,
  saveInsert,
  saveUpdate,
} from "@/lib/odata/simulate";
import { translateFetch } from "@/lib/odata/translator";
import type { FetchRequest, FetchResultType, IncrementalNode, ObjectID, StoreMethodCall, WireEvent } from "@/lib/odata/types";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";

function freshEngine() {
  return new ODataEngine();
}

const RESULT_TYPES: { id: FetchResultType; label: string }[] = [
  { id: "managedObject", label: "objects" },
  { id: "managedObjectID", label: "object IDs" },
  { id: "dictionary", label: "dictionary" },
  { id: "count", label: "count" },
];

export function Workbench() {
  const [engine] = useState(freshEngine);
  const [entity, setEntity] = useState("Product");
  const [predicate, setPredicate] = useState("unitPrice > 20 AND discontinued == NO");
  const [sortKey, setSortKey] = useState("unitPrice");
  const [sortAsc, setSortAsc] = useState(false);
  const [limit, setLimit] = useState<string>("");
  const [expand, setExpand] = useState("");
  const [resultType, setResultType] = useState<FetchResultType>("managedObject");
  const [faults, setFaults] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [wires, setWires] = useState<WireEvent[]>([]);
  const [methods, setMethods] = useState<StoreMethodCall[]>([]);
  const [ids, setIds] = useState<ObjectID[]>([]);
  const [nodes, setNodes] = useState<IncrementalNode[]>([]);
  const [dictionaries, setDictionaries] = useState<Record<string, unknown>[]>([]);
  const [count, setCount] = useState<number | null>(null);
  const [payload, setPayload] = useState<unknown>(null);
  const [selected, setSelected] = useState<ObjectID | null>(null);
  const [insertName, setInsertName] = useState("New Blend");

  const entityDef = entityByName(entity);

  const request: FetchRequest = useMemo(
    () => ({
      entity,
      predicate: predicate.trim() || undefined,
      sort: sortKey ? [{ key: sortKey, ascending: sortAsc }] : [],
      fetchLimit: limit ? Number(limit) : undefined,
      relationshipKeyPathsForPrefetching: expand ? [expand] : undefined,
      resultType,
      returnsObjectsAsFaults: faults,
      propertiesToFetch: resultType === "dictionary" ? ["name", "unitPrice", "id"].filter((n) => entityDef.attributes.some((a) => a.name === n)) : undefined,
    }),
    [entity, predicate, sortKey, sortAsc, limit, expand, resultType, faults, entityDef],
  );

  const live = useMemo(() => {
    try {
      return { ok: true as const, translation: translateFetch(request) };
    } catch (err) {
      return { ok: false as const, message: err instanceof Error ? err.message : String(err) };
    }
  }, [request]);

  function pushWire(w: WireEvent) {
    setWires((prev) => [w, ...prev].slice(0, 24));
  }

  function run() {
    try {
      setError(null);
      const out = executeFetch(engine, request);
      pushWire(out.wire);
      setMethods(out.methods);
      setIds(out.objectIDs);
      setNodes(out.nodes);
      setDictionaries(out.dictionaries);
      setCount(out.count);
      setPayload(out.json);
      setSelected(out.objectIDs[0] ?? null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  function applyPreset(label: string) {
    const preset = FETCH_PRESETS.find((p) => p.label === label);
    if (!preset) return;
    const r = preset.request;
    setEntity(r.entity);
    setPredicate(r.predicate ?? "");
    setSortKey(r.sort[0]?.key ?? "");
    setSortAsc(r.sort[0]?.ascending ?? true);
    setLimit(r.fetchLimit != null ? String(r.fetchLimit) : "");
    setExpand(r.relationshipKeyPathsForPrefetching?.[0] ?? "");
    setResultType(r.resultType);
    setFaults(r.returnsObjectsAsFaults !== false);
  }

  function onSelect(id: ObjectID) {
    setSelected(id);
    const existing = nodes.find((n) => n.objectID.ref === id.ref);
    if (existing && !existing.faults) return;
    try {
      const out = fulfillFault(engine, id);
      pushWire(out.wire);
      setMethods(out.methods);
      setNodes((prev) => {
        const rest = prev.filter((n) => n.objectID.ref !== id.ref);
        return [out.node, ...rest];
      });
      setPayload(out.wire.responseBody);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  function onExpandRel(relName: string) {
    if (!selected) return;
    try {
      const out = fulfillRelationship(engine, selected, relName);
      pushWire(out.wire);
      setMethods(out.methods);
      setPayload(out.json);
      if (out.ids.length) {
        setIds(out.ids);
        setSelected(out.ids[0] ?? null);
        setEntity(out.ids[0]?.entity ?? entity);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  function bumpPrice() {
    if (!selected) return;
    const node = nodes.find((n) => n.objectID.ref === selected.ref);
    const current = Number(node?.values.unitPrice ?? 20);
    try {
      const out = saveUpdate(engine, selected, { unitPrice: current + 1 }, node?.version ?? 1);
      pushWire(out.wire);
      setMethods(out.methods);
      setPayload(out.wire.responseBody);
      if (out.status === 200) onSelect(selected);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  function insertProduct() {
    try {
      const out = saveInsert(engine, "Product", {
        name: insertName,
        quantityPerUnit: "1 unit",
        unitPrice: 12.5,
        unitsInStock: 8,
        discontinued: false,
        categoryId: 1,
        supplierId: 1,
      });
      pushWire(out.wire);
      setMethods(out.methods);
      setIds([out.id, ...ids]);
      setSelected(out.id);
      setEntity("Product");
      setPayload(out.wire.responseBody);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  function removeSelected() {
    if (!selected) return;
    try {
      const out = saveDelete(engine, selected);
      pushWire(out.wire);
      setMethods(out.methods);
      setIds((prev) => prev.filter((i) => i.ref !== selected.ref));
      setNodes((prev) => prev.filter((n) => n.objectID.ref !== selected.ref));
      setSelected(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  const selectedNode = nodes.find((n) => n.objectID.ref === selected?.ref);
  const selectedEntity = selected ? entityByName(selected.entity) : entityDef;

  return (
    <div className="mx-auto flex max-w-6xl flex-col gap-6 px-4 py-6 sm:px-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <p className="text-xs font-medium uppercase tracking-[0.16em] text-muted">NSIncrementalStore session</p>
          <h1 className="font-display text-3xl tracking-tight text-fg sm:text-4xl">Workbench</h1>
          <p className="mt-2 max-w-xl text-sm leading-relaxed text-muted">
            This page is a JavaScript twin of the translator so you can poke at predicates in the browser. The store
            itself is Objective-C —{" "}
            <Link to="/source" className="text-wire hover:text-fg">
              ODataIncrementalStore.m
            </Link>
            .
          </p>
        </div>
        <Button variant="ghost" size="sm" onClick={() => window.location.reload()}>
          <RotateCcw className="size-3.5" />
          Reset store
        </Button>
      </div>

      <div className="flex flex-wrap gap-2">
        {FETCH_PRESETS.map((p) => (
          <button
            key={p.label}
            type="button"
            onClick={() => applyPreset(p.label)}
            className="rounded-sm bg-raised px-3 py-2 text-left text-xs text-muted shadow-[var(--shadow-border)] transition-colors duration-150 hover:text-fg"
          >
            {p.label}
          </button>
        ))}
      </div>

      <section className="rounded-xl bg-surface p-3 shadow-[var(--shadow-border)] sm:p-4">
        <div className="grid gap-3 md:grid-cols-2">
          <label className="flex flex-col gap-1.5 text-xs text-muted">
            Entity
            <select
              value={entity}
              onChange={(e) => {
                setEntity(e.target.value);
                const next = entityByName(e.target.value);
                setSortKey(next.attributes.find((a) => !a.key)?.name ?? "id");
                setExpand("");
              }}
              className="h-11 rounded-sm bg-raised px-3 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none focus:ring-2 focus:ring-accent/40"
            >
              {SCHEMA.entities.map((e) => (
                <option key={e.name} value={e.name}>
                  {e.name}
                </option>
              ))}
            </select>
          </label>
          <label className="flex flex-col gap-1.5 text-xs text-muted">
            Result type
            <select
              value={resultType}
              onChange={(e) => setResultType(e.target.value as FetchResultType)}
              className="h-11 rounded-sm bg-raised px-3 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none focus:ring-2 focus:ring-accent/40"
            >
              {RESULT_TYPES.map((t) => (
                <option key={t.id} value={t.id}>
                  {t.label}
                </option>
              ))}
            </select>
          </label>
        </div>
        <label className="mt-3 flex flex-col gap-1.5 text-xs text-muted">
          NSPredicate format
          <textarea
            value={predicate}
            onChange={(e) => setPredicate(e.target.value)}
            rows={2}
            spellCheck={false}
            className="resize-y rounded-md bg-raised px-3 py-2 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none focus:ring-2 focus:ring-accent/40"
            placeholder='unitPrice > 20 AND name BEGINSWITH[cd] "c"'
          />
        </label>
        <div className="mt-3 grid gap-3 sm:grid-cols-3">
          <label className="flex flex-col gap-1.5 text-xs text-muted">
            Sort
            <select
              value={sortKey}
              onChange={(e) => setSortKey(e.target.value)}
              className="h-11 rounded-sm bg-raised px-3 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none"
            >
              <option value="">(none)</option>
              {entityDef.attributes.map((a) => (
                <option key={a.name} value={a.name}>
                  {a.name}
                </option>
              ))}
            </select>
          </label>
          <label className="flex flex-col gap-1.5 text-xs text-muted">
            Direction
            <select
              value={sortAsc ? "asc" : "desc"}
              onChange={(e) => setSortAsc(e.target.value === "asc")}
              className="h-11 rounded-sm bg-raised px-3 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none"
            >
              <option value="asc">ascending</option>
              <option value="desc">descending</option>
            </select>
          </label>
          <label className="flex flex-col gap-1.5 text-xs text-muted">
            fetchLimit ($top)
            <input
              value={limit}
              onChange={(e) => setLimit(e.target.value)}
              inputMode="numeric"
              className="h-11 rounded-sm bg-raised px-3 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none"
              placeholder="∞"
            />
          </label>
        </div>
        <div className="mt-3 flex flex-wrap items-center gap-3">
          <label className="flex flex-col gap-1.5 text-xs text-muted">
            Prefetch ($expand)
            <select
              value={expand}
              onChange={(e) => setExpand(e.target.value)}
              className="h-11 rounded-sm bg-raised px-3 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none"
            >
              <option value="">(none)</option>
              {entityDef.relationships.map((r) => (
                <option key={r.name} value={r.name}>
                  {r.name}
                </option>
              ))}
            </select>
          </label>
          <label className="mt-5 flex h-11 items-center gap-2 text-sm text-muted">
            <input type="checkbox" checked={faults} onChange={(e) => setFaults(e.target.checked)} className="size-4 accent-accent" />
            return as faults
          </label>
          <div className="ml-auto pt-5">
            <Button onClick={run}>
              <Play className="size-3.5" />
              Execute
            </Button>
          </div>
        </div>
      </section>

      <section className="rounded-lg bg-raised px-4 py-3 shadow-[var(--shadow-border)]">
        <div className="flex flex-wrap items-center gap-2 text-xs text-muted">
          <Badge>GET</Badge>
          <code className="font-mono text-[0.8125rem] break-all text-fg">
            {live.ok ? live.translation.url : live.message}
          </code>
        </div>
        {live.ok && live.translation.notes.length > 0 && (
          <p className="mt-2 text-xs text-subtle">{live.translation.notes.join(" · ")}</p>
        )}
      </section>

      {error && (
        <p className="rounded-md bg-raised px-4 py-3 text-sm text-danger shadow-[var(--shadow-border)]">{error}</p>
      )}

      <div className="grid gap-4 lg:grid-cols-3">
        <Panel title="Store callbacks">
          {methods.length === 0 ? (
            <Empty>Execute a fetch to see which NSIncrementalStore methods fire.</Empty>
          ) : (
            <ol className="space-y-3">
              {methods.map((m, i) => (
                <li key={`${m.method}-${i}`} className="flex gap-3">
                  <span className="mt-0.5 font-mono text-[0.6875rem] text-subtle">{String(i + 1).padStart(2, "0")}</span>
                  <div>
                    <p className="font-mono text-xs text-wire">{m.method}</p>
                    <p className="mt-1 text-sm text-muted">{m.detail}</p>
                  </div>
                </li>
              ))}
            </ol>
          )}
        </Panel>

        <Panel title="Object IDs">
          {resultType === "count" && count != null && (
            <p className="font-display text-4xl tabular-nums text-fg">{count}</p>
          )}
          {resultType === "dictionary" && (
            <pre className="overflow-auto font-mono text-[0.75rem] leading-relaxed text-muted">
              {JSON.stringify(dictionaries, null, 2)}
            </pre>
          )}
          {resultType !== "count" && resultType !== "dictionary" && (
            <ul className="space-y-1">
              {ids.length === 0 && <Empty>No IDs yet.</Empty>}
              {ids.map((id) => {
                const node = nodes.find((n) => n.objectID.ref === id.ref);
                const active = selected?.ref === id.ref;
                return (
                  <li key={id.ref}>
                    <button
                      type="button"
                      onClick={() => onSelect(id)}
                      className={cn(
                        "flex w-full items-center justify-between rounded-sm px-2 py-2 text-left font-mono text-xs transition-colors duration-150",
                        active ? "bg-raised text-fg" : "text-muted hover:text-fg",
                      )}
                    >
                      <span>{id.ref}</span>
                      <span className="text-subtle">{node?.faults === false ? "node" : "fault"}</span>
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </Panel>

        <Panel title="Node / save">
          {!selected && <Empty>Select an object ID to fulfill the fault.</Empty>}
          {selected && (
            <div className="space-y-3">
              <p className="font-mono text-xs text-wire">{selected.ref}</p>
              {selectedNode?.faults !== false && (
                <p className="text-sm text-muted">Still a fault. Selecting it called newValuesForObjectWithID:withContext:error:.</p>
              )}
              {selectedNode && selectedNode.faults === false && (
                <dl className="space-y-1 font-mono text-[0.75rem]">
                  {Object.entries(selectedNode.values).map(([k, v]) => (
                    <div key={k} className="flex justify-between gap-3">
                      <dt className="text-subtle">{k}</dt>
                      <dd className="text-fg">{v == null ? "nil" : String(v)}</dd>
                    </div>
                  ))}
                  <div className="flex justify-between gap-3 pt-1">
                    <dt className="text-subtle">version</dt>
                    <dd className="text-fg tabular-nums">{selectedNode.version}</dd>
                  </div>
                </dl>
              )}
              <div className="flex flex-wrap gap-2">
                {selectedEntity.relationships.map((r) => (
                  <Button key={r.name} variant="secondary" size="sm" onClick={() => onExpandRel(r.name)}>
                    {r.name}
                    <ChevronRight className="size-3.5" />
                  </Button>
                ))}
              </div>
              {selected.entity === "Product" && (
                <Button variant="outline" size="sm" onClick={bumpPrice}>
                  PATCH unitPrice + 1
                </Button>
              )}
              <Button variant="ghost" size="sm" onClick={removeSelected}>
                DELETE
              </Button>
            </div>
          )}
        </Panel>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        <Panel title="Payload">
          <pre className="max-h-80 overflow-auto font-mono text-[0.75rem] leading-relaxed text-muted">
            {payload == null ? "—" : JSON.stringify(payload, null, 2)}
          </pre>
        </Panel>
        <Panel title="Wire log">
          {wires.length === 0 && <Empty>No HTTP yet.</Empty>}
          <ol className="space-y-2">
            {wires.map((w) => (
              <li key={w.id} className="flex items-baseline gap-3 font-mono text-[0.75rem]">
                <span className={cn("w-10 shrink-0", w.status >= 400 ? "text-danger" : "text-ok")}>{w.status}</span>
                <span className="w-14 shrink-0 text-wire">{w.method}</span>
                <span className="min-w-0 flex-1 truncate text-muted">{w.url}</span>
              </li>
            ))}
          </ol>
        </Panel>
      </div>

      <section className="rounded-xl bg-surface p-4 shadow-[var(--shadow-border)]">
        <h2 className="text-sm font-medium text-fg">Insert</h2>
        <p className="mt-1 text-xs text-muted">
          obtainPermanentIDsForObjects:error: POSTs the entity so Core Data can assign a permanent object ID before the
          save request.
        </p>
        <div className="mt-3 flex flex-col gap-2 sm:flex-row">
          <input
            value={insertName}
            onChange={(e) => setInsertName(e.target.value)}
            className="h-11 flex-1 rounded-sm bg-raised px-3 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none"
          />
          <Button variant="secondary" onClick={insertProduct}>
            POST Product
          </Button>
        </div>
      </section>
    </div>
  );
}

function Panel({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="rounded-xl bg-surface p-4 shadow-[var(--shadow-border)]">
      <h2 className="mb-3 text-xs font-medium uppercase tracking-[0.14em] text-muted">{title}</h2>
      {children}
    </section>
  );
}

function Empty({ children }: { children: React.ReactNode }) {
  return <p className="text-sm text-subtle">{children}</p>;
}
