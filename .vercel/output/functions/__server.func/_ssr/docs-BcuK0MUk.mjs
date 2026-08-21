import { R as require_jsx_runtime } from "../_libs/@tanstack/react-router+[...].mjs";
import { s as SCHEMA } from "./router-CdaHd3Ug.mjs";
//#region node_modules/.nitro/vite/services/ssr/assets/docs-BcuK0MUk.js
var import_jsx_runtime = require_jsx_runtime();
function DocsPage() {
	return /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("main", {
		className: "mx-auto max-w-3xl px-4 py-10 sm:px-6",
		children: [
			/* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
				className: "text-xs font-medium uppercase tracking-[0.16em] text-muted",
				children: "Implementation notes"
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h1", {
				className: "mt-2 font-display text-4xl tracking-tight text-fg",
				children: "How the store talks"
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("article", {
				className: "mt-8 space-y-8 text-sm leading-relaxed text-muted",
				children: [
					/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("section", { children: [
						/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h2", {
							className: "font-display text-2xl text-fg",
							children: "Required overrides"
						}),
						/* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
							className: "mt-3",
							children: "Apple requires five methods on an NSIncrementalStore subclass. Everything else is optional. OIS implements exactly those, plus the mapping layer they need."
						}),
						/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("ul", {
							className: "mt-3 space-y-2",
							children: [
								/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("li", { children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
									className: "font-mono text-fg",
									children: "loadMetadata:"
								}), " — GET $metadata, set store UUID and type."] }),
								/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("li", { children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
									className: "font-mono text-fg",
									children: "executeRequest:withContext:error:"
								}), " — fetch becomes GET; save becomes POST / PATCH / DELETE."] }),
								/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("li", { children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
									className: "font-mono text-fg",
									children: "newValuesForObjectWithID:withContext:error:"
								}), " — fault fulfillment, GET EntitySet(key)."] }),
								/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("li", { children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
									className: "font-mono text-fg",
									children: "newValueForRelationship:forObjectWithID:withContext:error:"
								}), " — GET navigation property."] }),
								/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("li", { children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
									className: "font-mono text-fg",
									children: "obtainPermanentIDsForObjects:error:"
								}), " — POST inserted objects so the server can assign keys."] })
							]
						})
					] }),
					/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("section", { children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h2", {
						className: "font-display text-2xl text-fg",
						children: "Predicate translation"
					}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
						className: "mt-3",
						children: "NSComparisonPredicate and NSCompoundPredicate walk into OData operators. CONTAINS / BEGINSWITH / ENDSWITH become functions. The [c] modifier wraps both sides in tolower(). Dotted key paths become navigation segments. ANY/ALL become lambda any/all."
					})] }),
					/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("section", { children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h2", {
						className: "font-display text-2xl text-fg",
						children: "Threading"
					}), /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("p", {
						className: "mt-3",
						children: [
							"Incremental store callbacks are synchronous. On GNUstep the client uses",
							" ",
							/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
								className: "font-mono text-fg",
								children: "NSURLConnection"
							}),
							" send-synchronous (no libdispatch). On Apple it waits on an ",
							/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
								className: "font-mono text-fg",
								children: "NSCondition"
							}),
							". Attach this store to a private-queue context."
						]
					})] }),
					/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("section", { children: [
						/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h2", {
							className: "font-display text-2xl text-fg",
							children: "GNUstep / FreeCoreData"
						}),
						/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("p", {
							className: "mt-3",
							children: [
								"Built for the modern Objective-C runtime — clang,",
								" ",
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
									className: "font-mono text-fg",
									children: "-fobjc-runtime=gnustep-2.0"
								}),
								", ARC, blocks, non-fragile ABI. GCC’s old runtime is rejected at compile time by ",
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
									className: "font-mono text-fg",
									children: "OISRuntime.h"
								}),
								"."
							]
						}),
						/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("p", {
							className: "mt-3",
							children: [
								"On GNUstep the store subclasses",
								" ",
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("a", {
									href: "https://github.com/ashalkhakov/FreeCoreData",
									className: "text-wire hover:text-fg",
									children: "FreeCoreData"
								}),
								"— a Cocotron-based Core Data that actually implements",
								" ",
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
									className: "font-mono text-fg",
									children: "NSIncrementalStore"
								}),
								" and",
								" ",
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
									className: "font-mono text-fg",
									children: "NSIncrementalStoreNode"
								}),
								". Install that framework, then",
								" ",
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
									className: "font-mono text-fg",
									children: "make"
								}),
								". OIS is ARC; FreeCoreData is MRC;",
								" ",
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
									className: "font-mono text-fg",
									children: "new…"
								}),
								" methods return +1 on both sides."
							]
						}),
						/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("p", {
							className: "mt-3",
							children: [
								"Without FreeCoreData, ",
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
									className: "font-mono text-fg",
									children: "make OIS_COREDATA=stub"
								}),
								" compiles the in-tree shim so ",
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
									className: "font-mono text-fg",
									children: "ois-filter"
								}),
								" can still walk NSPredicate. That is not a persistent store."
							]
						})
					] }),
					/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("section", { children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h2", {
						className: "font-display text-2xl text-fg",
						children: "Optimistic locking"
					}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
						className: "mt-3",
						children: "@odata.etag is stored as NSIncrementalStoreNode.version. Updates send If-Match. HTTP 412 becomes an optimistic locking error Core Data can merge."
					})] }),
					/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("section", { children: [
						/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h2", {
							className: "font-display text-2xl text-fg",
							children: "Demo model"
						}),
						/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("p", {
							className: "mt-3",
							children: [
								"The workbench and the ",
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
									className: "font-mono text-fg",
									children: "/odata"
								}),
								" service speak a Northwind-shaped schema:"
							]
						}),
						/* @__PURE__ */ (0, import_jsx_runtime.jsx)("ul", {
							className: "mt-3 space-y-1 font-mono text-xs text-fg",
							children: SCHEMA.entities.map((e) => /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("li", { children: [
								e.name,
								" → ",
								e.entitySet,
								" (",
								e.attributes.length,
								" attrs, ",
								e.relationships.length,
								" rels)"
							] }, e.name))
						})
					] }),
					/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("section", { children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h2", {
						className: "font-display text-2xl text-fg",
						children: "What is out of scope"
					}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
						className: "mt-3",
						children: "$batch change sets, an offline SQLite mirror, delta tokens, unbound functions, and NSBatchDeleteRequest. Those are the next honest increments — not stubs."
					})] })
				]
			})
		]
	});
}
//#endregion
export { DocsPage as component };
