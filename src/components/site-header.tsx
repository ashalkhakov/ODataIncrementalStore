import { Link, useRouterState } from "@tanstack/react-router";
import { cn } from "@/lib/utils";

const links = [
  { to: "/", label: "Overview" },
  { to: "/source", label: "Objective-C" },
  { to: "/workbench", label: "Workbench" },
  { to: "/docs", label: "Notes" },
  { to: "/license", label: "GPL" },
] as const;

export function SiteHeader() {
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  return (
    <header className="sticky top-0 z-40 border-b border-border/80 bg-bg/85 backdrop-blur-md">
      <div className="mx-auto flex h-14 max-w-6xl items-center justify-between gap-4 px-4 sm:h-16 sm:px-6">
        <Link to="/" className="flex items-baseline gap-2 text-fg no-underline">
          <span className="font-display text-xl tracking-tight">OIS</span>
          <span className="hidden text-xs text-muted sm:inline">Open Incremental Store</span>
        </Link>
        <nav className="flex items-center gap-0.5 overflow-x-auto">
          {links.map((link) => {
            const active = pathname === link.to;
            return (
              <Link
                key={link.to}
                to={link.to}
                className={cn(
                  "rounded-sm px-2.5 py-2 text-sm transition-colors duration-150",
                  active ? "text-fg" : "text-muted hover:text-fg",
                )}
              >
                {link.label}
              </Link>
            );
          })}
        </nav>
      </div>
    </header>
  );
}
