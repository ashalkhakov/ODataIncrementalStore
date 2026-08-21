import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";

export const Route = createFileRoute("/license")({ component: LicensePage });

function LicensePage() {
  const [text, setText] = useState("Loading the GNU General Public License…");
  useEffect(() => {
    fetch("/ODataIncrementalStore/LICENSE")
      .then((r) => r.text())
      .then(setText)
      .catch(() => setText("Could not load LICENSE."));
  }, []);
  return (
    <main className="mx-auto max-w-3xl px-4 py-10 sm:px-6">
      <p className="text-xs font-medium uppercase tracking-[0.16em] text-muted">Copyleft</p>
      <h1 className="mt-2 font-display text-4xl tracking-tight text-fg">GNU GPL v3</h1>
      <p className="mt-4 text-sm leading-relaxed text-muted">
        ODataIncrementalStore is free software. You may redistribute and modify it under the terms of the GNU General
        Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
        option) any later version. Applications that link the store must be GPL-compatible.
      </p>
      <pre className="mt-8 max-h-[70vh] overflow-auto whitespace-pre-wrap rounded-xl bg-surface p-4 font-mono text-[0.75rem] leading-relaxed text-muted shadow-[var(--shadow-border)]">
        {text}
      </pre>
    </main>
  );
}
