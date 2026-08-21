import { i as __toESM } from "../_runtime.mjs";
import { R as require_jsx_runtime } from "../_libs/@tanstack/react-router+[...].mjs";
import { n as require_react } from "../_libs/@radix-ui/react-compose-refs+[...].mjs";
//#region node_modules/.nitro/vite/services/ssr/assets/license-1NBA8iwP.js
var import_react = /* @__PURE__ */ __toESM(require_react());
var import_jsx_runtime = require_jsx_runtime();
function LicensePage() {
	const [text, setText] = (0, import_react.useState)("Loading the GNU General Public License…");
	(0, import_react.useEffect)(() => {
		fetch("/ODataIncrementalStore/LICENSE").then((r) => r.text()).then(setText).catch(() => setText("Could not load LICENSE."));
	}, []);
	return /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("main", {
		className: "mx-auto max-w-3xl px-4 py-10 sm:px-6",
		children: [
			/* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
				className: "text-xs font-medium uppercase tracking-[0.16em] text-muted",
				children: "Copyleft"
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h1", {
				className: "mt-2 font-display text-4xl tracking-tight text-fg",
				children: "GNU GPL v3"
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
				className: "mt-4 text-sm leading-relaxed text-muted",
				children: "ODataIncrementalStore is free software. You may redistribute and modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. Applications that link the store must be GPL-compatible."
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsx)("pre", {
				className: "mt-8 max-h-[70vh] overflow-auto whitespace-pre-wrap rounded-xl bg-surface p-4 font-mono text-[0.75rem] leading-relaxed text-muted shadow-[var(--shadow-border)]",
				children: text
			})
		]
	});
}
//#endregion
export { LicensePage as component };
