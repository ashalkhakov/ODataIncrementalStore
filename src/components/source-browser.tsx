import { useEffect, useState } from "react";
import { SOURCE_FILES, type SourceGroup } from "@/lib/odata/source-files";
import { cn } from "@/lib/utils";

const GROUPS: { id: SourceGroup; label: string }[] = [
  { id: "library", label: "Library" },
  { id: "tests", label: "XCTest" },
  { id: "example", label: "Catalog" },
];

export function SourceBrowser({ initialGroup = "library" }: { initialGroup?: SourceGroup }) {
  const [group, setGroup] = useState<SourceGroup>(initialGroup);
  const files = SOURCE_FILES.filter((f) => f.group === group);
  const [active, setActive] = useState(files[0]?.path ?? SOURCE_FILES[0]!.path);
  const [text, setText] = useState("Loading…");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const first = SOURCE_FILES.find((f) => f.group === group);
    if (first) setActive(first.path);
  }, [group]);

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
      <div className="flex flex-col gap-3">
        <div className="flex flex-wrap gap-1">
          {GROUPS.map((g) => (
            <button
              key={g.id}
              type="button"
              onClick={() => setGroup(g.id)}
              className={cn(
                "rounded-sm px-2 py-1 text-xs",
                group === g.id ? "bg-raised text-fg" : "text-muted hover:text-fg",
              )}
            >
              {g.label}
            </button>
          ))}
        </div>
        <nav className="flex flex-row gap-1 overflow-x-auto lg:flex-col">
          {files.map((file) => (
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
      </div>
      <div className="rounded-xl bg-surface p-4 shadow-[var(--shadow-border)]">
        <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
          <p className="font-mono text-xs text-muted">{active}</p>
          <a href={`/ODataIncrementalStore/${active}`} download className="text-xs text-wire hover:text-fg">
            Download file
          </a>
        </div>
        {error && <p className="text-sm text-danger">{error}</p>}
        <pre className="max-h-[70vh] overflow-auto font-mono text-[0.75rem] leading-relaxed text-muted">{text}</pre>
      </div>
    </div>
  );
}
