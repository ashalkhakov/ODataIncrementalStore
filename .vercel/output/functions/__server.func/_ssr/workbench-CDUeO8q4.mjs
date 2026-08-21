import { i as __toESM } from "../_runtime.mjs";
import { R as require_jsx_runtime, v as Link } from "../_libs/@tanstack/react-router+[...].mjs";
import { n as require_react } from "../_libs/@radix-ui/react-compose-refs+[...].mjs";
import { i as ChevronRight, n as RotateCcw, r as Play } from "../_libs/lucide-react.mjs";
import { a as cn, c as entityByName, i as translateFetch, n as ODataEngine, o as FETCH_PRESETS, r as resourcePath, s as SCHEMA } from "./router-CdaHd3Ug.mjs";
import { t as Button } from "./button-DwizoDYl.mjs";
//#region node_modules/.nitro/vite/services/ssr/assets/workbench-CDUeO8q4.js
var import_react = /* @__PURE__ */ __toESM(require_react());
var import_jsx_runtime = require_jsx_runtime();
var wireSeq = 1;
function objectIDFor(entityName, row) {
	const entity = entityByName(entityName);
	const keyAttr = entity.attributes.find((a) => a.key);
	const key = { [keyAttr.odata]: row[keyAttr.name] };
	return {
		entity: entity.name,
		entitySet: entity.entitySet,
		key,
		ref: resourcePath(entity.entitySet, key)
	};
}
function executeFetch(engine, request, serviceRoot = "/odata") {
	const translation = translateFetch(request, serviceRoot);
	const url = new URL(translation.url, "https://store.local");
	const response = engine.handle({
		method: "GET",
		path: url.pathname,
		query: url.searchParams,
		serviceRoot
	});
	const methods = [...translation.storeMethods];
	const entity = entityByName(request.entity);
	let rows = [];
	if (request.resultType === "count") return {
		translation,
		objectIDs: [],
		nodes: [],
		dictionaries: [],
		count: Number(response.text ?? response.body ?? 0),
		wire: event("GET", translation.url, response.status, void 0, response.body ?? response.text, "countResultType"),
		methods,
		json: response.body ?? response.text
	};
	if (response.body && typeof response.body === "object" && "value" in response.body) rows = response.body.value.map((item) => engine.fromOData(entity, item));
	const objectIDs = rows.map((r) => objectIDFor(request.entity, r));
	const nodes = [];
	const dictionaries = [];
	if (request.resultType === "dictionary") {
		const keys = request.propertiesToFetch?.length ? request.propertiesToFetch : entity.attributes.map((a) => a.name);
		for (const row of rows) {
			const dict = {};
			for (const k of keys) dict[k] = row[k];
			dictionaries.push(dict);
		}
	} else if (request.returnsObjectsAsFaults === false || request.relationshipKeyPathsForPrefetching?.length) {
		for (const row of rows) nodes.push(nodeFromRow(request.entity, row, false));
		methods.push({
			method: "newValuesForObjectWithID:withContext:error:",
			detail: `Cached ${nodes.length} NSIncrementalStoreNode(s) from this payload`
		});
	} else for (const row of rows) nodes.push(nodeFromRow(request.entity, row, true));
	return {
		translation,
		objectIDs,
		nodes,
		dictionaries,
		count: objectIDs.length,
		wire: event("GET", translation.url, response.status, void 0, response.body, translation.notes.join(" · ")),
		methods,
		json: response.body
	};
}
function fulfillFault(engine, id, serviceRoot = "/odata") {
	const path = `${serviceRoot}/${id.ref}`;
	const response = engine.handle({
		method: "GET",
		path,
		query: new URLSearchParams(),
		serviceRoot
	});
	const entity = entityByName(id.entity);
	const row = engine.fromOData(entity, response.body ?? {});
	return {
		node: nodeFromRow(id.entity, row, false),
		wire: event("GET", path, response.status, void 0, response.body, "fault fulfillment"),
		methods: [{
			method: "newValuesForObjectWithID:withContext:error:",
			detail: `GET ${id.ref} → NSIncrementalStoreNode version ${row.__etag}`
		}]
	};
}
function fulfillRelationship(engine, id, relationship, serviceRoot = "/odata") {
	const rel = entityByName(id.entity).relationships.find((r) => r.name === relationship);
	if (!rel) throw new Error(`Unknown relationship ${relationship}`);
	const path = `${serviceRoot}/${id.ref}/${rel.odata}`;
	const response = engine.handle({
		method: "GET",
		path,
		query: new URLSearchParams(),
		serviceRoot
	});
	const dest = entityByName(rel.destination);
	let ids = [];
	const body = response.body;
	if (rel.toMany && body && typeof body === "object" && "value" in body) ids = body.value.map((v) => engine.fromOData(dest, v)).map((r) => objectIDFor(dest.name, r));
	else if (!rel.toMany && body && typeof body === "object") {
		const row = engine.fromOData(dest, body);
		if (row[dest.attributes.find((a) => a.key).name] != null) ids = [objectIDFor(dest.name, row)];
	}
	return {
		ids,
		json: body,
		wire: event("GET", path, response.status, void 0, body, `navigation ${rel.odata}`),
		methods: [{
			method: "newValueForRelationship:forObjectWithID:withContext:error:",
			detail: `${id.entity}.${relationship} → ${rel.toMany ? `[${ids.length} IDs]` : ids[0]?.ref ?? "nil"}`
		}]
	};
}
function saveInsert(engine, entityName, values, serviceRoot = "/odata") {
	const entity = entityByName(entityName);
	const body = {};
	for (const attr of entity.attributes) if (values[attr.name] !== void 0) body[attr.odata] = values[attr.name];
	const path = `${serviceRoot}/${entity.entitySet}`;
	const response = engine.handle({
		method: "POST",
		path,
		query: new URLSearchParams(),
		body,
		serviceRoot
	});
	const row = engine.fromOData(entity, response.body ?? {});
	return {
		id: objectIDFor(entityName, row),
		wire: event("POST", path, response.status, body, response.body, "obtainPermanentIDs + insert"),
		methods: [{
			method: "obtainPermanentIDsForObjects:error:",
			detail: `POST ${entity.entitySet} assigns ${objectIDFor(entityName, row).ref}`
		}, {
			method: "executeRequest:withContext:error:",
			detail: "NSSaveChangesRequest — inserted already persisted"
		}]
	};
}
function saveUpdate(engine, id, values, version, serviceRoot = "/odata") {
	const entity = entityByName(id.entity);
	const body = {};
	for (const attr of entity.attributes) if (values[attr.name] !== void 0) body[attr.odata] = values[attr.name];
	const path = `${serviceRoot}/${id.ref}`;
	const response = engine.handle({
		method: "PATCH",
		path,
		query: new URLSearchParams(),
		body,
		headers: { "If-Match": `W/"${version}"` },
		serviceRoot
	});
	return {
		status: response.status,
		wire: event("PATCH", path, response.status, body, response.body, "optimistic concurrency via ETag"),
		methods: [{
			method: "executeRequest:withContext:error:",
			detail: `NSSaveChangesRequest updatedObjects → PATCH ${id.ref} If-Match W/"${version}"`
		}]
	};
}
function saveDelete(engine, id, serviceRoot = "/odata") {
	const path = `${serviceRoot}/${id.ref}`;
	const response = engine.handle({
		method: "DELETE",
		path,
		query: new URLSearchParams(),
		serviceRoot
	});
	return {
		wire: event("DELETE", path, response.status, void 0, response.body, "deletedObjects"),
		methods: [{
			method: "executeRequest:withContext:error:",
			detail: `NSSaveChangesRequest deletedObjects → DELETE ${id.ref}`
		}]
	};
}
function nodeFromRow(entityName, row, faults) {
	const entity = entityByName(entityName);
	const values = {};
	if (!faults) for (const attr of entity.attributes) values[attr.name] = row[attr.name];
	return {
		objectID: objectIDFor(entityName, row),
		values,
		version: row.__etag,
		faults
	};
}
function event(method, url, status, requestBody, responseBody, note) {
	return {
		id: wireSeq++,
		at: Date.now(),
		method,
		url,
		status,
		requestBody,
		responseBody,
		note
	};
}
function Badge({ className, children }) {
	return /* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
		className: cn("inline-flex items-center rounded-sm bg-raised px-2 py-0.5 font-mono text-xs uppercase tracking-wide text-muted", className),
		children
	});
}
function freshEngine() {
	return new ODataEngine();
}
var RESULT_TYPES = [
	{
		id: "managedObject",
		label: "objects"
	},
	{
		id: "managedObjectID",
		label: "object IDs"
	},
	{
		id: "dictionary",
		label: "dictionary"
	},
	{
		id: "count",
		label: "count"
	}
];
function Workbench() {
	const [engine] = (0, import_react.useState)(freshEngine);
	const [entity, setEntity] = (0, import_react.useState)("Product");
	const [predicate, setPredicate] = (0, import_react.useState)("unitPrice > 20 AND discontinued == NO");
	const [sortKey, setSortKey] = (0, import_react.useState)("unitPrice");
	const [sortAsc, setSortAsc] = (0, import_react.useState)(false);
	const [limit, setLimit] = (0, import_react.useState)("");
	const [expand, setExpand] = (0, import_react.useState)("");
	const [resultType, setResultType] = (0, import_react.useState)("managedObject");
	const [faults, setFaults] = (0, import_react.useState)(true);
	const [error, setError] = (0, import_react.useState)(null);
	const [wires, setWires] = (0, import_react.useState)([]);
	const [methods, setMethods] = (0, import_react.useState)([]);
	const [ids, setIds] = (0, import_react.useState)([]);
	const [nodes, setNodes] = (0, import_react.useState)([]);
	const [dictionaries, setDictionaries] = (0, import_react.useState)([]);
	const [count, setCount] = (0, import_react.useState)(null);
	const [payload, setPayload] = (0, import_react.useState)(null);
	const [selected, setSelected] = (0, import_react.useState)(null);
	const [insertName, setInsertName] = (0, import_react.useState)("New Blend");
	const entityDef = entityByName(entity);
	const request = (0, import_react.useMemo)(() => ({
		entity,
		predicate: predicate.trim() || void 0,
		sort: sortKey ? [{
			key: sortKey,
			ascending: sortAsc
		}] : [],
		fetchLimit: limit ? Number(limit) : void 0,
		relationshipKeyPathsForPrefetching: expand ? [expand] : void 0,
		resultType,
		returnsObjectsAsFaults: faults,
		propertiesToFetch: resultType === "dictionary" ? [
			"name",
			"unitPrice",
			"id"
		].filter((n) => entityDef.attributes.some((a) => a.name === n)) : void 0
	}), [
		entity,
		predicate,
		sortKey,
		sortAsc,
		limit,
		expand,
		resultType,
		faults,
		entityDef
	]);
	const live = (0, import_react.useMemo)(() => {
		try {
			return {
				ok: true,
				translation: translateFetch(request)
			};
		} catch (err) {
			return {
				ok: false,
				message: err instanceof Error ? err.message : String(err)
			};
		}
	}, [request]);
	function pushWire(w) {
		setWires((prev) => [w, ...prev].slice(0, 24));
	}
	function run() {
		try {
			setError(null);
			const out = executeFetch(engine, request);
			pushWire(out.wire);
			setMethods(out.methods);
			setIds(out.objectIDs);
			setNodes(out.nodes);
			setDictionaries(out.dictionaries);
			setCount(out.count);
			setPayload(out.json);
			setSelected(out.objectIDs[0] ?? null);
		} catch (err) {
			setError(err instanceof Error ? err.message : String(err));
		}
	}
	function applyPreset(label) {
		const preset = FETCH_PRESETS.find((p) => p.label === label);
		if (!preset) return;
		const r = preset.request;
		setEntity(r.entity);
		setPredicate(r.predicate ?? "");
		setSortKey(r.sort[0]?.key ?? "");
		setSortAsc(r.sort[0]?.ascending ?? true);
		setLimit(r.fetchLimit != null ? String(r.fetchLimit) : "");
		setExpand(r.relationshipKeyPathsForPrefetching?.[0] ?? "");
		setResultType(r.resultType);
		setFaults(r.returnsObjectsAsFaults !== false);
	}
	function onSelect(id) {
		setSelected(id);
		const existing = nodes.find((n) => n.objectID.ref === id.ref);
		if (existing && !existing.faults) return;
		try {
			const out = fulfillFault(engine, id);
			pushWire(out.wire);
			setMethods(out.methods);
			setNodes((prev) => {
				const rest = prev.filter((n) => n.objectID.ref !== id.ref);
				return [out.node, ...rest];
			});
			setPayload(out.wire.responseBody);
		} catch (err) {
			setError(err instanceof Error ? err.message : String(err));
		}
	}
	function onExpandRel(relName) {
		if (!selected) return;
		try {
			const out = fulfillRelationship(engine, selected, relName);
			pushWire(out.wire);
			setMethods(out.methods);
			setPayload(out.json);
			if (out.ids.length) {
				setIds(out.ids);
				setSelected(out.ids[0] ?? null);
				setEntity(out.ids[0]?.entity ?? entity);
			}
		} catch (err) {
			setError(err instanceof Error ? err.message : String(err));
		}
	}
	function bumpPrice() {
		if (!selected) return;
		const node = nodes.find((n) => n.objectID.ref === selected.ref);
		const current = Number(node?.values.unitPrice ?? 20);
		try {
			const out = saveUpdate(engine, selected, { unitPrice: current + 1 }, node?.version ?? 1);
			pushWire(out.wire);
			setMethods(out.methods);
			setPayload(out.wire.responseBody);
			if (out.status === 200) onSelect(selected);
		} catch (err) {
			setError(err instanceof Error ? err.message : String(err));
		}
	}
	function insertProduct() {
		try {
			const out = saveInsert(engine, "Product", {
				name: insertName,
				quantityPerUnit: "1 unit",
				unitPrice: 12.5,
				unitsInStock: 8,
				discontinued: false,
				categoryId: 1,
				supplierId: 1
			});
			pushWire(out.wire);
			setMethods(out.methods);
			setIds([out.id, ...ids]);
			setSelected(out.id);
			setEntity("Product");
			setPayload(out.wire.responseBody);
		} catch (err) {
			setError(err instanceof Error ? err.message : String(err));
		}
	}
	function removeSelected() {
		if (!selected) return;
		try {
			const out = saveDelete(engine, selected);
			pushWire(out.wire);
			setMethods(out.methods);
			setIds((prev) => prev.filter((i) => i.ref !== selected.ref));
			setNodes((prev) => prev.filter((n) => n.objectID.ref !== selected.ref));
			setSelected(null);
		} catch (err) {
			setError(err instanceof Error ? err.message : String(err));
		}
	}
	const selectedNode = nodes.find((n) => n.objectID.ref === selected?.ref);
	const selectedEntity = selected ? entityByName(selected.entity) : entityDef;
	return /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
		className: "mx-auto flex max-w-6xl flex-col gap-6 px-4 py-6 sm:px-6",
		children: [
			/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
				className: "flex flex-wrap items-end justify-between gap-4",
				children: [/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", { children: [
					/* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
						className: "text-xs font-medium uppercase tracking-[0.16em] text-muted",
						children: "NSIncrementalStore session"
					}),
					/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h1", {
						className: "font-display text-3xl tracking-tight text-fg sm:text-4xl",
						children: "Workbench"
					}),
					/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("p", {
						className: "mt-2 max-w-xl text-sm leading-relaxed text-muted",
						children: [
							"This page is a JavaScript twin of the translator so you can poke at predicates in the browser. The store itself is Objective-C —",
							" ",
							/* @__PURE__ */ (0, import_jsx_runtime.jsx)(Link, {
								to: "/source",
								className: "text-wire hover:text-fg",
								children: "ODataIncrementalStore.m"
							}),
							"."
						]
					})
				] }), /* @__PURE__ */ (0, import_jsx_runtime.jsxs)(Button, {
					variant: "ghost",
					size: "sm",
					onClick: () => window.location.reload(),
					children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)(RotateCcw, { className: "size-3.5" }), "Reset store"]
				})]
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsx)("div", {
				className: "flex flex-wrap gap-2",
				children: FETCH_PRESETS.map((p) => /* @__PURE__ */ (0, import_jsx_runtime.jsx)("button", {
					type: "button",
					onClick: () => applyPreset(p.label),
					className: "rounded-sm bg-raised px-3 py-2 text-left text-xs text-muted shadow-[var(--shadow-border)] transition-colors duration-150 hover:text-fg",
					children: p.label
				}, p.label))
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("section", {
				className: "rounded-xl bg-surface p-3 shadow-[var(--shadow-border)] sm:p-4",
				children: [
					/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
						className: "grid gap-3 md:grid-cols-2",
						children: [/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("label", {
							className: "flex flex-col gap-1.5 text-xs text-muted",
							children: ["Entity", /* @__PURE__ */ (0, import_jsx_runtime.jsx)("select", {
								value: entity,
								onChange: (e) => {
									setEntity(e.target.value);
									const next = entityByName(e.target.value);
									setSortKey(next.attributes.find((a) => !a.key)?.name ?? "id");
									setExpand("");
								},
								className: "h-11 rounded-sm bg-raised px-3 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none focus:ring-2 focus:ring-accent/40",
								children: SCHEMA.entities.map((e) => /* @__PURE__ */ (0, import_jsx_runtime.jsx)("option", {
									value: e.name,
									children: e.name
								}, e.name))
							})]
						}), /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("label", {
							className: "flex flex-col gap-1.5 text-xs text-muted",
							children: ["Result type", /* @__PURE__ */ (0, import_jsx_runtime.jsx)("select", {
								value: resultType,
								onChange: (e) => setResultType(e.target.value),
								className: "h-11 rounded-sm bg-raised px-3 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none focus:ring-2 focus:ring-accent/40",
								children: RESULT_TYPES.map((t) => /* @__PURE__ */ (0, import_jsx_runtime.jsx)("option", {
									value: t.id,
									children: t.label
								}, t.id))
							})]
						})]
					}),
					/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("label", {
						className: "mt-3 flex flex-col gap-1.5 text-xs text-muted",
						children: ["NSPredicate format", /* @__PURE__ */ (0, import_jsx_runtime.jsx)("textarea", {
							value: predicate,
							onChange: (e) => setPredicate(e.target.value),
							rows: 2,
							spellCheck: false,
							className: "resize-y rounded-md bg-raised px-3 py-2 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none focus:ring-2 focus:ring-accent/40",
							placeholder: "unitPrice > 20 AND name BEGINSWITH[cd] \"c\""
						})]
					}),
					/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
						className: "mt-3 grid gap-3 sm:grid-cols-3",
						children: [
							/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("label", {
								className: "flex flex-col gap-1.5 text-xs text-muted",
								children: ["Sort", /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("select", {
									value: sortKey,
									onChange: (e) => setSortKey(e.target.value),
									className: "h-11 rounded-sm bg-raised px-3 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none",
									children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("option", {
										value: "",
										children: "(none)"
									}), entityDef.attributes.map((a) => /* @__PURE__ */ (0, import_jsx_runtime.jsx)("option", {
										value: a.name,
										children: a.name
									}, a.name))]
								})]
							}),
							/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("label", {
								className: "flex flex-col gap-1.5 text-xs text-muted",
								children: ["Direction", /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("select", {
									value: sortAsc ? "asc" : "desc",
									onChange: (e) => setSortAsc(e.target.value === "asc"),
									className: "h-11 rounded-sm bg-raised px-3 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none",
									children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("option", {
										value: "asc",
										children: "ascending"
									}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("option", {
										value: "desc",
										children: "descending"
									})]
								})]
							}),
							/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("label", {
								className: "flex flex-col gap-1.5 text-xs text-muted",
								children: ["fetchLimit ($top)", /* @__PURE__ */ (0, import_jsx_runtime.jsx)("input", {
									value: limit,
									onChange: (e) => setLimit(e.target.value),
									inputMode: "numeric",
									className: "h-11 rounded-sm bg-raised px-3 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none",
									placeholder: "∞"
								})]
							})
						]
					}),
					/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
						className: "mt-3 flex flex-wrap items-center gap-3",
						children: [
							/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("label", {
								className: "flex flex-col gap-1.5 text-xs text-muted",
								children: ["Prefetch ($expand)", /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("select", {
									value: expand,
									onChange: (e) => setExpand(e.target.value),
									className: "h-11 rounded-sm bg-raised px-3 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none",
									children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("option", {
										value: "",
										children: "(none)"
									}), entityDef.relationships.map((r) => /* @__PURE__ */ (0, import_jsx_runtime.jsx)("option", {
										value: r.name,
										children: r.name
									}, r.name))]
								})]
							}),
							/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("label", {
								className: "mt-5 flex h-11 items-center gap-2 text-sm text-muted",
								children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("input", {
									type: "checkbox",
									checked: faults,
									onChange: (e) => setFaults(e.target.checked),
									className: "size-4 accent-accent"
								}), "return as faults"]
							}),
							/* @__PURE__ */ (0, import_jsx_runtime.jsx)("div", {
								className: "ml-auto pt-5",
								children: /* @__PURE__ */ (0, import_jsx_runtime.jsxs)(Button, {
									onClick: run,
									children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)(Play, { className: "size-3.5" }), "Execute"]
								})
							})
						]
					})
				]
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("section", {
				className: "rounded-lg bg-raised px-4 py-3 shadow-[var(--shadow-border)]",
				children: [/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
					className: "flex flex-wrap items-center gap-2 text-xs text-muted",
					children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)(Badge, { children: "GET" }), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("code", {
						className: "font-mono text-[0.8125rem] break-all text-fg",
						children: live.ok ? live.translation.url : live.message
					})]
				}), live.ok && live.translation.notes.length > 0 && /* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
					className: "mt-2 text-xs text-subtle",
					children: live.translation.notes.join(" · ")
				})]
			}),
			error && /* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
				className: "rounded-md bg-raised px-4 py-3 text-sm text-danger shadow-[var(--shadow-border)]",
				children: error
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
				className: "grid gap-4 lg:grid-cols-3",
				children: [
					/* @__PURE__ */ (0, import_jsx_runtime.jsx)(Panel, {
						title: "Store callbacks",
						children: methods.length === 0 ? /* @__PURE__ */ (0, import_jsx_runtime.jsx)(Empty, { children: "Execute a fetch to see which NSIncrementalStore methods fire." }) : /* @__PURE__ */ (0, import_jsx_runtime.jsx)("ol", {
							className: "space-y-3",
							children: methods.map((m, i) => /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("li", {
								className: "flex gap-3",
								children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
									className: "mt-0.5 font-mono text-[0.6875rem] text-subtle",
									children: String(i + 1).padStart(2, "0")
								}), /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", { children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
									className: "font-mono text-xs text-wire",
									children: m.method
								}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
									className: "mt-1 text-sm text-muted",
									children: m.detail
								})] })]
							}, `${m.method}-${i}`))
						})
					}),
					/* @__PURE__ */ (0, import_jsx_runtime.jsxs)(Panel, {
						title: "Object IDs",
						children: [
							resultType === "count" && count != null && /* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
								className: "font-display text-4xl tabular-nums text-fg",
								children: count
							}),
							resultType === "dictionary" && /* @__PURE__ */ (0, import_jsx_runtime.jsx)("pre", {
								className: "overflow-auto font-mono text-[0.75rem] leading-relaxed text-muted",
								children: JSON.stringify(dictionaries, null, 2)
							}),
							resultType !== "count" && resultType !== "dictionary" && /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("ul", {
								className: "space-y-1",
								children: [ids.length === 0 && /* @__PURE__ */ (0, import_jsx_runtime.jsx)(Empty, { children: "No IDs yet." }), ids.map((id) => {
									const node = nodes.find((n) => n.objectID.ref === id.ref);
									const active = selected?.ref === id.ref;
									return /* @__PURE__ */ (0, import_jsx_runtime.jsx)("li", { children: /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("button", {
										type: "button",
										onClick: () => onSelect(id),
										className: cn("flex w-full items-center justify-between rounded-sm px-2 py-2 text-left font-mono text-xs transition-colors duration-150", active ? "bg-raised text-fg" : "text-muted hover:text-fg"),
										children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", { children: id.ref }), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
											className: "text-subtle",
											children: node?.faults === false ? "node" : "fault"
										})]
									}) }, id.ref);
								})]
							})
						]
					}),
					/* @__PURE__ */ (0, import_jsx_runtime.jsxs)(Panel, {
						title: "Node / save",
						children: [!selected && /* @__PURE__ */ (0, import_jsx_runtime.jsx)(Empty, { children: "Select an object ID to fulfill the fault." }), selected && /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
							className: "space-y-3",
							children: [
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
									className: "font-mono text-xs text-wire",
									children: selected.ref
								}),
								selectedNode?.faults !== false && /* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
									className: "text-sm text-muted",
									children: "Still a fault. Selecting it called newValuesForObjectWithID:withContext:error:."
								}),
								selectedNode && selectedNode.faults === false && /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("dl", {
									className: "space-y-1 font-mono text-[0.75rem]",
									children: [Object.entries(selectedNode.values).map(([k, v]) => /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
										className: "flex justify-between gap-3",
										children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("dt", {
											className: "text-subtle",
											children: k
										}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("dd", {
											className: "text-fg",
											children: v == null ? "nil" : String(v)
										})]
									}, k)), /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
										className: "flex justify-between gap-3 pt-1",
										children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("dt", {
											className: "text-subtle",
											children: "version"
										}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("dd", {
											className: "text-fg tabular-nums",
											children: selectedNode.version
										})]
									})]
								}),
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("div", {
									className: "flex flex-wrap gap-2",
									children: selectedEntity.relationships.map((r) => /* @__PURE__ */ (0, import_jsx_runtime.jsxs)(Button, {
										variant: "secondary",
										size: "sm",
										onClick: () => onExpandRel(r.name),
										children: [r.name, /* @__PURE__ */ (0, import_jsx_runtime.jsx)(ChevronRight, { className: "size-3.5" })]
									}, r.name))
								}),
								selected.entity === "Product" && /* @__PURE__ */ (0, import_jsx_runtime.jsx)(Button, {
									variant: "outline",
									size: "sm",
									onClick: bumpPrice,
									children: "PATCH unitPrice + 1"
								}),
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)(Button, {
									variant: "ghost",
									size: "sm",
									onClick: removeSelected,
									children: "DELETE"
								})
							]
						})]
					})
				]
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
				className: "grid gap-4 lg:grid-cols-2",
				children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)(Panel, {
					title: "Payload",
					children: /* @__PURE__ */ (0, import_jsx_runtime.jsx)("pre", {
						className: "max-h-80 overflow-auto font-mono text-[0.75rem] leading-relaxed text-muted",
						children: payload == null ? "—" : JSON.stringify(payload, null, 2)
					})
				}), /* @__PURE__ */ (0, import_jsx_runtime.jsxs)(Panel, {
					title: "Wire log",
					children: [wires.length === 0 && /* @__PURE__ */ (0, import_jsx_runtime.jsx)(Empty, { children: "No HTTP yet." }), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("ol", {
						className: "space-y-2",
						children: wires.map((w) => /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("li", {
							className: "flex items-baseline gap-3 font-mono text-[0.75rem]",
							children: [
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
									className: cn("w-10 shrink-0", w.status >= 400 ? "text-danger" : "text-ok"),
									children: w.status
								}),
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
									className: "w-14 shrink-0 text-wire",
									children: w.method
								}),
								/* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
									className: "min-w-0 flex-1 truncate text-muted",
									children: w.url
								})
							]
						}, w.id))
					})]
				})]
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("section", {
				className: "rounded-xl bg-surface p-4 shadow-[var(--shadow-border)]",
				children: [
					/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h2", {
						className: "text-sm font-medium text-fg",
						children: "Insert"
					}),
					/* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
						className: "mt-1 text-xs text-muted",
						children: "obtainPermanentIDsForObjects:error: POSTs the entity so Core Data can assign a permanent object ID before the save request."
					}),
					/* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
						className: "mt-3 flex flex-col gap-2 sm:flex-row",
						children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("input", {
							value: insertName,
							onChange: (e) => setInsertName(e.target.value),
							className: "h-11 flex-1 rounded-sm bg-raised px-3 font-mono text-sm text-fg shadow-[var(--shadow-border)] outline-none"
						}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)(Button, {
							variant: "secondary",
							onClick: insertProduct,
							children: "POST Product"
						})]
					})
				]
			})
		]
	});
}
function Panel({ title, children }) {
	return /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("section", {
		className: "rounded-xl bg-surface p-4 shadow-[var(--shadow-border)]",
		children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h2", {
			className: "mb-3 text-xs font-medium uppercase tracking-[0.14em] text-muted",
			children: title
		}), children]
	});
}
function Empty({ children }) {
	return /* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
		className: "text-sm text-subtle",
		children
	});
}
function WorkbenchPage() {
	return /* @__PURE__ */ (0, import_jsx_runtime.jsx)("main", { children: /* @__PURE__ */ (0, import_jsx_runtime.jsx)(Workbench, {}) });
}
//#endregion
export { WorkbenchPage as component };
