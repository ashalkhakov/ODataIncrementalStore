import { useEffect, useState } from "react";
import { SOURCE_FILES } from "@/lib/odata/source-files";
import { cn } from "@/lib/utils";

export function SourceBrowser() {
  const [active, setActive] = useState<(typeof SOURCE_FILES)[number]["path"]>(
    "Source/ODataIncrementalStore.m",
  );
  const [text, setText] = useState("Loading…");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setText("Loading…");
    setError(null);
    fetch(`/ODataIncrementalStore/${active}`)
      .then((r) => {
        if (!r.ok) throw new Error(`${r.status}`);
        return r.text();
      })
      .then((body) => {
        if (!cancelled) setText(body);
      })
      .catch((err: unknown) => {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      });
    return () => {
      cancelled = true;
    };
  }, [active]);

  return (
    <div className="grid gap-4 lg:grid-cols-[16rem_minmax(0,1fr)]">
      <nav className="flex flex-row gap-1 overflow-x-auto lg:flex-col">
        {SOURCE_FILES.map((file) => (
          <button
            key={file.path}
            type="button"
            onClick={() => setActive(file.path)}
            className={cn(
              "rounded-sm px-3 py-2 text-left font-mono text-xs whitespace-nowrap transition-colors duration-150",
              active === file.path ? "bg-raised text-fg" : "text-muted hover:text-fg",
            )}
          >
            {file.label}
          </button>
        ))}
      </nav>
      <div className="rounded-xl bg-surface p-4 shadow-[var(--shadow-border)]">
        <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
          <p className="font-mono text-xs text-muted">{active}</p>
          <a
            href={`/ODataIncrementalStore/${active}`}
            download
            className="text-xs text-wire hover:text-fg"
          >
            Download file
          </a>
        </div>
        {error && <p className="text-sm text-danger">{error}</p>}
        <pre className="max-h-[70vh] overflow-auto font-mono text-[0.75rem] leading-relaxed text-muted">
          {text}
        </pre>
      </div>
    </div>
  );
}
