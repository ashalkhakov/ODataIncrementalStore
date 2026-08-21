import { entityByName, entityBySet, SCHEMA, seedData } from "./model";
import { parseODataFilter } from "./odata-filter";
import { evaluate, relatedRows } from "./predicate";
import { resourcePath } from "./translator";
import type { EntityDef, ODataResponse, RecordObject } from "./types";

export type ODataRequest = {
  method: string;
  path: string;
  query: URLSearchParams;
  body?: unknown;
  headers?: Record<string, string>;
  serviceRoot?: string;
};

function cloneSeed(): Record<string, RecordObject[]> {
  const src = seedData();
  const out: Record<string, RecordObject[]> = {};
  for (const [k, rows] of Object.entries(src)) {
    out[k] = rows.map((r) => ({ ...r }));
  }
  return out;
}

export class ODataEngine {
  data: Record<string, RecordObject[]>;
  private sequences: Record<string, number> = {};

  constructor(data?: Record<string, RecordObject[]>) {
    this.data = data ?? cloneSeed();
    for (const entity of SCHEMA.entities) {
      const key = entity.attributes.find((a) => a.key);
      if (key?.type === "Edm.String") continue;
      const rows = this.data[entity.name] ?? [];
      const max = rows.reduce((m, r) => Math.max(m, Number(r[key?.name ?? "id"] ?? 0)), 0);
      this.sequences[entity.name] = max;
    }
  }

  clone(): ODataEngine {
    const copy: Record<string, RecordObject[]> = {};
    for (const [k, rows] of Object.entries(this.data)) {
      copy[k] = rows.map((r) => ({ ...r }));
    }
    const next = new ODataEngine(copy);
    next.sequences = { ...this.sequences };
    return next;
  }

  handle(req: ODataRequest): ODataResponse {
    const method = req.method.toUpperCase();
    const raw = req.path.replace(/^\/+/, "").replace(/^odata\/?/, "");
    const serviceRoot = req.serviceRoot ?? "/odata";

    if (raw === "" || raw === "/") {
      return json(200, this.serviceDocument(serviceRoot));
    }
    if (raw === "$metadata") {
      const accept = req.headers?.accept ?? req.headers?.Accept ?? "";
      if (accept.includes("application/json")) {
        return json(200, this.metadataJson());
      }
      return {
        status: 200,
        headers: { "content-type": "application/xml;charset=utf-8" },
        body: this.metadataXml(),
        text: this.metadataXml(),
      };
    }

    const parsed = parseResource(raw);
    if (!parsed) return error(404, "Resource not found");

    try {
      if (parsed.count) {
        const rows = this.querySet(parsed.entitySet, req.query, false);
        return {
          status: 200,
          headers: { "content-type": "text/plain" },
          body: rows.length,
          text: String(rows.length),
        };
      }

      if (parsed.key) {
        const entity = entityBySet(parsed.entitySet);
        const row = this.find(entity, parsed.key);
        if (!row) return error(404, "Not found");

        if (parsed.nav) {
          return this.handleNav(method, entity, row, parsed.nav, req, serviceRoot);
        }

        if (method === "GET") {
          return json(200, this.serializeEntity(entity, row, req.query.get("$expand"), serviceRoot, true));
        }
        if (method === "PATCH" || method === "PUT") {
          return this.patch(entity, row, req.body, req.headers);
        }
        if (method === "DELETE") {
          this.remove(entity, row);
          return { status: 204, headers: {}, body: null };
        }
        return error(405, "Method not allowed");
      }

      const entity = entityBySet(parsed.entitySet);
      if (method === "GET") {
        const withExpand = this.querySet(parsed.entitySet, req.query, true);
        const payload = withExpand.map((row) =>
          this.serializeEntity(entity, row, req.query.get("$expand"), serviceRoot, false),
        );
        const body: Record<string, unknown> = {
          "@odata.context": `${serviceRoot}/$metadata#${entity.entitySet}`,
          value: payload,
        };
        if (req.query.get("$count") === "true") {
          body["@odata.count"] = this.querySet(parsed.entitySet, req.query, false).length;
        }
        return json(200, body);
      }
      if (method === "POST") {
        return this.insert(entity, req.body, serviceRoot);
      }
      return error(405, "Method not allowed");
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return error(400, message);
    }
  }

