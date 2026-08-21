import { entityByName } from "./model";
import type { EntityDef } from "./types";

export type FilterExpr =
  | { kind: "cmp"; op: CmpOp; left: FilterExpr; right: FilterExpr; options?: string }
  | { kind: "logic"; op: "and" | "or"; args: FilterExpr[] }
  | { kind: "not"; arg: FilterExpr }
  | { kind: "fn"; name: string; args: FilterExpr[] }
  | { kind: "path"; parts: string[] }
  | { kind: "lit"; value: unknown }
  | { kind: "in"; path: FilterExpr; values: FilterExpr[] }
  | { kind: "between"; path: FilterExpr; low: FilterExpr; high: FilterExpr }
  | { kind: "lambda"; quant: "any" | "all"; path: string[]; variable: string; pred: FilterExpr };

export type CmpOp = "eq" | "ne" | "gt" | "ge" | "lt" | "le";

class Parser {
  tokens: string[];
  i = 0;

  constructor(input: string) {
    this.tokens = tokenize(input);
  }

  peek(): string | undefined {
    return this.tokens[this.i];
  }

  eat(expected?: string): string {
    const t = this.tokens[this.i];
    if (expected && t !== expected) {
      throw new Error(`Expected ${expected}, got ${t ?? "end"}`);
    }
    if (t === undefined) throw new Error("Unexpected end of predicate");
    this.i += 1;
    return t;
  }

  parse(): FilterExpr {
    if (this.tokens.length === 0) throw new Error("Empty predicate");
    const expr = this.parseOr();
    if (this.i !== this.tokens.length) {
      throw new Error(`Unexpected token ${this.peek()}`);
    }
    return expr;
  }

  parseOr(): FilterExpr {
    const args = [this.parseAnd()];
    while (this.peek() && /^or$/i.test(this.peek()!)) {
      this.eat();
      args.push(this.parseAnd());
    }
    return args.length === 1 ? args[0]! : { kind: "logic", op: "or", args };
  }

  parseAnd(): FilterExpr {
    const args = [this.parseNot()];
    while (this.peek() && /^and$/i.test(this.peek()!)) {
      this.eat();
      args.push(this.parseNot());
    }
    return args.length === 1 ? args[0]! : { kind: "logic", op: "and", args };
  }

  parseNot(): FilterExpr {
    if (this.peek() && /^not$/i.test(this.peek()!)) {
      this.eat();
      return { kind: "not", arg: this.parseNot() };
    }
    return this.parseCmp();
  }

  parseCmp(): FilterExpr {
    if (this.peek() === "(") {
      this.eat("(");
      const inner = this.parseOr();
      this.eat(")");
      return inner;
    }

    let quant: "any" | "all" | undefined;
    if (this.peek() && /^(any|all)$/i.test(this.peek()!)) {
      quant = this.eat().toLowerCase() as "any" | "all";
    }

    const left = this.parsePath();
    if (quant) {
      const opTok = this.peek();
      if (!opTok) throw new Error("Expected operator after ANY/ALL");
      const { op, options } = parseOperator(this.eat());
      const right = this.parseValue();
      const pred: FilterExpr = { kind: "cmp", op, left: { kind: "path", parts: ["x"] }, right, options };
      return { kind: "lambda", quant, path: left.parts, variable: "x", pred };
    }

    const next = this.peek();
    if (!next) return left;

    if (/^in$/i.test(next)) {
      this.eat();
      const values = this.parseList();
      return { kind: "in", path: left, values };
    }
    if (/^between$/i.test(next)) {
      this.eat();
      const values = this.parseList();
      if (values.length !== 2) throw new Error("BETWEEN expects two values");
      return { kind: "between", path: left, low: values[0]!, high: values[1]! };
    }

    if (isOperatorToken(next)) {
      const { op, options, fn } = parseOperator(this.eat());
      const right = this.parseValue();
      if (fn) {
        return { kind: "fn", name: fn, args: options?.includes("c") ? wrapLower(left, right) : [left, right] };
      }
      return { kind: "cmp", op, left, right, options };
    }

    return left;
  }

  parsePath(): Extract<FilterExpr, { kind: "path" }> {
    const first = this.eat();
    if (!/^[$A-Za-z_][\w$]*$/.test(first)) {
      throw new Error(`Expected key path, got ${first}`);
    }
    const parts = [first];
    while (this.peek() === ".") {
      this.eat(".");
      parts.push(this.eat());
    }
    return { kind: "path", parts };
  }

