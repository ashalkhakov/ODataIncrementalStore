export type EdmType =
  | "Edm.String"
  | "Edm.Int64"
  | "Edm.Int32"
  | "Edm.Int16"
  | "Edm.Decimal"
  | "Edm.Boolean"
  | "Edm.DateTimeOffset"
  | "Edm.Single"
  | "Edm.Guid";

export type AttributeDef = {
  name: string;
  odata: string;
  type: EdmType;
  optional: boolean;
  key?: boolean;
};

export type RelationshipDef = {
  name: string;
  odata: string;
  destination: string;
  entitySet: string;
  toMany: boolean;
  inverse: string;
  fk?: string;
};

export type EntityDef = {
  name: string;
  entitySet: string;
  attributes: AttributeDef[];
  relationships: RelationshipDef[];
};

export type Schema = {
  namespace: string;
  container: string;
  entities: EntityDef[];
};

export type FetchResultType =
  | "managedObject"
  | "managedObjectID"
  | "dictionary"
  | "count";

export type FetchRequest = {
  entity: string;
  predicate?: string;
  sort: { key: string; ascending: boolean }[];
  fetchLimit?: number;
  fetchOffset?: number;
  propertiesToFetch?: string[];
  relationshipKeyPathsForPrefetching?: string[];
  resultType: FetchResultType;
  returnsObjectsAsFaults?: boolean;
};

export type RecordObject = Record<string, unknown> & {
  __etag: number;
};

export type WireEvent = {
  id: number;
  at: number;
  method: string;
  url: string;
  status: number;
  requestBody?: unknown;
  responseBody?: unknown;
  note?: string;
};

export type StoreMethodCall = {
  method: string;
  detail: string;
};

export type ObjectID = {
  entity: string;
  entitySet: string;
  key: Record<string, string | number>;
  ref: string;
};

export type IncrementalNode = {
  objectID: ObjectID;
  values: Record<string, unknown>;
  version: number;
  faults: boolean;
};

export type ODataResponse = {
  status: number;
  headers: Record<string, string>;
  body: unknown;
  text?: string;
};
