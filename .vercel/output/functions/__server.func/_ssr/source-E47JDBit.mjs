import { i as __toESM } from "../_runtime.mjs";
import { R as require_jsx_runtime } from "../_libs/@tanstack/react-router+[...].mjs";
import { n as require_react } from "../_libs/@radix-ui/react-compose-refs+[...].mjs";
import { a as cn } from "./router-CdaHd3Ug.mjs";
//#region node_modules/.nitro/vite/services/ssr/assets/source-E47JDBit.js
var import_react = /* @__PURE__ */ __toESM(require_react());
var import_jsx_runtime = require_jsx_runtime();
var SOURCE_FILES = [
	{
		path: "GNUmakefile",
		label: "GNUmakefile"
	},
	{
		path: "Makefile",
		label: "Makefile"
	},
	{
		path: "Package.swift",
		label: "Package.swift"
	},
	{
		path: "README.md",
		label: "README.md"
	},
	{
		path: "LICENSE",
		label: "LICENSE"
	},
	{
		path: "Tools/ois-filter.m",
		label: "ois-filter.m"
	},
	{
		path: "Source/include/OISRuntime.h",
		label: "OISRuntime.h"
	},
	{
		path: "Source/include/ODataIncrementalStore.h",
		label: "ODataIncrementalStore.h"
	},
	{
		path: "Source/ODataIncrementalStore.m",
		label: "ODataIncrementalStore.m"
	},
	{
		path: "Source/include/ODataPredicateTranslator.h",
		label: "ODataPredicateTranslator.h"
	},
	{
		path: "Source/ODataPredicateTranslator.m",
		label: "ODataPredicateTranslator.m"
	},
	{
		path: "Source/include/ODataQueryBuilder.h",
		label: "ODataQueryBuilder.h"
	},
	{
		path: "Source/ODataQueryBuilder.m",
		label: "ODataQueryBuilder.m"
	},
	{
		path: "Source/include/ODataClient.h",
		label: "ODataClient.h"
	},
	{
		path: "Source/ODataClient.m",
		label: "ODataClient.m"
	},
	{
		path: "Source/include/ODataPropertyMapper.h",
		label: "ODataPropertyMapper.h"
	},
	{
		path: "Source/ODataPropertyMapper.m",
		label: "ODataPropertyMapper.m"
	},
	{
		path: "Source/include/ODataConfiguration.h",
		label: "ODataConfiguration.h"
	},
	{
		path: "Source/ODataConfiguration.m",
		label: "ODataConfiguration.m"
	},
	{
		path: "Source/include/ODataResourceIdentifier.h",
		label: "ODataResourceIdentifier.h"
	},
	{
		path: "Source/ODataResourceIdentifier.m",
		label: "ODataResourceIdentifier.m"
	},
	{
		path: "Source/include/ODataError.h",
		label: "ODataError.h"
	},
	{
		path: "Source/ODataError.m",
		label: "ODataError.m"
	},
	{
		path: "Source/include/OISCoreData.h",
		label: "OISCoreData.h"
	},
	{
		path: "Source/include/OISCoreDataStub.h",
		label: "OISCoreDataStub.h"
	},
	{
		path: "Source/OISCoreDataStub.m",
		label: "OISCoreDataStub.m"
	}
];
function SourceBrowser() {
	const [active, setActive] = (0, import_react.useState)("Source/ODataIncrementalStore.m");
	const [text, setText] = (0, import_react.useState)("Loading…");
	const [error, setError] = (0, import_react.useState)(null);
	(0, import_react.useEffect)(() => {
		let cancelled = false;
		setText("Loading…");
		setError(null);
		fetch(`/ODataIncrementalStore/${active}`).then((r) => {
			if (!r.ok) throw new Error(`${r.status}`);
			return r.text();
		}).then((body) => {
			if (!cancelled) setText(body);
		}).catch((err) => {
			if (!cancelled) setError(err instanceof Error ? err.message : String(err));
		});
		return () => {
			cancelled = true;
		};
	}, [active]);
	return /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
		className: "grid gap-4 lg:grid-cols-[16rem_minmax(0,1fr)]",
		children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("nav", {
			className: "flex flex-row gap-1 overflow-x-auto lg:flex-col",
			children: SOURCE_FILES.map((file) => /* @__PURE__ */ (0, import_jsx_runtime.jsx)("button", {
				type: "button",
				onClick: () => setActive(file.path),
				className: cn("rounded-sm px-3 py-2 text-left font-mono text-xs whitespace-nowrap transition-colors duration-150", active === file.path ? "bg-raised text-fg" : "text-muted hover:text-fg"),
				children: file.label
			}, file.path))
		}), /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
			className: "rounded-xl bg-surface p-4 shadow-[var(--shadow-border)]",
			children: [
				/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
					className: "mb-3 flex flex-wrap items-center justify-between gap-2",
					children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
						className: "font-mono text-xs text-muted",
						children: active
					}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("a", {
						href: `/ODataIncrementalStore/${active}`,
						download: true,
						className: "text-xs text-wire hover:text-fg",
						children: "Download file"
					})]
				}),
				error && /* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
					className: "text-sm text-danger",
					children: error
				}),
				/* @__PURE__ */ (0, import_jsx_runtime.jsx)("pre", {
					className: "max-h-[70vh] overflow-auto font-mono text-[0.75rem] leading-relaxed text-muted",
					children: text
				})
			]
		})]
	});
}
function SourcePage() {
	return /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("main", {
		className: "mx-auto max-w-6xl px-4 py-10 sm:px-6",
		children: [
			/* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
				className: "text-xs font-medium uppercase tracking-[0.16em] text-muted",
				children: "This is the library · not the workbench"
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h1", {
				className: "mt-2 font-display text-4xl tracking-tight text-fg",
				children: "ODataIncrementalStore"
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("p", {
				className: "mt-3 max-w-2xl text-sm leading-relaxed text-muted",
				children: [
					"clang, ARC, blocks, non-fragile ABI. On GNUstep this subclasses",
					" ",
					/* @__PURE__ */ (0, import_jsx_runtime.jsx)("a", {
						href: "https://github.com/ashalkhakov/FreeCoreData",
						className: "text-wire hover:text-fg",
						children: "FreeCoreData"
					}),
					"’s NSIncrementalStore. The headers will not compile against GCC’s libobjc."
				]
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("p", {
				className: "mt-4 flex flex-wrap gap-x-3 gap-y-1 text-sm",
				children: [
					/* @__PURE__ */ (0, import_jsx_runtime.jsx)("a", {
						href: "/ODataIncrementalStore.zip",
						className: "text-wire hover:text-fg",
						children: "Download package zip"
					}),
					/* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
						className: "text-subtle",
						children: "·"
					}),
					/* @__PURE__ */ (0, import_jsx_runtime.jsx)("a", {
						href: "/ODataIncrementalStore/GNUmakefile",
						className: "text-wire hover:text-fg",
						children: "GNUmakefile"
					}),
					/* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
						className: "text-subtle",
						children: "·"
					}),
					/* @__PURE__ */ (0, import_jsx_runtime.jsx)("a", {
						href: "/ODataIncrementalStore/Makefile",
						className: "text-wire hover:text-fg",
						children: "Makefile"
					}),
					/* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
						className: "text-subtle",
						children: "·"
					}),
					/* @__PURE__ */ (0, import_jsx_runtime.jsx)("a", {
						href: "/ODataIncrementalStore/LICENSE",
						className: "text-wire hover:text-fg",
						children: "LICENSE"
					})
				]
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsx)("div", {
				className: "mt-8",
				children: /* @__PURE__ */ (0, import_jsx_runtime.jsx)(SourceBrowser, {})
			})
		]
	});
}
//#endregion
export { SourcePage as component };