  private handleNav(
    method: string,
    entity: EntityDef,
    row: RecordObject,
    nav: string,
    req: ODataRequest,
    serviceRoot: string,
  ): ODataResponse {
    const rel = entity.relationships.find((r) => r.odata === nav || r.name === nav);
    if (!rel) return error(404, `Unknown navigation ${nav}`);
    const dest = entityByName(rel.destination);
    const related = relatedRows(row, entity, rel.name, this.data) as RecordObject[];
    if (method !== "GET") return error(405, "Method not allowed");
    if (rel.toMany) {
      return json(200, {
        "@odata.context": `${serviceRoot}/$metadata#${dest.entitySet}`,
        value: related.map((r) => this.serializeEntity(dest, r, null, serviceRoot, false)),
      });
    }
    const one = related[0];
    if (!one) return { status: 204, headers: {}, body: null };
    return json(200, this.serializeEntity(dest, one, null, serviceRoot, true));
  }

  querySet(entitySet: string, query: URLSearchParams, applyPage: boolean): RecordObject[] {
    const entity = entityBySet(entitySet);
    let rows = [...(this.data[entity.name] ?? [])];
    const filter = query.get("$filter");
    if (filter) {
      const ast = parseODataFilter(filter, entity);
      rows = rows.filter((row) => evaluate(ast, row, entity, this.data));
    }
    const orderby = query.get("$orderby");
    if (orderby) {
      rows = sortRows(rows, entity, orderby);
    }
    if (applyPage) {
      const skip = Number(query.get("$skip") ?? 0);
      const top = query.get("$top") != null ? Number(query.get("$top")) : undefined;
      if (skip) rows = rows.slice(skip);
      if (top != null) rows = rows.slice(0, top);
    }
    return rows;
  }

  find(entity: EntityDef, key: Record<string, string | number>): RecordObject | undefined {
    const keyAttr = entity.attributes.find((a) => a.key)!;
    const raw = key[keyAttr.odata] ?? key[keyAttr.name] ?? Object.values(key)[0];
    return (this.data[entity.name] ?? []).find((r) => String(r[keyAttr.name]) === String(raw));
  }

  private insert(entity: EntityDef, body: unknown, serviceRoot: string): ODataResponse {
    const payload = (body ?? {}) as Record<string, unknown>;
    const row = this.fromOData(entity, payload);
    const keyAttr = entity.attributes.find((a) => a.key)!;
    if (row[keyAttr.name] == null) {
      if (keyAttr.type === "Edm.String") {
        row[keyAttr.name] = `NEW${Date.now().toString(36).toUpperCase()}`;
      } else {
        this.sequences[entity.name] = (this.sequences[entity.name] ?? 0) + 1;
        row[keyAttr.name] = this.sequences[entity.name];
      }
    }
    row.__etag = 1;
    this.data[entity.name] = [...(this.data[entity.name] ?? []), row];
    const serialized = this.serializeEntity(entity, row, null, serviceRoot, true);
    return json(201, serialized, {
      location: `${serviceRoot}/${resourcePath(entity.entitySet, { [keyAttr.odata]: row[keyAttr.name] as string | number })}`,
    });
  }

  private patch(entity: EntityDef, row: RecordObject, body: unknown, headers?: Record<string, string>): ODataResponse {
    const ifMatch = headers?.["if-match"] ?? headers?.["If-Match"];
    if (ifMatch && ifMatch !== "*" && ifMatch !== etag(row.__etag)) {
      return error(412, "Precondition Failed — ETag mismatch (optimistic lock)");
    }
    const incoming = this.fromOData(entity, (body ?? {}) as Record<string, unknown>);
    for (const [k, v] of Object.entries(incoming)) {
      if (k === "__etag") continue;
      row[k] = v;
    }
    row.__etag += 1;
    return json(200, this.serializeEntity(entity, row, null, "/odata", true));
  }

