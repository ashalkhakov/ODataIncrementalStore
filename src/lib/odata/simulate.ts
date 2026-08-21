import { entityByName } from "./model";
import { relatedRows } from "./predicate";
import { parsePredicate, evaluate } from "./predicate";
import { resourcePath, translateFetch } from "./translator";
import type { FetchRequest, IncrementalNode, ObjectID, RecordObject, StoreMethodCall, WireEvent } from "./types";
import type { ODataEngine } from "./engine";

let wireSeq = 1;

export type FetchOutcome = {
  translation: ReturnType<typeof translateFetch>;
  objectIDs: ObjectID[];
  nodes: IncrementalNode[];
  dictionaries: Record<string, unknown>[];
  count: number;
  wire: WireEvent;
  methods: StoreMethodCall[];
  json: unknown;
};

export function objectIDFor(entityName: string, row: RecordObject): ObjectID {
  const entity = entityByName(entityName);
  const keyAttr = entity.attributes.find((a) => a.key)!;
  const key = { [keyAttr.odata]: row[keyAttr.name] as string | number };
  return {
    entity: entity.name,
    entitySet: entity.entitySet,
    key,
    ref: resourcePath(entity.entitySet, key),
  };
}

export function executeFetch(engine: ODataEngine, request: FetchRequest, serviceRoot = "/odata"): FetchOutcome {
  const translation = translateFetch(request, serviceRoot);
  const url = new URL(translation.url, "https://store.local");
  const response = engine.handle({
    method: "GET",
    path: url.pathname,
    query: url.searchParams,
    serviceRoot,
  });

  const methods = [...translation.storeMethods];
  const entity = entityByName(request.entity);
  let rows: RecordObject[] = [];

  if (request.resultType === "count") {
    const count = Number(response.text ?? response.body ?? 0);
    return {
      translation,
      objectIDs: [],
      nodes: [],
      dictionaries: [],
      count,
      wire: event("GET", translation.url, response.status, undefined, response.body ?? response.text, "countResultType"),
      methods,
      json: response.body ?? response.text,
    };
  }

  if (response.body && typeof response.body === "object" && "value" in (response.body as object)) {
    const raw = (response.body as { value: Record<string, unknown>[] }).value;
    rows = raw.map((item) => engine.fromOData(entity, item));
  }

  const objectIDs = rows.map((r) => objectIDFor(request.entity, r));
  const nodes: IncrementalNode[] = [];
  const dictionaries: Record<string, unknown>[] = [];

  if (request.resultType === "dictionary") {
    const keys = request.propertiesToFetch?.length
      ? request.propertiesToFetch
      : entity.attributes.map((a) => a.name);
    for (const row of rows) {
      const dict: Record<string, unknown> = {};
      for (const k of keys) dict[k] = row[k];
      dictionaries.push(dict);
    }
  } else if (request.returnsObjectsAsFaults === false || request.relationshipKeyPathsForPrefetching?.length) {
    for (const row of rows) {
      nodes.push(nodeFromRow(request.entity, row, false));
    }
    methods.push({
      method: "newValuesForObjectWithID:withContext:error:",
      detail: `Cached ${nodes.length} NSIncrementalStoreNode(s) from this payload`,
    });
  } else {
    for (const row of rows) {
      nodes.push(nodeFromRow(request.entity, row, true));
    }
  }

  return {
    translation,
    objectIDs,
    nodes,
    dictionaries,
    count: objectIDs.length,
    wire: event("GET", translation.url, response.status, undefined, response.body, translation.notes.join(" · ")),
    methods,
    json: response.body,
  };
}

export function fulfillFault(engine: ODataEngine, id: ObjectID, serviceRoot = "/odata"): { node: IncrementalNode; wire: WireEvent; methods: StoreMethodCall[] } {
  const path = `${serviceRoot}/${id.ref}`;
  const response = engine.handle({ method: "GET", path, query: new URLSearchParams(), serviceRoot });
  const entity = entityByName(id.entity);
  const row = engine.fromOData(entity, (response.body ?? {}) as Record<string, unknown>);
  return {
    node: nodeFromRow(id.entity, row, false),
    wire: event("GET", path, response.status, undefined, response.body, "fault fulfillment"),
    methods: [
      {
        method: "newValuesForObjectWithID:withContext:error:",
        detail: `GET ${id.ref} → NSIncrementalStoreNode version ${row.__etag}`,
      },
    ],
  };
}

