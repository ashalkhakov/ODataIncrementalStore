import { i as __toESM } from "../_runtime.mjs";
import { R as require_jsx_runtime, v as Link } from "../_libs/@tanstack/react-router+[...].mjs";
import { n as require_react } from "../_libs/@radix-ui/react-compose-refs+[...].mjs";
import { a as ArrowRight } from "../_libs/lucide-react.mjs";
import { c as entityByName, i as translateFetch, s as SCHEMA } from "./router-CdaHd3Ug.mjs";
import { t as Button } from "./button-DwizoDYl.mjs";
//#region node_modules/.nitro/vite/services/ssr/assets/routes-O_tEwzrU.js
var import_react = /* @__PURE__ */ __toESM(require_react());
var import_jsx_runtime = require_jsx_runtime();
function LiveTranslate() {
	const [predicate, setPredicate] = (0, import_react.useState)("name BEGINSWITH[cd] \"c\" AND unitPrice > 18");
	const request = {
		entity: "Product",
		predicate,
		sort: [{
			key: "name",
			ascending: true
		}],
		fetchLimit: 25,
		relationshipKeyPathsForPrefetching: ["category"],
		resultType: "managedObject"
	};
	const result = (0, import_react.useMemo)(() => {
		try {
			return {
				ok: true,
				t: translateFetch(request)
			};
		} catch (err) {
			return {
				ok: false,
				message: err instanceof Error ? err.message : String(err)
			};
		}
	}, [predicate]);
	const entity = entityByName("Product");
	return /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
		className: "rounded-xl bg-surface p-3 shadow-[var(--shadow-border)] sm:p-5",
		children: [
			/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
				className: "flex items-center justify-between gap-3",
				children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
					className: "text-xs font-medium uppercase tracking-[0.14em] text-muted",
					children: "NSFetchRequest → OData"
				}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
					className: "font-mono text-[0.6875rem] text-subtle",
					children: entity.entitySet
				})]
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsx)("textarea", {
				value: predicate,
				onChange: (e) => setPredicate(e.target.value),
				rows: 2,
				spellCheck: false,
				className: "mt-3 w-full resize-y rounded-md bg-raised px-3 py-2 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none focus:ring-2 focus:ring-accent/40"
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsx)("div", {
				className: "mt-3 overflow-x-auto rounded-md bg-raised px-3 py-3",
				children: result.ok ? /* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
					className: "font-mono text-[0.8125rem] leading-relaxed break-all text-wire",
					children: result.t.url
				}) : /* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
					className: "text-sm text-danger",
					children: result.message
				})
			}),
			result.ok && /* @__PURE__ */ (0, import_jsx_runtime.jsx)("ul", {
				className: "mt-3 flex flex-wrap gap-2",
				children: result.t.notes.map((n) => /* @__PURE__ */ (0, import_jsx_runtime.jsx)("li", {
					className: "rounded-sm bg-bg px-2 py-1 font-mono text-[0.6875rem] text-muted",
					children: n
				}, n))
			})
		]
	});
}
var layers = [
	{
		name: "NSManagedObjectContext",
		hint: "Your app talks only to Core Data"
	},
	{
		name: "NSPersistentStoreCoordinator",
		hint: "Apple Core Data or FreeCoreData on GNUstep"
	},
	{
		name: "ODataIncrementalStore",
		hint: "libobjc2 · executeRequest:withContext:error: · obtainPermanentIDsForObjects:"
	},
	{
		name: "OData v4 HTTP",
		hint: "$filter $expand $orderby POST PATCH DELETE"
	}
];
function StackDiagram() {
	return /* @__PURE__ */ (0, import_jsx_runtime.jsx)("ol", {
		className: "space-y-2",
		children: layers.map((layer, i) => /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("li", {
			className: "rounded-lg bg-surface px-4 py-3 shadow-[var(--shadow-border)]",
			children: [/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("p", {
				className: "font-mono text-sm text-fg",
				children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
					className: "mr-3 font-mono text-[0.6875rem] text-subtle",
					children: String(i + 1).padStart(2, "0")
				}), layer.name]
			}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
				className: "mt-1 pl-8 text-xs text-muted",
				children: layer.hint
			})]
		}, layer.name))
	});
}
function Home() {
	return /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("main", { children: [
		/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("section", {
			className: "mx-auto max-w-6xl px-4 pb-16 pt-12 sm:px-6 sm:pt-20",
			children: [
				/* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
					className: "text-xs font-medium uppercase tracking-[0.18em] text-muted",
					children: "GPL-3.0-or-later · Objective-C 2.0 · libobjc2 · FreeCoreData & Apple"
				}),
				/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h1", {
					className: "mt-4 max-w-3xl font-display text-5xl leading-[1.05] tracking-tight text-fg sm:text-7xl",
					children: "Core Data, over OData."
				}),
				/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("p", {
					className: "mt-6 max-w-xl text-base leading-relaxed text-muted sm:text-lg",
					children: [
						"OIS is an ",
						/* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
							className: "text-fg",
							children: "NSIncrementalStore"
						}),
						" subclass that uses a remote OData service as the persistent store. Fetch requests become query options. Saves become POST, PATCH, and DELETE. ETags become optimistic locks. On GNUstep it subclasses",
						" ",
						/* @__PURE__ */ (0, import_jsx_runtime.jsx)("a", {
							href: "https://github.com/ashalkhakov/FreeCoreData",
							className: "text-wire hover:text-fg",
							children: "FreeCoreData"
						}),
						"."
					]
				}),
				/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
					className: "mt-8 flex flex-wrap gap-3",
					children: [
						/* @__PURE__ */ (0, import_jsx_runtime.jsx)(Button, {
							asChild: true,
							children: /* @__PURE__ */ (0, import_jsx_runtime.jsxs)(Link, {
								to: "/source",
								children: ["Open the Objective-C", /* @__PURE__ */ (0, import_jsx_runtime.jsx)(ArrowRight, { className: "size-4" })]
							})
						}),
						/* @__PURE__ */ (0, import_jsx_runtime.jsx)(Button, {
							asChild: true,
							variant: "secondary",
							children: /* @__PURE__ */ (0, import_jsx_runtime.jsx)("a", {
								href: "/ODataIncrementalStore.zip",
								children: "Download .m / .h zip"
							})
						}),
						/* @__PURE__ */ (0, import_jsx_runtime.jsx)(Button, {
							asChild: true,
							variant: "secondary",
							children: /* @__PURE__ */ (0, import_jsx_runtime.jsx)(Link, {
								to: "/workbench",
								children: "Predicate workbench"
							})
						})
					]
				}),
				/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
					className: "mt-10 overflow-hidden rounded-xl bg-surface shadow-[var(--shadow-border)]",
					children: [/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
						className: "flex flex-wrap items-center justify-between gap-2 border-b border-border px-4 py-3",
						children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
							className: "font-mono text-xs text-muted",
							children: "ODataIncrementalStore.m"
						}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)(Link, {
							to: "/source",
							className: "text-xs text-wire hover:text-fg",
							children: "All 11 implementation files"
						})]
					}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("pre", {
						className: "overflow-x-auto p-4 font-mono text-[0.75rem] leading-relaxed text-wire sm:p-5",
						children: `- (id)executeRequest:(NSPersistentStoreRequest *)request
         withContext:(NSManagedObjectContext *)context
               error:(NSError **)error
{
  if (request.requestType == NSFetchRequestType)
    return [self executeFetch:(NSFetchRequest *)request
                      context:context error:error];
  if (request.requestType == NSSaveRequestType)
    return [self executeSave:(NSSaveChangesRequest *)request error:error];
  return nil;
}`
					})]
				}),
				/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
					className: "mt-10 max-w-xl rounded-xl bg-surface px-4 py-4 shadow-[var(--shadow-border)] sm:px-5",
					children: [
						/* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
							className: "text-xs font-medium uppercase tracking-[0.14em] text-muted",
							children: "clang · libobjc2"
						}),
						/* @__PURE__ */ (0, import_jsx_runtime.jsx)("pre", {
							className: "mt-3 overflow-x-auto font-mono text-[0.75rem] leading-relaxed text-wire",
							children: `clang -fobjc-runtime=gnustep-2.0 -fobjc-arc -fblocks
      -fconstant-string-class=NSConstantString`
						}),
						/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("p", {
							className: "mt-3 text-xs leading-relaxed text-muted",
							children: [
								"GCC’s ",
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
									className: "font-mono text-fg",
									children: "libobjc"
								}),
								" is the fragile ABI: no ARC, no non-fragile ivars, no zeroing weak. The headers refuse it. Use clang."
							]
						})
					]
				})
			]
		}),
		/* @__PURE__ */ (0, import_jsx_runtime.jsx)("section", {
			className: "mx-auto max-w-6xl px-4 pb-16 sm:px-6",
			children: /* @__PURE__ */ (0, import_jsx_runtime.jsx)(LiveTranslate, {})
		}),
		/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("section", {
			className: "mx-auto grid max-w-6xl gap-10 px-4 pb-16 sm:px-6 lg:grid-cols-2",
			children: [/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", { children: [
				/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h2", {
					className: "font-display text-3xl tracking-tight text-fg",
					children: "Why it exists"
				}),
				/* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
					className: "mt-4 text-sm leading-relaxed text-muted",
					children: "Microsoft’s OData4ObjC client was archived in 2013. AFIncrementalStore taught Core Data to speak REST, but never OData. SAP’s SDK is proprietary. If you have an OData v4 service and a Core Data model, there has not been a free, honest store in years."
				}),
				/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("p", {
					className: "mt-3 text-sm leading-relaxed text-muted",
					children: [
						"OIS is that store: GPL, Objective-C 2.0 on libobjc2, sitting on Apple Core Data or",
						" ",
						/* @__PURE__ */ (0, import_jsx_runtime.jsx)("a", {
							href: "https://github.com/ashalkhakov/FreeCoreData",
							className: "text-wire hover:text-fg",
							children: "FreeCoreData"
						}),
						" ",
						"on GNUstep. The workbench on this site is the same translation the",
						" ",
						/* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
							className: "text-fg",
							children: ".m"
						}),
						" files perform."
					]
				})
			] }), /* @__PURE__ */ (0, import_jsx_runtime.jsx)(StackDiagram, {})]
		}),
		/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("section", {
			className: "mx-auto max-w-6xl px-4 pb-20 sm:px-6",
			children: [
				/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h2", {
					className: "font-display text-3xl tracking-tight text-fg",
					children: "Name mapping"
				}),
				/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("p", {
					className: "mt-3 max-w-2xl text-sm text-muted",
					children: [
						"Core Data likes camelCase. Northwind likes PascalCase. The mapper uses",
						" ",
						/* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
							className: "font-mono text-fg",
							children: "userInfo"
						}),
						" overrides, then PascalCase, then the attribute name."
					]
				}),
				/* @__PURE__ */ (0, import_jsx_runtime.jsx)("div", {
					className: "mt-6 overflow-x-auto rounded-xl bg-surface shadow-[var(--shadow-border)]",
					children: /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("table", {
						className: "w-full min-w-[36rem] text-left text-sm",
						children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("thead", {
							className: "border-b border-border text-xs uppercase tracking-wide text-muted",
							children: /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("tr", { children: [
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("th", {
									className: "px-4 py-3 font-medium",
									children: "Entity"
								}),
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("th", {
									className: "px-4 py-3 font-medium",
									children: "Attribute"
								}),
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("th", {
									className: "px-4 py-3 font-medium",
									children: "OData property"
								}),
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("th", {
									className: "px-4 py-3 font-medium",
									children: "EDM"
								})
							] })
						}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("tbody", { children: SCHEMA.entities.flatMap((e) => e.attributes.filter((a) => a.key || a.name === "name" || a.name === "unitPrice").map((a) => ({
							e,
							a
						}))).map(({ e, a }) => /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("tr", {
							className: "border-b border-border/70",
							children: [
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("td", {
									className: "px-4 py-2.5 font-mono text-xs text-fg",
									children: e.name
								}),
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("td", {
									className: "px-4 py-2.5 font-mono text-xs text-muted",
									children: a.name
								}),
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("td", {
									className: "px-4 py-2.5 font-mono text-xs text-wire",
									children: a.odata
								}),
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("td", {
									className: "px-4 py-2.5 font-mono text-xs text-subtle",
									children: a.type
								})
							]
						}, `${e.name}-${a.name}`)) })]
					})
				})
			]
		})
	] });
}
//#endregion
export { Home as component };
