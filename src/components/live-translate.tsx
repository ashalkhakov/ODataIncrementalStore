import { useMemo, useState } from "react";
import { entityByName } from "@/lib/odata/model";
import { translateFetch } from "@/lib/odata/translator";
import type { FetchRequest } from "@/lib/odata/types";

export function LiveTranslate() {
  const [predicate, setPredicate] = useState('name BEGINSWITH[cd] "c" AND unitPrice > 18');
  const request: FetchRequest = {
    entity: "Product",
    predicate,
    sort: [{ key: "name", ascending: true }],
    fetchLimit: 25,
    relationshipKeyPathsForPrefetching: ["category"],
    resultType: "managedObject",
  };
  const result = useMemo(() => {
    try {
      return { ok: true as const, t: translateFetch(request) };
    } catch (err) {
      return { ok: false as const, message: err instanceof Error ? err.message : String(err) };
    }
  }, [predicate]);

  const entity = entityByName("Product");

  return (
    <div className="rounded-xl bg-surface p-3 shadow-[var(--shadow-border)] sm:p-5">
      <div className="flex items-center justify-between gap-3">
        <p className="text-xs font-medium uppercase tracking-[0.14em] text-muted">NSFetchRequest → OData</p>
        <span className="font-mono text-[0.6875rem] text-subtle">{entity.entitySet}</span>
      </div>
      <textarea
        value={predicate}
        onChange={(e) => setPredicate(e.target.value)}
        rows={2}
        spellCheck={false}
        className="mt-3 w-full resize-y rounded-md bg-raised px-3 py-2 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none focus:ring-2 focus:ring-accent/40"
      />
      <div className="mt-3 overflow-x-auto rounded-md bg-raised px-3 py-3">
        {result.ok ? (
          <code className="font-mono text-[0.8125rem] leading-relaxed break-all text-wire">{result.t.url}</code>
        ) : (
          <p className="text-sm text-danger">{result.message}</p>
        )}
      </div>
      {result.ok && (
        <ul className="mt-3 flex flex-wrap gap-2">
          {result.t.notes.map((n) => (
            <li key={n} className="rounded-sm bg-bg px-2 py-1 font-mono text-[0.6875rem] text-muted">
              {n}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