  parseValue(): FilterExpr {
    const t = this.peek();
    if (!t) throw new Error("Expected value");
    if (t === "(") return { kind: "lit", value: this.parseList().map((v) => (v.kind === "lit" ? v.value : v)) };
    if (t.startsWith('"') || t.startsWith("'")) {
      this.eat();
      return { kind: "lit", value: unquote(t) };
    }
    if (/^(yes|true)$/i.test(t)) {
      this.eat();
      return { kind: "lit", value: true };
    }
    if (/^(no|false)$/i.test(t)) {
      this.eat();
      return { kind: "lit", value: false };
    }
    if (/^(nil|null)$/i.test(t)) {
      this.eat();
      return { kind: "lit", value: null };
    }
    if (/^-?\d/.test(t)) {
      this.eat();
      return { kind: "lit", value: t.includes(".") ? Number(t) : Number(t) };
    }
    return this.parsePath();
  }

  parseList(): FilterExpr[] {
    const t = this.peek();
    if (t === "{" || t === "(") {
      this.eat();
      const close = t === "{" ? "}" : ")";
      const values: FilterExpr[] = [];
      if (this.peek() !== close) {
        values.push(this.parseValue());
        while (this.peek() === ",") {
          this.eat(",");
          values.push(this.parseValue());
        }
      }
      this.eat(close);
      return values;
    }
    return [this.parseValue()];
  }
}

function wrapLower(a: FilterExpr, b: FilterExpr): FilterExpr[] {
  return [
    { kind: "fn", name: "tolower", args: [a] },
    { kind: "fn", name: "tolower", args: [b] },
  ];
}

function isOperatorToken(t: string): boolean {
  return /^(==|!=|<=|>=|=|<|>|contains|beginswith|endswith)/i.test(t);
}

function parseOperator(raw: string): { op: CmpOp; options?: string; fn?: string } {
  const m = raw.match(/^(==|!=|<=|>=|=|<|>|contains|beginswith|endswith)(?:\[([cd]+)\])?$/i);
  if (!m) throw new Error(`Unknown operator ${raw}`);
  const opTok = m[1]!.toLowerCase();
  const options = m[2]?.toLowerCase();
  if (opTok === "contains") return { op: "eq", options, fn: "contains" };
  if (opTok === "beginswith") return { op: "eq", options, fn: "startswith" };
  if (opTok === "endswith") return { op: "eq", options, fn: "endswith" };
  const map: Record<string, CmpOp> = {
    "==": "eq",
    "=": "eq",
    "!=": "ne",
    "<": "lt",
    ">": "gt",
    "<=": "le",
    ">=": "ge",
  };
  return { op: map[opTok] ?? "eq", options };
}

function unquote(t: string): string {
  const q = t[0];
  let s = t.slice(1, -1);
  if (q === '"') s = s.replace(/\\"/g, '"').replace(/\\\\/g, "\\");
  else s = s.replace(/''/g, "'");
  return s;
}

function tokenize(input: string): string[] {
  const tokens: string[] = [];
  let i = 0;
  while (i < input.length) {
    const c = input[i]!;
    if (/\s/.test(c)) {
      i += 1;
      continue;
    }
    if (c === '"' || c === "'") {
      const q = c;
      i += 1;
      let s = q;
      while (i < input.length) {
        const ch = input[i]!;
        s += ch;
        i += 1;
        if (q === "'" && ch === "'" && input[i] === "'") {
          s += input[i];
          i += 1;
          continue;
        }
        if (ch === q && (q === '"' ? s[s.length - 2] !== "\\" : true)) break;
      }
      tokens.push(s);
      continue;
    }
    if ("(){},.".includes(c)) {
      tokens.push(c);
      i += 1;
      continue;
    }
    if (c === "=" || c === "!" || c === "<" || c === ">") {
      let op = c;
      i += 1;
      if (input[i] === "=") {
        op += "=";
        i += 1;
      }
      if (input[i] === "[") {
        const end = input.indexOf("]", i);
        op += input.slice(i, end + 1);
        i = end + 1;
      }
      tokens.push(op);
      continue;
    }
    if (/[A-Za-z_]/.test(c)) {
      let s = "";
      while (i < input.length && /[\w]/.test(input[i]!)) {
        s += input[i];
        i += 1;
      }
      if (input[i] === "[") {
        const end = input.indexOf("]", i);
        s += input.slice(i, end + 1);
        i = end + 1;
      }
      tokens.push(s);
      continue;
    }
    if (/[-0-9]/.test(c)) {
      let s = "";
      if (c === "-") {
        s += c;
        i += 1;
      }
      while (i < input.length && /[0-9.]/.test(input[i]!)) {
        s += input[i];
        i += 1;
      }
      tokens.push(s);
      continue;
    }
    throw new Error(`Unexpected character ${c}`);
  }
  return tokens;
}

export function parsePredicate(input: string): FilterExpr {
  return new Parser(input.trim()).parse();
}

function mapPath(parts: string[], entity: EntityDef): string[] {
  const out: string[] = [];
  let current: EntityDef | undefined = entity;
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i]!;
    if (!current) {
      out.push(part);
      continue;
    }
    const attr = current.attributes.find((a) => a.name === part);
    if (attr) {
      out.push(attr.odata);
      current = undefined;
      continue;
    }
    const rel = current.relationships.find((r) => r.name === part);
    if (rel) {
      out.push(rel.odata);
      current = entityByName(rel.destination);
      continue;
    }
    out.push(part);
    current = undefined;
  }
  return out;
}

