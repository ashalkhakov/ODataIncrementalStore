import { entityByName } from "./model";
import { parsePredicate, toODataFilter } from "./predicate";
import type { FetchRequest } from "./types";

export type Translation = {
  path: string;
  query: Record<string, string>;
  url: string;
  method: "GET";
  notes: string[];
  storeMethods: { method: string; detail: string }[];
};

export function translateFetch(request: FetchRequest, serviceRoot = "/odata"): Translation {
  const entity = entityByName(request.entity);
  const query: Record<string, string> = {};
  const notes: string[] = [];
  const storeMethods: { method: string; detail: string }[] = [
    {
      method: "executeRequest:withContext:error:",
      detail: `NSFetchRequest · ${request.entity} · ${request.resultType}`,
    },
  ];

  if (request.predicate?.trim()) {
    const ast = parsePredicate(request.predicate);
    query.$filter = toODataFilter(ast, entity);
    notes.push(`NSPredicate → $filter`);
  }

  if (request.sort.length) {
    query.$orderby = request.sort
      .map((s) => {
        const attr = entity.attributes.find((a) => a.name === s.key);
        const name = attr?.odata ?? s.key;
        return s.ascending ? name : `${name} desc`;
      })
      .join(",");
    notes.push("NSSortDescriptor → $orderby");
  }

  if (request.fetchLimit != null) {
    query.$top = String(request.fetchLimit);
    notes.push("fetchLimit → $top");
  }
  if (request.fetchOffset) {
    query.$skip = String(request.fetchOffset);
    notes.push("fetchOffset → $skip");
  }

  if (request.resultType === "count") {
    const qs = encodeQuery(query);
    const path = `${serviceRoot}/${entity.entitySet}/$count`;
    return {
      path,
      query,
      url: qs ? `${path}?${qs}` : path,
      method: "GET",
      notes: [...notes, "countResultType → /$count"],
      storeMethods,
    };
  }

  if (request.resultType === "dictionary" && request.propertiesToFetch?.length) {
    query.$select = request.propertiesToFetch
      .map((n) => entity.attributes.find((a) => a.name === n)?.odata ?? n)
      .join(",");
    notes.push("propertiesToFetch → $select");
  }

  if (request.relationshipKeyPathsForPrefetching?.length) {
    query.$expand = request.relationshipKeyPathsForPrefetching
      .map((n) => entity.relationships.find((r) => r.name === n)?.odata ?? n)
      .join(",");
    notes.push("relationshipKeyPathsForPrefetching → $expand");
    storeMethods.push({
      method: "newValueForRelationship:forObjectWithID:withContext:error:",
      detail: "Satisfied from $expand payload — no extra round trip",
    });
  }

  if (request.returnsObjectsAsFaults === false) {
    notes.push("returnsObjectsAsFaults = false → materialize NSIncrementalStoreNode now");
    storeMethods.push({
      method: "newValuesForObjectWithID:withContext:error:",
      detail: "Nodes cached from this payload; later faults are local",
    });
  } else if (request.resultType === "managedObject") {
    storeMethods.push({
      method: "newValuesForObjectWithID:withContext:error:",
      detail: "Fired later, per fault, as GET EntitySet(key)",
    });
  }

  const qs = encodeQuery(query);
  const path = `${serviceRoot}/${entity.entitySet}`;
  return {
    path,
    query,
    url: qs ? `${path}?${qs}` : path,
    method: "GET",
    notes,
    storeMethods,
  };
}

function encodeQuery(query: Record<string, string>): string {
  return Object.entries(query)
    .map(([key, value]) => `${key}=${encodeURIComponent(value)}`)
    .join("&");
}

export function keyLiteral(value: string | number): string {
  return typeof value === "string" ? `'${value.replace(/'/g, "''")}'` : String(value);
}

export function resourcePath(entitySet: string, key: Record<string, string | number>): string {
  const entries = Object.entries(key);
  if (entries.length === 1) {
    return `${entitySet}(${keyLiteral(entries[0]![1])})`;
  }
  return `${entitySet}(${entries.map(([k, v]) => `${k}=${keyLiteral(v)}`).join(",")})`;
}