  private remove(entity: EntityDef, row: RecordObject) {
    const keyAttr = entity.attributes.find((a) => a.key)!;
    this.data[entity.name] = (this.data[entity.name] ?? []).filter((r) => r[keyAttr.name] !== row[keyAttr.name]);
  }

  serializeEntity(
    entity: EntityDef,
    row: RecordObject,
    expand: string | null,
    serviceRoot: string,
    single: boolean,
  ): Record<string, unknown> {
    const keyAttr = entity.attributes.find((a) => a.key)!;
    const keyVal = row[keyAttr.name] as string | number;
    const out: Record<string, unknown> = {};
    if (single) {
      out["@odata.context"] = `${serviceRoot}/$metadata#${entity.entitySet}/$entity`;
    }
    out["@odata.id"] = `${serviceRoot}/${resourcePath(entity.entitySet, { [keyAttr.odata]: keyVal })}`;
    out["@odata.etag"] = etag(row.__etag);
    for (const attr of entity.attributes) {
      out[attr.odata] = row[attr.name] ?? null;
    }
    const expandSet = new Set(
      (expand ?? "")
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean),
    );
    for (const rel of entity.relationships) {
      if (!expandSet.has(rel.odata) && !expandSet.has(rel.name)) continue;
      const dest = entityByName(rel.destination);
      const related = relatedRows(row, entity, rel.name, this.data) as RecordObject[];
      if (rel.toMany) {
        out[rel.odata] = related.map((r) => this.serializeEntity(dest, r, null, serviceRoot, false));
      } else {
        const one = related[0];
        out[rel.odata] = one ? this.serializeEntity(dest, one, null, serviceRoot, false) : null;
      }
    }
    if (expandSet.size === 0 && single) {
      // omit nav payloads; presence of @odata.id is enough
    }
    return out;
  }

  fromOData(entity: EntityDef, payload: Record<string, unknown>): RecordObject {
    const row: RecordObject = { __etag: 1 };
    for (const attr of entity.attributes) {
      if (payload[attr.odata] !== undefined) row[attr.name] = payload[attr.odata];
      else if (payload[attr.name] !== undefined) row[attr.name] = payload[attr.name];
    }
    return row;
  }

  serviceDocument(serviceRoot: string) {
    return {
      "@odata.context": `${serviceRoot}/$metadata`,
      value: SCHEMA.entities.map((e) => ({ name: e.entitySet, kind: "EntitySet", url: e.entitySet })),
    };
  }

  metadataJson() {
    return {
      $Version: "4.0",
      $EntityContainer: `${SCHEMA.namespace}.${SCHEMA.container}`,
      [SCHEMA.namespace]: Object.fromEntries(
        SCHEMA.entities.map((e) => [
          e.name,
          {
            $Kind: "EntityType",
            $Key: e.attributes.filter((a) => a.key).map((a) => a.odata),
            ...Object.fromEntries(e.attributes.map((a) => [a.odata, { $Type: a.type, $Nullable: a.optional }])),
            ...Object.fromEntries(
              e.relationships.map((r) => [
                r.odata,
                {
                  $Kind: "NavigationProperty",
                  $Type: r.toMany ? `Collection(${SCHEMA.namespace}.${r.destination})` : `${SCHEMA.namespace}.${r.destination}`,
                  $Partner: entityByName(r.destination).relationships.find((x) => x.name === r.inverse)?.odata,
                },
              ]),
            ),
          },
        ]),
      ),
    };
  }

  metadataXml(): string {
    const types = SCHEMA.entities
      .map((e) => {
        const keys = e.attributes
          .filter((a) => a.key)
          .map((a) => `<PropertyRef Name="${a.odata}"/>`)
          .join("");
        const props = e.attributes
          .map(
            (a) =>
              `<Property Name="${a.odata}" Type="${a.type}" Nullable="${a.optional ? "true" : "false"}"/>`,
          )
          .join("");
        const nav = e.relationships
          .map((r) => {
            const type = r.toMany
              ? `Collection(${SCHEMA.namespace}.${r.destination})`
              : `${SCHEMA.namespace}.${r.destination}`;
            return `<NavigationProperty Name="${r.odata}" Type="${type}"/>`;
          })
          .join("");
        return `<EntityType Name="${e.name}"><Key>${keys}</Key>${props}${nav}</EntityType>`;
      })
      .join("");
    const sets = SCHEMA.entities
      .map((e) => `<EntitySet Name="${e.entitySet}" EntityType="${SCHEMA.namespace}.${e.name}"/>`)
      .join("");
    return `<?xml version="1.0" encoding="utf-8"?>\n<edmx:Edmx Version="4.0" xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx"><edmx:DataServices><Schema Namespace="${SCHEMA.namespace}" xmlns="http://docs.oasis-open.org/odata/ns/edm">${types}<EntityContainer Name="${SCHEMA.container}">${sets}</EntityContainer></Schema></edmx:DataServices></edmx:Edmx>`;
  }
}