export function toODataFilter(expr: FilterExpr, entity: EntityDef): string {
  switch (expr.kind) {
    case "lit":
      return literal(expr.value);
    case "path":
      return mapPath(expr.parts, entity).join("/");
    case "cmp": {
      const l = toODataFilter(expr.left, entity);
      const r = toODataFilter(expr.right, entity);
      if (expr.options?.includes("c")) {
        return `tolower(${l}) ${expr.op} tolower(${r})`;
      }
      return `${l} ${expr.op} ${r}`;
    }
    case "logic":
      return expr.args.map((a) => `(${toODataFilter(a, entity)})`).join(` ${expr.op} `);
    case "not":
      return `not (${toODataFilter(expr.arg, entity)})`;
    case "fn":
      return `${expr.name}(${expr.args.map((a) => toODataFilter(a, entity)).join(", ")})`;
    case "in":
      return `${toODataFilter(expr.path, entity)} in (${expr.values.map((v) => toODataFilter(v, entity)).join(", ")})`;
    case "between":
      return `(${toODataFilter(expr.path, entity)} ge ${toODataFilter(expr.low, entity)} and ${toODataFilter(expr.path, entity)} le ${toODataFilter(expr.high, entity)})`;
    case "lambda": {
      const path = mapPath(expr.path, entity).join("/");
      const innerEntity = resolvePathEntity(entity, expr.path);
      const pred = toODataFilter(expr.pred, innerEntity);
      return `${path}/${expr.quant}(${expr.variable}: ${pred})`;
    }
  }
}

function resolvePathEntity(entity: EntityDef, parts: string[]): EntityDef {
  let current = entity;
  for (const part of parts) {
    const rel = current.relationships.find((r) => r.name === part);
    if (rel) current = entityByName(rel.destination);
  }
  return current;
}

function literal(value: unknown): string {
  if (value === null || value === undefined) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") return String(value);
  if (typeof value === "string") {
    if (/^\d{4}-\d{2}-\d{2}T/.test(value)) return value;
    return `'${value.replace(/'/g, "''")}'`;
  }
  return `'${String(value)}'`;
}

export function evaluate(expr: FilterExpr, row: Record<string, unknown>, entity: EntityDef, collections: Record<string, Record<string, unknown>[]>): boolean {
  const v = evalExpr(expr, row, entity, collections);
  return Boolean(v);
}