export function fulfillRelationship(
  engine: ODataEngine,
  id: ObjectID,
  relationship: string,
  serviceRoot = "/odata",
): { ids: ObjectID[]; json: unknown; wire: WireEvent; methods: StoreMethodCall[] } {
  const entity = entityByName(id.entity);
  const rel = entity.relationships.find((r) => r.name === relationship);
  if (!rel) throw new Error(`Unknown relationship ${relationship}`);
  const path = `${serviceRoot}/${id.ref}/${rel.odata}`;
  const response = engine.handle({ method: "GET", path, query: new URLSearchParams(), serviceRoot });
  const dest = entityByName(rel.destination);
  let ids: ObjectID[] = [];
  const body = response.body;
  if (rel.toMany && body && typeof body === "object" && "value" in body) {
    const rows = (body as { value: Record<string, unknown>[] }).value.map((v) => engine.fromOData(dest, v));
    ids = rows.map((r) => objectIDFor(dest.name, r));
  } else if (!rel.toMany && body && typeof body === "object") {
    const row = engine.fromOData(dest, body as Record<string, unknown>);
    if (row[dest.attributes.find((a) => a.key)!.name] != null) {
      ids = [objectIDFor(dest.name, row)];
    }
  }
  return {
    ids,
    json: body,
    wire: event("GET", path, response.status, undefined, body, `navigation ${rel.odata}`),
    methods: [
      {
        method: "newValueForRelationship:forObjectWithID:withContext:error:",
        detail: `${id.entity}.${relationship} → ${rel.toMany ? `[${ids.length} IDs]` : ids[0]?.ref ?? "nil"}`,
      },
    ],
  };
}

export function saveInsert(
  engine: ODataEngine,
  entityName: string,
  values: Record<string, unknown>,
  serviceRoot = "/odata",
): { id: ObjectID; wire: WireEvent; methods: StoreMethodCall[] } {
  const entity = entityByName(entityName);
  const body: Record<string, unknown> = {};
  for (const attr of entity.attributes) {
    if (values[attr.name] !== undefined) body[attr.odata] = values[attr.name];
  }
  const path = `${serviceRoot}/${entity.entitySet}`;
  const response = engine.handle({ method: "POST", path, query: new URLSearchParams(), body, serviceRoot });
  const row = engine.fromOData(entity, (response.body ?? {}) as Record<string, unknown>);
  return {
    id: objectIDFor(entityName, row),
    wire: event("POST", path, response.status, body, response.body, "obtainPermanentIDs + insert"),
    methods: [
      { method: "obtainPermanentIDsForObjects:error:", detail: `POST ${entity.entitySet} assigns ${objectIDFor(entityName, row).ref}` },
      { method: "executeRequest:withContext:error:", detail: "NSSaveChangesRequest — inserted already persisted" },
    ],
  };
}

export function saveUpdate(
  engine: ODataEngine,
  id: ObjectID,
  values: Record<string, unknown>,
  version: number,
  serviceRoot = "/odata",
): { wire: WireEvent; methods: StoreMethodCall[]; status: number } {
  const entity = entityByName(id.entity);
  const body: Record<string, unknown> = {};
  for (const attr of entity.attributes) {
    if (values[attr.name] !== undefined) body[attr.odata] = values[attr.name];
  }
  const path = `${serviceRoot}/${id.ref}`;
  const response = engine.handle({
    method: "PATCH",
    path,
    query: new URLSearchParams(),
    body,
    headers: { "If-Match": `W/"${version}"` },
    serviceRoot,
  });
  return {
    status: response.status,
    wire: event("PATCH", path, response.status, body, response.body, "optimistic concurrency via ETag"),
    methods: [
      {
        method: "executeRequest:withContext:error:",
        detail: `NSSaveChangesRequest updatedObjects → PATCH ${id.ref} If-Match W/"${version}"`,
      },
    ],
  };
}

export function saveDelete(
  engine: ODataEngine,
  id: ObjectID,
  serviceRoot = "/odata",
): { wire: WireEvent; methods: StoreMethodCall[] } {
  const path = `${serviceRoot}/${id.ref}`;
  const response = engine.handle({ method: "DELETE", path, query: new URLSearchParams(), serviceRoot });
  return {
    wire: event("DELETE", path, response.status, undefined, response.body, "deletedObjects"),
    methods: [{ method: "executeRequest:withContext:error:", detail: `NSSaveChangesRequest deletedObjects → DELETE ${id.ref}` }],
  };
}

export function localRelated(
  engine: ODataEngine,
  id: ObjectID,
  relationship: string,
): ObjectID[] {
  const entity = entityByName(id.entity);
  const row = engine.find(entity, id.key);
  if (!row) return [];
  const rel = entity.relationships.find((r) => r.name === relationship);
  if (!rel) return [];
  const dest = entityByName(rel.destination);
  return (relatedRows(row, entity, rel.name, engine.data) as RecordObject[]).map((r) => objectIDFor(dest.name, r));
}

export function matchesPredicate(engine: ODataEngine, entityName: string, predicate: string): RecordObject[] {
  const entity = entityByName(entityName);
  const ast = parsePredicate(predicate);
  return (engine.data[entityName] ?? []).filter((row) => evaluate(ast, row, entity, engine.data));
}

function nodeFromRow(entityName: string, row: RecordObject, faults: boolean): IncrementalNode {
  const entity = entityByName(entityName);
  const values: Record<string, unknown> = {};
  if (!faults) {
    for (const attr of entity.attributes) values[attr.name] = row[attr.name];
  }
  return {
    objectID: objectIDFor(entityName, row),
    values,
    version: row.__etag,
    faults,
  };
}

function event(method: string, url: string, status: number, requestBody: unknown, responseBody: unknown, note?: string): WireEvent {
  return {
    id: wireSeq++,
    at: Date.now(),
    method,
    url,
    status,
    requestBody,
    responseBody,
    note,
  };
}