function sortRows(rows: RecordObject[], entity: EntityDef, orderby: string): RecordObject[] {
  const clauses = orderby.split(",").map((c) => {
    const [raw, dir] = c.trim().split(/\s+/);
    const attr = entity.attributes.find((a) => a.odata === raw || a.name === raw);
    return { key: attr?.name ?? raw!, desc: (dir ?? "asc").toLowerCase() === "desc" };
  });
  return [...rows].sort((a, b) => {
    for (const c of clauses) {
      const av = a[c.key] as never;
      const bv = b[c.key] as never;
      if (av == bv) continue;
      if (av == null) return 1;
      if (bv == null) return -1;
      const cmp = av < bv ? -1 : 1;
      return c.desc ? -cmp : cmp;
    }
    return 0;
  });
}

function parseResource(raw: string): { entitySet: string; key?: Record<string, string | number>; nav?: string; count?: boolean } | null {
  const trimmed = raw.replace(/\/+$/, "");
  if (!trimmed) return null;
  const count = /\/\$count$/.test(trimmed);
  const path = trimmed.replace(/\/\$count$/, "");
  const navMatch = path.match(/^([A-Za-z_][\w]*)(?:\(([^)]+)\))?(?:\/([A-Za-z_][\w]*))?$/);
  if (!navMatch) return null;
  const entitySet = navMatch[1]!;
  const keyRaw = navMatch[2];
  const nav = navMatch[3];
  let key: Record<string, string | number> | undefined;
  if (keyRaw) {
    key = {};
    if (keyRaw.includes("=")) {
      for (const part of keyRaw.split(",")) {
        const [k, v] = part.split("=");
        key[k!.trim()] = parseKeyValue(v!.trim());
      }
    } else {
      key.value = parseKeyValue(keyRaw);
    }
  }
  return { entitySet, key, nav, count };
}

function parseKeyValue(raw: string): string | number {
  if (raw.startsWith("'") && raw.endsWith("'")) return raw.slice(1, -1).replace(/''/g, "'");
  const n = Number(raw);
  return Number.isNaN(n) ? raw : n;
}

function etag(version: number): string {
  return `W/"${version}"`;
}

function json(status: number, body: unknown, extra?: Record<string, string>): ODataResponse {
  return {
    status,
    headers: {
      "content-type": "application/json;odata.metadata=minimal;charset=utf-8",
      odata_version: "4.0",
      ...extra,
    },
    body,
  };
}

function error(status: number, message: string): ODataResponse {
  return {
    status,
    headers: { "content-type": "application/json" },
    body: { error: { code: String(status), message } },
  };
}

let singleton: ODataEngine | null = null;
export function getSharedEngine(): ODataEngine {
  singleton ??= new ODataEngine();
  return singleton;
}