function evalExpr(
  expr: FilterExpr,
  row: Record<string, unknown>,
  entity: EntityDef,
  collections: Record<string, Record<string, unknown>[]>,
): unknown {
  switch (expr.kind) {
    case "lit":
      return expr.value;
    case "path":
      return readPath(expr.parts, row, entity, collections);
    case "cmp": {
      let l = evalExpr(expr.left, row, entity, collections);
      let r = evalExpr(expr.right, row, entity, collections);
      if (expr.options?.includes("c") && typeof l === "string" && typeof r === "string") {
        l = l.toLowerCase();
        r = r.toLowerCase();
      }
      return compare(expr.op, l, r);
    }
    case "logic":
      if (expr.op === "and") return expr.args.every((a) => Boolean(evalExpr(a, row, entity, collections)));
      return expr.args.some((a) => Boolean(evalExpr(a, row, entity, collections)));
    case "not":
      return !evalExpr(expr.arg, row, entity, collections);
    case "fn": {
      const args = expr.args.map((a) => evalExpr(a, row, entity, collections));
      const [a, b] = args;
      if (expr.name === "tolower") return String(a ?? "").toLowerCase();
      if (expr.name === "contains") return String(a ?? "").includes(String(b ?? ""));
      if (expr.name === "startswith") return String(a ?? "").startsWith(String(b ?? ""));
      if (expr.name === "endswith") return String(a ?? "").endsWith(String(b ?? ""));
      return false;
    }
    case "in": {
      const val = evalExpr(expr.path, row, entity, collections);
      return expr.values.some((v) => evalExpr(v, row, entity, collections) === val);
    }
    case "between": {
      const val = evalExpr(expr.path, row, entity, collections);
      const low = evalExpr(expr.low, row, entity, collections);
      const high = evalExpr(expr.high, row, entity, collections);
      return compare("ge", val, low) && compare("le", val, high);
    }
    case "lambda": {
      const rel = entity.relationships.find((r) => r.name === expr.path[0]);
      if (!rel) return false;
      const dest = entityByName(rel.destination);
      const related = relatedRows(row, entity, rel.name, collections);
      const pred = (item: Record<string, unknown>) => Boolean(evalExpr(expr.pred, item, dest, collections));
      return expr.quant === "any" ? related.some(pred) : related.every(pred);
    }
  }
}

function readPath(
  parts: string[],
  row: Record<string, unknown>,
  entity: EntityDef,
  collections: Record<string, Record<string, unknown>[]>,
): unknown {
  if (parts.length === 1) return row[parts[0]!];
  const rel = entity.relationships.find((r) => r.name === parts[0]);
  if (!rel) return undefined;
  const related = relatedRows(row, entity, rel.name, collections);
  const dest = entityByName(rel.destination);
  if (rel.toMany) return related.map((r) => readPath(parts.slice(1), r, dest, collections));
  const one = related[0];
  if (!one) return undefined;
  return readPath(parts.slice(1), one, dest, collections);
}

export function relatedRows(
  row: Record<string, unknown>,
  entity: EntityDef,
  relName: string,
  collections: Record<string, Record<string, unknown>[]>,
): Record<string, unknown>[] {
  const rel = entity.relationships.find((r) => r.name === relName);
  if (!rel) return [];
  const dest = entityByName(rel.destination);
  const destRows = collections[dest.name] ?? [];
  if (rel.toMany) {
    const key = entity.attributes.find((a) => a.key)?.name ?? "id";
    const fk = rel.fk ?? `${entity.name[0]!.toLowerCase()}${entity.name.slice(1)}Id`;
    return destRows.filter((d) => d[fk] === row[key]);
  }
  const fk = rel.fk ?? `${rel.name}Id`;
  const destKey = dest.attributes.find((a) => a.key)?.name ?? "id";
  return destRows.filter((d) => d[destKey] === row[fk]);
}

function compare(op: CmpOp, l: unknown, r: unknown): boolean {
  if (l == null || r == null) {
    if (op === "eq") return l == r;
    if (op === "ne") return l != r;
    return false;
  }
  const lv = l as never;
  const rv = r as never;
  switch (op) {
    case "eq":
      return l === r || (typeof l === "number" && typeof r === "number" && l === r);
    case "ne":
      return l !== r;
    case "gt":
      return lv > rv;
    case "ge":
      return lv >= rv;
    case "lt":
      return lv < rv;
    case "le":
      return lv <= rv;
  }
}

export function parseODataFilter(input: string, entity: EntityDef): FilterExpr {
  // The workbench primarily authors NSPredicate format. When executing live
  // OData URLs we also accept a thin OData subset by rewriting to NSPredicate.
  const rewritten = input
    .replace(/\beq\b/g, "==")
    .replace(/\bne\b/g, "!=")
    .replace(/\bgt\b/g, ">")
    .replace(/\bge\b/g, ">=")
    .replace(/\blt\b/g, "<")
    .replace(/\ble\b/g, "<=")
    .replace(/\btrue\b/g, "YES")
    .replace(/\bfalse\b/g, "NO")
    .replace(/null/g, "nil");
  void entity;
  return parsePredicate(rewritten);
}
