import { createFileRoute } from "@tanstack/react-router";
import { SourceBrowser } from "@/components/source-browser";

export const Route = createFileRoute("/source")({ component: SourcePage });

function SourcePage() {
  return (
    <main className="mx-auto max-w-6xl px-4 py-10 sm:px-6">
      <p className="text-xs font-medium uppercase tracking-[0.16em] text-muted">
        This is the library · not the workbench
      </p>
      <h1 className="mt-2 font-display text-4xl tracking-tight text-fg">ODataIncrementalStore</h1>
      <p className="mt-3 max-w-2xl text-sm leading-relaxed text-muted">
        clang, ARC, blocks, non-fragile ABI. On GNUstep this subclasses{" "}
        <a href="https://github.com/ashalkhakov/FreeCoreData" className="text-wire hover:text-fg">
          FreeCoreData
        </a>
        ’s NSIncrementalStore. The headers will not compile against GCC’s libobjc.
      </p>
      <p className="mt-4 flex flex-wrap gap-x-3 gap-y-1 text-sm">
        <a href="/ODataIncrementalStore.zip" className="text-wire hover:text-fg">
          Download package zip
        </a>
        <span className="text-subtle">·</span>
        <a href="/ODataIncrementalStore/GNUmakefile" className="text-wire hover:text-fg">
          GNUmakefile
        </a>
        <span className="text-subtle">·</span>
        <a href="/ODataIncrementalStore/Makefile" className="text-wire hover:text-fg">
          Makefile
        </a>
        <span className="text-subtle">·</span>
        <a href="/ODataIncrementalStore/LICENSE" className="text-wire hover:text-fg">
          LICENSE
        </a>
      </p>
      <div className="mt-8">
        <SourceBrowser />
      </div>
    </main>
  );
}
