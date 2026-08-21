import { entityByName } from "./model";
import type { FilterExpr } from "./predicate";
import type { EntityDef } from "./types";

class Lexer {
  tokens: string[] = [];
  i = 0;
  constructor(input: string) {
    this.tokens = tokenizeOData(input);
  }
  peek(): string | undefined {
    return this.tokens[this.i];
  }
  eat(expected?: string): string {
    const t = this.tokens[this.i];
    if (expected && t !== expected) throw new Error(`Expected ${expected}, got ${t ?? "end"}`);
    if (t === undefined) throw new Error("Unexpected end of $filter");
    this.i += 1;
    return t;
  }
}

function tokenizeOData(input: string): string[] {
  const tokens: string[] = [];
  let i = 0;
  while (i < input.length) {
    const c = input[i]!;
    if (/\s/.test(c)) {
      i += 1;
      continue;
    }
    if (c === "'") {
      i += 1;
      let s = "'";
      while (i < input.length) {
        const ch = input[i]!;
        s += ch;
        i += 1;
        if (ch === "'" && input[i] === "'") {
          s += "'";
          i += 1;
          continue;
        }
        if (ch === "'") break;
      }
      tokens.push(s);
      continue;
    }
    if ("()/,:".includes(c)) {
      tokens.push(c);
      i += 1;
      continue;
    }
    if (/[A-Za-z_]/.test(c)) {
      let s = "";
      while (i < input.length && /[\w]/.test(input[i]!)) {
        s += input[i];
        i += 1;
      }
      tokens.push(s);
      continue;
    }
    if (/[-0-9]/.test(c)) {
      let s = "";
      while (i < input.length && /[0-9.T:+\-Z]/.test(input[i]!)) {
        s += input[i];
        i += 1;
      }
      tokens.push(s);
      continue;
    }
    throw new Error(`Unexpected character ${c} in $filter`);
  }
  return tokens;
}

export function parseODataFilter(input: string, entity: EntityDef): FilterExpr {
  const p = new Lexer(input.trim());
  const expr = parseOr(p, entity);
  if (p.peek() !== undefined) throw new Error(`Unexpected token ${p.peek()}`);
  return expr;
}

function parseOr(p: Lexer, entity: EntityDef): FilterExpr {
  const args = [parseAnd(p, entity)];
  while (p.peek() === "or") {
    p.eat();
    args.push(parseAnd(p, entity));
  }
  return args.length === 1 ? args[0]! : { kind: "logic", op: "or", args };
}

function parseAnd(p: Lexer, entity: EntityDef): FilterExpr {
  const args = [parseNot(p, entity)];
  while (p.peek() === "and") {
    p.eat();
    args.push(parseNot(p, entity));
  }
  return args.length === 1 ? args[0]! : { kind: "logic", op: "and", args };
}

function parseNot(p: Lexer, entity: EntityDef): FilterExpr {
  if (p.peek() === "not") {
    p.eat();
    return { kind: "not", arg: parseNot(p, entity) };
  }
  return parseCmp(p, entity);
}

function parseCmp(p: Lexer, entity: EntityDef): FilterExpr {
  if (p.peek() === "(") {
    p.eat("(");
    const inner = parseOr(p, entity);
    p.eat(")");
    return inner;
  }
  const left = parseValue(p, entity);
  const next = p.peek();
  if (next && ["eq", "ne", "gt", "ge", "lt", "le"].includes(next)) {
    const op = p.eat() as "eq" | "ne" | "gt" | "ge" | "lt" | "le";
    const right = parseValue(p, entity);
    return { kind: "cmp", op, left, right };
  }
  if (next === "in") {
    p.eat();
    p.eat("(");
    const values: FilterExpr[] = [parseValue(p, entity)];
    while (p.peek() === ",") {
      p.eat(",");
      values.push(parseValue(p, entity));
    }
    p.eat(")");
    return { kind: "in", path: left, values };
  }
  return left;
}

function parseValue(p: Lexer, entity: EntityDef): FilterExpr {
  const t = p.peek();
  if (!t) throw new Error("Expected value in $filter");
  if (t.startsWith("'")) {
    p.eat();
    return { kind: "lit", value: t.slice(1, -1).replace(/''/g, "'") };
  }
  if (t === "true") {
    p.eat();
    return { kind: "lit", value: true };
  }
  if (t === "false") {
    p.eat();
    return { kind: "lit", value: false };
  }
  if (t === "null") {
    p.eat();
    return { kind: "lit", value: null };
  }
  if (/^-?\d/.test(t)) {
    p.eat();
    return { kind: "lit", value: t.includes(".") || t.includes("T") ? (t.includes("T") ? t : Number(t)) : Number(t) };
  }
  if (["contains", "startswith", "endswith", "tolower", "toupper"].includes(t)) {
    const name = p.eat();
    p.eat("(");
    const args: FilterExpr[] = [parseValue(p, entity)];
    while (p.peek() === ",") {
      p.eat(",");
      args.push(parseValue(p, entity));
    }
    p.eat(")");
    return { kind: "fn", name, args };
  }
  return parseODataPath(p, entity);
}

function parseODataPath(p: Lexer, entity: EntityDef): FilterExpr {
  const parts: string[] = [odataToCore(p.eat(), entity)];
  let current: EntityDef = entity;
  while (p.peek() === "/") {
    p.eat("/");
    const ident = p.peek();
    if (ident === "any" || ident === "all") {
      const quant = p.eat() as "any" | "all";
      p.eat("(");
      const variable = p.eat();
      p.eat(":");
      const rel = current.relationships.find((r) => r.name === parts[parts.length - 1]);
      const dest = rel ? entityByName(rel.destination) : current;
      const pred = parseOr(p, dest);
      p.eat(")");
      return { kind: "lambda", quant, path: parts, variable, pred };
    }
    const next = p.eat();
    const rel = current.relationships.find((r) => r.odata === next || r.name === next);
    const attr = current.attributes.find((a) => a.odata === next || a.name === next);
    if (rel) {
      parts.push(rel.name);
      current = entityByName(rel.destination);
    } else if (attr) {
      parts.push(attr.name);
    } else {
      parts.push(next);
    }
  }
  return { kind: "path", parts };
}

function odataToCore(name: string, entity: EntityDef): string {
  const attr = entity.attributes.find((a) => a.odata === name || a.name === name);
  if (attr) return attr.name;
  const rel = entity.relationships.find((r) => r.odata === name || r.name === name);
  if (rel) return rel.name;
  return name;
}
