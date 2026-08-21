import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { ODataEngine } from "./engine.ts";
import { entityByName, seedData } from "./model.ts";
import { evaluate, parsePredicate, toODataFilter } from "./predicate.ts";
import { translateFetch } from "./translator.ts";
describe("NSPredicate → $filter", () => {
  const product = entityByName("Product");

  it("translates comparisons and boolean constants", () => {
    const ast = parsePredicate("unitPrice > 20 AND discontinued == NO");
    const filter = toODataFilter(ast, product);
    assert.equal(filter, "(UnitPrice gt 20) and (Discontinued eq false)");
  });

  it("translates BEGINSWITH[cd]", () => {
    const ast = parsePredicate('name BEGINSWITH[cd] "c"');
    const filter = toODataFilter(ast, product);
    assert.equal(filter, "startswith(tolower(ProductName), tolower('c'))");
  });

  it("translates navigation paths", () => {
    const ast = parsePredicate('category.name == "Beverages"');
    const filter = toODataFilter(ast, product);
    assert.equal(filter, "Category/CategoryName eq 'Beverages'");
  });

  it("builds a fetch URL with expand, top, orderby", () => {
    const t = translateFetch({
      entity: "Product",
      predicate: "unitPrice > 20",
      sort: [{ key: "name", ascending: true }],
      fetchLimit: 25,
      relationshipKeyPathsForPrefetching: ["category"],
      resultType: "managedObject",
    });
    assert.equal(t.url.includes("$filter=UnitPrice+gt+20") || t.url.includes("$filter=UnitPrice%20gt%20") || t.url.includes("UnitPrice gt 20"), true);
    assert.match(t.url, /\$orderby=ProductName/);
    assert.match(t.url, /\$top=25/);
    assert.match(t.url, /\$expand=Category/);
  });

  it("evaluates against seed data", () => {
    const ast = parsePredicate("unitPrice > 200");
    const rows = seedData().Product.filter((r) => evaluate(ast, r, product, seedData()));
    assert.equal(rows.length, 1);
    assert.equal(rows[0]?.name, "Côte de Blaye");
  });

  it("serves Products through the engine", () => {
    const engine = new ODataEngine();
    const res = engine.handle({
      method: "GET",
      path: "Products",
      query: new URLSearchParams("$filter=UnitPrice gt 200"),
      serviceRoot: "/odata",
    });
    assert.equal(res.status, 200);
    const body = res.body as { value: { ProductName: string }[] };
    assert.equal(body.value.length, 1);
    assert.equal(body.value[0]?.ProductName, "Côte de Blaye");
  });

  it("counts discontinued products", () => {
    const engine = new ODataEngine();
    const res = engine.handle({
      method: "GET",
      path: "Products/$count",
      query: new URLSearchParams("$filter=Discontinued eq true"),
      serviceRoot: "/odata",
    });
    assert.equal(res.status, 200);
    assert.equal(res.text, "1");
  });
});
