import { i as __toESM } from "../_runtime.mjs";
import { R as require_jsx_runtime, _ as createRootRoute, d as useRouterState, g as createFileRoute, h as lazyRouteComponent, l as Scripts, m as Outlet, p as createRouter, u as HeadContent, v as Link, y as useRouter } from "../_libs/@tanstack/react-router+[...].mjs";
import { n as require_react } from "../_libs/@radix-ui/react-compose-refs+[...].mjs";
import { t as TriangleAlert } from "../_libs/lucide-react.mjs";
import { a as union, i as string, n as number, r as object, t as literal$1 } from "../_libs/zod.mjs";
import { n as clsx } from "../_libs/class-variance-authority+clsx.mjs";
import { t as twMerge } from "../_libs/tailwind-merge.mjs";
//#region node_modules/.nitro/vite/services/ssr/assets/model-CbBi3bDq.js
var SCHEMA = {
	namespace: "Northwind",
	container: "Northwind",
	entities: [
		{
			name: "Category",
			entitySet: "Categories",
			attributes: [
				{
					name: "id",
					odata: "CategoryID",
					type: "Edm.Int64",
					optional: false,
					key: true
				},
				{
					name: "name",
					odata: "CategoryName",
					type: "Edm.String",
					optional: false
				},
				{
					name: "detail",
					odata: "Description",
					type: "Edm.String",
					optional: true
				}
			],
			relationships: [{
				name: "products",
				odata: "Products",
				destination: "Product",
				entitySet: "Products",
				toMany: true,
				inverse: "category",
				fk: "categoryId"
			}]
		},
		{
			name: "Supplier",
			entitySet: "Suppliers",
			attributes: [
				{
					name: "id",
					odata: "SupplierID",
					type: "Edm.Int64",
					optional: false,
					key: true
				},
				{
					name: "companyName",
					odata: "CompanyName",
					type: "Edm.String",
					optional: false
				},
				{
					name: "city",
					odata: "City",
					type: "Edm.String",
					optional: true
				},
				{
					name: "country",
					odata: "Country",
					type: "Edm.String",
					optional: true
				}
			],
			relationships: [{
				name: "products",
				odata: "Products",
				destination: "Product",
				entitySet: "Products",
				toMany: true,
				inverse: "supplier",
				fk: "supplierId"
			}]
		},
		{
			name: "Product",
			entitySet: "Products",
			attributes: [
				{
					name: "id",
					odata: "ProductID",
					type: "Edm.Int64",
					optional: false,
					key: true
				},
				{
					name: "name",
					odata: "ProductName",
					type: "Edm.String",
					optional: false
				},
				{
					name: "quantityPerUnit",
					odata: "QuantityPerUnit",
					type: "Edm.String",
					optional: true
				},
				{
					name: "unitPrice",
					odata: "UnitPrice",
					type: "Edm.Decimal",
					optional: false
				},
				{
					name: "unitsInStock",
					odata: "UnitsInStock",
					type: "Edm.Int16",
					optional: false
				},
				{
					name: "discontinued",
					odata: "Discontinued",
					type: "Edm.Boolean",
					optional: false
				},
				{
					name: "categoryId",
					odata: "CategoryID",
					type: "Edm.Int64",
					optional: false
				},
				{
					name: "supplierId",
					odata: "SupplierID",
					type: "Edm.Int64",
					optional: false
				}
			],
			relationships: [
				{
					name: "category",
					odata: "Category",
					destination: "Category",
					entitySet: "Categories",
					toMany: false,
					inverse: "products",
					fk: "categoryId"
				},
				{
					name: "supplier",
					odata: "Supplier",
					destination: "Supplier",
					entitySet: "Suppliers",
					toMany: false,
					inverse: "products",
					fk: "supplierId"
				},
				{
					name: "orderItems",
					odata: "Order_Details",
					destination: "OrderItem",
					entitySet: "OrderItems",
					toMany: true,
					inverse: "product",
					fk: "productId"
				}
			]
		},
		{
			name: "Customer",
			entitySet: "Customers",
			attributes: [
				{
					name: "id",
					odata: "CustomerID",
					type: "Edm.String",
					optional: false,
					key: true
				},
				{
					name: "companyName",
					odata: "CompanyName",
					type: "Edm.String",
					optional: false
				},
				{
					name: "contactName",
					odata: "ContactName",
					type: "Edm.String",
					optional: true
				},
				{
					name: "city",
					odata: "City",
					type: "Edm.String",
					optional: true
				},
				{
					name: "country",
					odata: "Country",
					type: "Edm.String",
					optional: true
				}
			],
			relationships: [{
				name: "orders",
				odata: "Orders",
				destination: "Order",
				entitySet: "Orders",
				toMany: true,
				inverse: "customer",
				fk: "customerId"
			}]
		},
		{
			name: "Order",
			entitySet: "Orders",
			attributes: [
				{
					name: "id",
					odata: "OrderID",
					type: "Edm.Int64",
					optional: false,
					key: true
				},
				{
					name: "orderDate",
					odata: "OrderDate",
					type: "Edm.DateTimeOffset",
					optional: false
				},
				{
					name: "shippedDate",
					odata: "ShippedDate",
					type: "Edm.DateTimeOffset",
					optional: true
				},
				{
					name: "freight",
					odata: "Freight",
					type: "Edm.Decimal",
					optional: false
				},
				{
					name: "shipCity",
					odata: "ShipCity",
					type: "Edm.String",
					optional: true
				},
				{
					name: "customerId",
					odata: "CustomerID",
					type: "Edm.String",
					optional: false
				}
			],
			relationships: [{
				name: "customer",
				odata: "Customer",
				destination: "Customer",
				entitySet: "Customers",
				toMany: false,
				inverse: "orders",
				fk: "customerId"
			}, {
				name: "items",
				odata: "Order_Details",
				destination: "OrderItem",
				entitySet: "OrderItems",
				toMany: true,
				inverse: "order",
				fk: "orderId"
			}]
		},
		{
			name: "OrderItem",
			entitySet: "OrderItems",
			attributes: [
				{
					name: "id",
					odata: "OrderDetailID",
					type: "Edm.Int64",
					optional: false,
					key: true
				},
				{
					name: "quantity",
					odata: "Quantity",
					type: "Edm.Int16",
					optional: false
				},
				{
					name: "unitPrice",
					odata: "UnitPrice",
					type: "Edm.Decimal",
					optional: false
				},
				{
					name: "discount",
					odata: "Discount",
					type: "Edm.Single",
					optional: false
				},
				{
					name: "orderId",
					odata: "OrderID",
					type: "Edm.Int64",
					optional: false
				},
				{
					name: "productId",
					odata: "ProductID",
					type: "Edm.Int64",
					optional: false
				}
			],
			relationships: [{
				name: "order",
				odata: "Order",
				destination: "Order",
				entitySet: "Orders",
				toMany: false,
				inverse: "items",
				fk: "orderId"
			}, {
				name: "product",
				odata: "Product",
				destination: "Product",
				entitySet: "Products",
				toMany: false,
				inverse: "orderItems",
				fk: "productId"
			}]
		}
	]
};
function entityByName(name) {
	const found = SCHEMA.entities.find((e) => e.name === name);
	if (!found) throw new Error(`Unknown entity ${name}`);
	return found;
}
function entityBySet(set) {
	const found = SCHEMA.entities.find((e) => e.entitySet === set);
	if (!found) throw new Error(`Unknown entity set ${set}`);
	return found;
}
function rec(values, etag = 1) {
	return {
		...values,
		__etag: etag
	};
}
function seedData() {
	return {
		Category: [
			rec({
				id: 1,
				name: "Beverages",
				detail: "Soft drinks, coffees, teas, beers"
			}),
			rec({
				id: 2,
				name: "Condiments",
				detail: "Sweet and savory sauces, relishes"
			}),
			rec({
				id: 3,
				name: "Confections",
				detail: "Desserts, candies, and sweet breads"
			}),
			rec({
				id: 4,
				name: "Dairy Products",
				detail: "Cheeses"
			}),
			rec({
				id: 5,
				name: "Produce",
				detail: "Dried fruit and bean curd"
			}),
			rec({
				id: 6,
				name: "Seafood",
				detail: "Seaweed and fish"
			})
		],
		Supplier: [
			rec({
				id: 1,
				companyName: "Exotic Liquids",
				city: "London",
				country: "UK"
			}),
			rec({
				id: 2,
				companyName: "New Orleans Cajun Delights",
				city: "New Orleans",
				country: "USA"
			}),
			rec({
				id: 3,
				companyName: "Grandma Kelly's Homestead",
				city: "Ann Arbor",
				country: "USA"
			}),
			rec({
				id: 4,
				companyName: "Tokyo Traders",
				city: "Tokyo",
				country: "Japan"
			}),
			rec({
				id: 5,
				companyName: "Cooperativa de Quesos",
				city: "Oviedo",
				country: "Spain"
			})
		],
		Product: [
			rec({
				id: 1,
				name: "Chai",
				quantityPerUnit: "10 boxes x 20 bags",
				unitPrice: 18,
				unitsInStock: 39,
				discontinued: false,
				categoryId: 1,
				supplierId: 1
			}),
			rec({
				id: 2,
				name: "Chang",
				quantityPerUnit: "24 - 12 oz bottles",
				unitPrice: 19,
				unitsInStock: 17,
				discontinued: false,
				categoryId: 1,
				supplierId: 1
			}),
			rec({
				id: 3,
				name: "Aniseed Syrup",
				quantityPerUnit: "12 - 550 ml bottles",
				unitPrice: 10,
				unitsInStock: 13,
				discontinued: false,
				categoryId: 2,
				supplierId: 1
			}),
			rec({
				id: 4,
				name: "Chef Anton's Cajun Seasoning",
				quantityPerUnit: "48 - 6 oz jars",
				unitPrice: 22,
				unitsInStock: 53,
				discontinued: false,
				categoryId: 2,
				supplierId: 2
			}),
			rec({
				id: 5,
				name: "Grandma's Boysenberry Spread",
				quantityPerUnit: "12 - 8 oz jars",
				unitPrice: 25,
				unitsInStock: 120,
				discontinued: false,
				categoryId: 2,
				supplierId: 3
			}),
			rec({
				id: 6,
				name: "Uncle Bob's Organic Dried Pears",
				quantityPerUnit: "12 - 1 lb pkgs.",
				unitPrice: 30,
				unitsInStock: 15,
				discontinued: false,
				categoryId: 5,
				supplierId: 3
			}),
			rec({
				id: 7,
				name: "Ikura",
				quantityPerUnit: "12 - 200 ml jars",
				unitPrice: 31,
				unitsInStock: 31,
				discontinued: false,
				categoryId: 6,
				supplierId: 4
			}),
			rec({
				id: 8,
				name: "Queso Cabrales",
				quantityPerUnit: "1 kg pkg.",
				unitPrice: 21,
				unitsInStock: 22,
				discontinued: false,
				categoryId: 4,
				supplierId: 5
			}),
			rec({
				id: 9,
				name: "Konbu",
				quantityPerUnit: "2 kg box",
				unitPrice: 6,
				unitsInStock: 24,
				discontinued: false,
				categoryId: 6,
				supplierId: 4
			}),
			rec({
				id: 10,
				name: "Tofu",
				quantityPerUnit: "40 - 100 g pkgs.",
				unitPrice: 23.25,
				unitsInStock: 35,
				discontinued: false,
				categoryId: 5,
				supplierId: 4
			}),
			rec({
				id: 11,
				name: "Sir Rodney's Marmalade",
				quantityPerUnit: "30 gift boxes",
				unitPrice: 81,
				unitsInStock: 40,
				discontinued: false,
				categoryId: 3,
				supplierId: 3
			}),
			rec({
				id: 12,
				name: "Côte de Blaye",
				quantityPerUnit: "12 - 75 cl bottles",
				unitPrice: 263.5,
				unitsInStock: 17,
				discontinued: false,
				categoryId: 1,
				supplierId: 1
			}),
			rec({
				id: 13,
				name: "Guaraná Fantástica",
				quantityPerUnit: "12 - 355 ml cans",
				unitPrice: 4.5,
				unitsInStock: 20,
				discontinued: true,
				categoryId: 1,
				supplierId: 2
			}),
			rec({
				id: 14,
				name: "NuNuCa Nuß-Nougat-Creme",
				quantityPerUnit: "20 - 450 g glasses",
				unitPrice: 14,
				unitsInStock: 76,
				discontinued: false,
				categoryId: 3,
				supplierId: 3
			})
		],
		Customer: [
			rec({
				id: "ALFKI",
				companyName: "Alfreds Futterkiste",
				contactName: "Maria Anders",
				city: "Berlin",
				country: "Germany"
			}),
			rec({
				id: "ANATR",
				companyName: "Ana Trujillo Emparedados",
				contactName: "Ana Trujillo",
				city: "México D.F.",
				country: "Mexico"
			}),
			rec({
				id: "ANTON",
				companyName: "Antonio Moreno Taquería",
				contactName: "Antonio Moreno",
				city: "México D.F.",
				country: "Mexico"
			}),
			rec({
				id: "AROUT",
				companyName: "Around the Horn",
				contactName: "Thomas Hardy",
				city: "London",
				country: "UK"
			}),
			rec({
				id: "BERGS",
				companyName: "Berglunds snabbköp",
				contactName: "Christina Berglund",
				city: "Luleå",
				country: "Sweden"
			}),
			rec({
				id: "BLAUS",
				companyName: "Blauer See Delikatessen",
				contactName: "Hanna Moos",
				city: "Mannheim",
				country: "Germany"
			})
		],
		Order: [
			rec({
				id: 10248,
				orderDate: "2024-07-04T00:00:00Z",
				shippedDate: "2024-07-16T00:00:00Z",
				freight: 32.38,
				shipCity: "Reims",
				customerId: "ALFKI"
			}),
			rec({
				id: 10249,
				orderDate: "2024-07-05T00:00:00Z",
				shippedDate: "2024-07-10T00:00:00Z",
				freight: 11.61,
				shipCity: "Münster",
				customerId: "ALFKI"
			}),
			rec({
				id: 10250,
				orderDate: "2024-07-08T00:00:00Z",
				shippedDate: "2024-07-12T00:00:00Z",
				freight: 65.83,
				shipCity: "Rio de Janeiro",
				customerId: "ANATR"
			}),
			rec({
				id: 10251,
				orderDate: "2024-07-08T00:00:00Z",
				shippedDate: "2024-07-15T00:00:00Z",
				freight: 41.34,
				shipCity: "Lyon",
				customerId: "ANTON"
			}),
			rec({
				id: 10252,
				orderDate: "2024-07-09T00:00:00Z",
				shippedDate: "2024-07-11T00:00:00Z",
				freight: 51.3,
				shipCity: "Charleroi",
				customerId: "AROUT"
			}),
			rec({
				id: 10253,
				orderDate: "2024-07-10T00:00:00Z",
				shippedDate: null,
				freight: 58.17,
				shipCity: "Rio de Janeiro",
				customerId: "ANATR"
			}),
			rec({
				id: 10254,
				orderDate: "2024-07-11T00:00:00Z",
				shippedDate: "2024-07-23T00:00:00Z",
				freight: 22.98,
				shipCity: "Bern",
				customerId: "BERGS"
			}),
			rec({
				id: 10255,
				orderDate: "2024-07-12T00:00:00Z",
				shippedDate: "2024-07-15T00:00:00Z",
				freight: 148.33,
				shipCity: "Genève",
				customerId: "BLAUS"
			})
		],
		OrderItem: [
			rec({
				id: 1,
				quantity: 12,
				unitPrice: 14,
				discount: 0,
				orderId: 10248,
				productId: 11
			}),
			rec({
				id: 2,
				quantity: 10,
				unitPrice: 18,
				discount: 0,
				orderId: 10248,
				productId: 1
			}),
			rec({
				id: 3,
				quantity: 5,
				unitPrice: 9.8,
				discount: 0,
				orderId: 10249,
				productId: 3
			}),
			rec({
				id: 4,
				quantity: 9,
				unitPrice: 42.4,
				discount: .15,
				orderId: 10250,
				productId: 12
			}),
			rec({
				id: 5,
				quantity: 40,
				unitPrice: 7.7,
				discount: .15,
				orderId: 10250,
				productId: 9
			}),
			rec({
				id: 6,
				quantity: 10,
				unitPrice: 16.8,
				discount: .05,
				orderId: 10251,
				productId: 8
			}),
			rec({
				id: 7,
				quantity: 35,
				unitPrice: 16.8,
				discount: .05,
				orderId: 10251,
				productId: 4
			}),
			rec({
				id: 8,
				quantity: 15,
				unitPrice: 64.8,
				discount: .05,
				orderId: 10252,
				productId: 11
			}),
			rec({
				id: 9,
				quantity: 21,
				unitPrice: 2,
				discount: 0,
				orderId: 10252,
				productId: 13
			}),
			rec({
				id: 10,
				quantity: 20,
				unitPrice: 10,
				discount: .2,
				orderId: 10253,
				productId: 3
			}),
			rec({
				id: 11,
				quantity: 12,
				unitPrice: 18,
				discount: 0,
				orderId: 10254,
				productId: 1
			}),
			rec({
				id: 12,
				quantity: 6,
				unitPrice: 31,
				discount: 0,
				orderId: 10254,
				productId: 7
			}),
			rec({
				id: 13,
				quantity: 15,
				unitPrice: 15.2,
				discount: 0,
				orderId: 10255,
				productId: 2
			}),
			rec({
				id: 14,
				quantity: 2,
				unitPrice: 263.5,
				discount: 0,
				orderId: 10255,
				productId: 12
			}),
			rec({
				id: 15,
				quantity: 20,
				unitPrice: 23.25,
				discount: 0,
				orderId: 10249,
				productId: 10
			})
		]
	};
}
var FETCH_PRESETS = [
	{
		label: "All products",
		request: {
			entity: "Product",
			sort: [{
				key: "name",
				ascending: true
			}],
			resultType: "managedObject"
		}
	},
	{
		label: "Priced over 20, in stock",
		request: {
			entity: "Product",
			predicate: "unitPrice > 20 AND unitsInStock > 0 AND discontinued == NO",
			sort: [{
				key: "unitPrice",
				ascending: false
			}],
			resultType: "managedObject"
		}
	},
	{
		label: "Beverages, expand category",
		request: {
			entity: "Product",
			predicate: "category.name == \"Beverages\"",
			sort: [{
				key: "name",
				ascending: true
			}],
			relationshipKeyPathsForPrefetching: ["category"],
			resultType: "managedObject"
		}
	},
	{
		label: "Top 5 by price (dictionary)",
		request: {
			entity: "Product",
			sort: [{
				key: "unitPrice",
				ascending: false
			}],
			fetchLimit: 5,
			propertiesToFetch: ["name", "unitPrice"],
			resultType: "dictionary"
		}
	},
	{
		label: "Count discontinued",
		request: {
			entity: "Product",
			predicate: "discontinued == YES",
			sort: [],
			resultType: "count"
		}
	},
	{
		label: "German customers",
		request: {
			entity: "Customer",
			predicate: "country == \"Germany\"",
			sort: [{
				key: "companyName",
				ascending: true
			}],
			resultType: "managedObject"
		}
	},
	{
		label: "Unshipped orders, expand customer",
		request: {
			entity: "Order",
			predicate: "shippedDate == nil",
			sort: [{
				key: "orderDate",
				ascending: false
			}],
			relationshipKeyPathsForPrefetching: ["customer"],
			resultType: "managedObject"
		}
	},
	{
		label: "Orders for ALFKI",
		request: {
			entity: "Order",
			predicate: "customerId == \"ALFKI\"",
			sort: [{
				key: "orderDate",
				ascending: true
			}],
			relationshipKeyPathsForPrefetching: ["items"],
			resultType: "managedObject"
		}
	},
	{
		label: "Name begins with C",
		request: {
			entity: "Product",
			predicate: "name BEGINSWITH[cd] \"c\"",
			sort: [{
				key: "name",
				ascending: true
			}],
			resultType: "managedObject"
		}
	}
];
//#endregion
//#region node_modules/.nitro/vite/services/ssr/assets/router-CdaHd3Ug.js
var import_react = /* @__PURE__ */ __toESM(require_react());
var import_jsx_runtime = require_jsx_runtime();
var __defProp = Object.defineProperty;
var __exportAll = (all, no_symbols) => {
	let target = {};
	for (var name in all) __defProp(target, name, {
		get: all[name],
		enumerable: true
	});
	if (!no_symbols) __defProp(target, Symbol.toStringTag, { value: "Module" });
	return target;
};
function AppErrorComponent({ error }) {
	return /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("main", {
		className: "flex min-h-screen flex-col items-center justify-center gap-3 px-6 text-center bg-zinc-50 text-zinc-900 dark:bg-zinc-950 dark:text-zinc-50",
		children: [
			/* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
				className: "text-red-500",
				"aria-hidden": "true",
				children: /* @__PURE__ */ (0, import_jsx_runtime.jsx)(TriangleAlert, {
					className: "size-10",
					strokeWidth: 2
				})
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsx)("h1", {
				className: "text-lg font-semibold",
				children: "Something went wrong"
			}),
			/* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", {
				className: "max-w-md text-sm break-words text-zinc-500 dark:text-zinc-400",
				children: error.message || "An unexpected error occurred. Try reloading the page."
			})
		]
	});
}
/**
* App-wide client provider mounted once near the root (in `src/routes/__root.tsx`):
*
*   <AuthProvider><Outlet /></AuthProvider>
*
* Better Auth's React client (`@/lib/auth/client`) needs NO context provider —
* its `useSession()` works standalone — so this is a passthrough today. It's
* kept as the single, stable mount point for any future client-side providers
* (e.g. a toast or theme provider) without churning the root shell.
*/
function AuthProvider({ children }) {
	return /* @__PURE__ */ (0, import_jsx_runtime.jsx)(import_jsx_runtime.Fragment, { children });
}
function isGrokEmbedderOrigin(origin) {
	try {
		const url = new URL(origin);
		if (url.protocol !== "https:" && url.protocol !== "http:") return false;
		const host = url.hostname.toLowerCase();
		if (host === "grok.com" || host.endsWith(".grok.com")) return true;
		if (host === "localhost" || host === "127.0.0.1" || host === "[::1]") return true;
		return false;
	} catch {
		return false;
	}
}
function isSandboxPreviewGuestHost(hostname) {
	const host = hostname.toLowerCase();
	return host === "grok-sandbox.com" || host.endsWith(".grok-sandbox.com");
}
function isRemintPreviewPair(guestHost, parentHost) {
	const guest = guestHost.toLowerCase();
	const parent = parentHost.toLowerCase();
	const i = guest.indexOf(".preview.");
	if (i <= 0) return false;
	const label = guest.slice(0, i);
	const rest = guest.slice(i + 9);
	if (label.includes(".") || !rest.includes(".")) return false;
	return parent === rest || parent === `grok.${rest}`;
}
function resolveParentEmbedderOrigin(parentIsSelf, referrer, ancestorOrigin, guestHostname = "") {
	if (parentIsSelf) return null;
	for (const candidate of [referrer, ancestorOrigin ?? ""].filter(Boolean)) try {
		const url = new URL(candidate.includes("://") ? candidate : `https://${candidate}`);
		if (url.protocol !== "https:" && url.protocol !== "http:") continue;
		if (isGrokEmbedderOrigin(url.origin)) return url.origin;
		if (isSandboxPreviewGuestHost(guestHostname) || isRemintPreviewPair(guestHostname, url.hostname)) return url.origin;
	} catch {}
	return null;
}
/**
* Guest side of the grok-web ↔ sandbox preview postMessage bridge.
*
* Activates only when this page is framed by an allowlisted Grok embedder.
* Top-level runs (download/export, local `npm run dev`, deployed sites) noop.
*/
var PREVIEW_BRIDGE_CHANNEL = "grok-preview-bridge";
var EnvelopeSchema = object({
	channel: literal$1(PREVIEW_BRIDGE_CHANNEL),
	version: number().int().positive(),
	type: string().min(1)
});
var HelloSchema = EnvelopeSchema.extend({ type: literal$1("hello") });
var NavigateSchema = EnvelopeSchema.extend({
	type: literal$1("navigate"),
	path: string().min(1)
});
var HistorySchema = EnvelopeSchema.extend({
	type: literal$1("history"),
	delta: union([literal$1(-1), literal$1(1)])
});
function isSafeBridgePath(path) {
	if (!path.startsWith("/") || path.startsWith("//") || path.includes("\\")) return false;
	try {
		return new URL(path, "https://preview.invalid").origin === "https://preview.invalid";
	} catch {
		return false;
	}
}
/**
* Install host↔guest messaging. Returns a dispose function.
* Noops (returns a no-op dispose) when not embedded under a Grok parent.
*/
function installPreviewHostBridge(options = {}) {
	if (typeof window === "undefined") return () => {};
	const ancestorOrigin = typeof location.ancestorOrigins !== "undefined" && location.ancestorOrigins.length > 0 ? location.ancestorOrigins[0] : null;
	const parentOrigin = resolveParentEmbedderOrigin(window.parent === window, document.referrer, ancestorOrigin, window.location.hostname);
	if (parentOrigin === null) return () => {};
	const ROOT_STATE_KEY = "__grokPreviewBridgeRoot";
	const originalPushState = window.history.pushState.bind(window.history);
	const originalReplaceState = window.history.replaceState.bind(window.history);
	const isAtHistoryRoot = () => {
		const state = window.history.state;
		return Boolean(state && typeof state === "object" && state[ROOT_STATE_KEY] === true);
	};
	try {
		const current = window.history.state;
		if (!(current !== null && typeof current === "object" && Object.prototype.hasOwnProperty.call(current, ROOT_STATE_KEY))) {
			const isRoot = window.history.length <= 1;
			originalReplaceState(current && typeof current === "object" ? {
				...current,
				[ROOT_STATE_KEY]: isRoot
			} : { [ROOT_STATE_KEY]: isRoot }, "", window.location.href);
		}
	} catch {}
	const post = (message) => {
		window.parent.postMessage(message, parentOrigin);
	};
	const reportLocation = () => {
		post({
			channel: PREVIEW_BRIDGE_CHANNEL,
			version: 1,
			type: "location",
			path: window.location.pathname || "/",
			search: window.location.search,
			hash: window.location.hash
		});
	};
	const reportRoutes = () => {
		const paths = options.getRoutePaths?.() ?? [];
		post({
			channel: PREVIEW_BRIDGE_CHANNEL,
			version: 1,
			type: "routes",
			paths
		});
	};
	const defaultNavigate = (path) => {
		if (!isSafeBridgePath(path)) return;
		try {
			const url = new URL(path, window.location.origin);
			if (url.origin !== window.location.origin) return;
			const next = `${url.pathname}${url.search}${url.hash}`;
			window.history.pushState(window.history.state, "", next);
			window.dispatchEvent(new PopStateEvent("popstate", { state: window.history.state }));
		} catch {}
	};
	const navigate = (path) => {
		if (!isSafeBridgePath(path)) return;
		if (options.navigate) {
			options.navigate(path);
			return;
		}
		defaultNavigate(path);
	};
	const announce = () => {
		reportLocation();
		reportRoutes();
		post({
			channel: PREVIEW_BRIDGE_CHANNEL,
			version: 1,
			type: "ready"
		});
	};
	const onMessage = (event) => {
		if (event.source !== window.parent) return;
		if (event.origin !== parentOrigin) return;
		const envelope = EnvelopeSchema.safeParse(event.data);
		if (!envelope.success || envelope.data.version !== 1) return;
		if (envelope.data.type === "hello") {
			if (!HelloSchema.safeParse(event.data).success) return;
			announce();
			return;
		}
		if (envelope.data.type === "navigate") {
			const parsed = NavigateSchema.safeParse(event.data);
			if (!parsed.success) return;
			navigate(parsed.data.path);
			queueMicrotask(reportLocation);
			return;
		}
		if (envelope.data.type === "history") {
			const parsed = HistorySchema.safeParse(event.data);
			if (!parsed.success) return;
			if (parsed.data.delta === -1 && isAtHistoryRoot()) return;
			window.history.go(parsed.data.delta);
		}
	};
	const onPopState = () => {
		reportLocation();
	};
	const onHashChange = () => {
		reportLocation();
	};
	window.history.pushState = (data, unused, url) => {
		const next = data && typeof data === "object" ? {
			...data,
			[ROOT_STATE_KEY]: false
		} : data;
		originalPushState(next, unused, url);
		reportLocation();
	};
	window.history.replaceState = (data, unused, url) => {
		const next = isAtHistoryRoot() ? {
			...data && typeof data === "object" ? data : {},
			[ROOT_STATE_KEY]: true
		} : data;
		originalReplaceState(next, unused, url);
		reportLocation();
	};
	window.addEventListener("message", onMessage);
	window.addEventListener("popstate", onPopState);
	window.addEventListener("hashchange", onHashChange);
	announce();
	return () => {
		window.removeEventListener("message", onMessage);
		window.removeEventListener("popstate", onPopState);
		window.removeEventListener("hashchange", onHashChange);
		window.history.pushState = originalPushState;
		window.history.replaceState = originalReplaceState;
	};
}
/** Collect static path patterns from a TanStack route tree (best-effort). */
function collectRoutePathsFromTree(routeTree) {
	const paths = /* @__PURE__ */ new Set();
	const walk = (node) => {
		if (!node || typeof node !== "object") return;
		const record = node;
		const full = typeof record.fullPath === "string" ? record.fullPath : typeof record.path === "string" ? record.path : null;
		if (full !== null && full !== "") paths.add(full.startsWith("/") ? full : `/${full}`);
		else if (full === "") paths.add("/");
		const children = record.children;
		if (Array.isArray(children)) for (const child of children) walk(child);
		else if (children && typeof children === "object") for (const child of Object.values(children)) walk(child);
	};
	walk(routeTree);
	return [...paths];
}
/**
* Mount once in `__root.tsx` so the Grok preview chrome can drive navigation
* (and later receive registered routes). Noops when the app is not embedded.
*/
function PreviewHostBridge() {
	const router = useRouter();
	(0, import_react.useEffect)(() => {
		return installPreviewHostBridge({
			navigate: (path) => {
				router.history.push(path);
			},
			getRoutePaths: () => collectRoutePathsFromTree(router.routeTree)
		});
	}, [router]);
	return null;
}
function cn(...inputs) {
	return twMerge(clsx(inputs));
}
var links = [
	{
		to: "/",
		label: "Overview"
	},
	{
		to: "/source",
		label: "Objective-C"
	},
	{
		to: "/workbench",
		label: "Workbench"
	},
	{
		to: "/docs",
		label: "Notes"
	},
	{
		to: "/license",
		label: "GPL"
	}
];
function SiteHeader() {
	const pathname = useRouterState({ select: (s) => s.location.pathname });
	return /* @__PURE__ */ (0, import_jsx_runtime.jsx)("header", {
		className: "sticky top-0 z-40 border-b border-border/80 bg-bg/85 backdrop-blur-md",
		children: /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("div", {
			className: "mx-auto flex h-14 max-w-6xl items-center justify-between gap-4 px-4 sm:h-16 sm:px-6",
			children: [/* @__PURE__ */ (0, import_jsx_runtime.jsxs)(Link, {
				to: "/",
				className: "flex items-baseline gap-2 text-fg no-underline",
				children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
					className: "font-display text-xl tracking-tight",
					children: "OIS"
				}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("span", {
					className: "hidden text-xs text-muted sm:inline",
					children: "Open Incremental Store"
				})]
			}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)("nav", {
				className: "flex items-center gap-0.5 overflow-x-auto",
				children: links.map((link) => {
					const active = pathname === link.to;
					return /* @__PURE__ */ (0, import_jsx_runtime.jsx)(Link, {
						to: link.to,
						className: cn("rounded-sm px-2.5 py-2 text-sm transition-colors duration-150", active ? "text-fg" : "text-muted hover:text-fg"),
						children: link.label
					}, link.to);
				})
			})]
		})
	});
}
var styles_default = "/assets/styles-CUv56C7C.css";
var APP_NAME = "OIS";
var Route$7 = createRootRoute({
	head: () => ({
		meta: [
			{ charSet: "utf-8" },
			{
				name: "viewport",
				content: "width=device-width, initial-scale=1"
			},
			{ title: `${APP_NAME} — Open Incremental Store` },
			{
				name: "description",
				content: "GPL NSIncrementalStore subclass for remote OData v4 services. Fetch requests become $filter. Saves become POST, PATCH, DELETE."
			},
			{
				name: "theme-color",
				content: "#0a0b0d"
			}
		],
		links: [
			{
				rel: "icon",
				type: "image/svg+xml",
				href: "/favicon.svg"
			},
			{
				rel: "stylesheet",
				href: styles_default
			},
			{
				rel: "preconnect",
				href: "https://fonts.googleapis.com"
			},
			{
				rel: "preconnect",
				href: "https://fonts.gstatic.com",
				crossOrigin: "anonymous"
			},
			{
				rel: "stylesheet",
				href: "https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:ital,wght@0,400;0,500;0,600;1,400&family=Instrument+Serif:ital@0;1&display=swap"
			}
		]
	}),
	component: RootComponent
});
function RootComponent() {
	return /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("html", {
		lang: "en",
		className: "antialiased",
		suppressHydrationWarning: true,
		children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)("head", { children: /* @__PURE__ */ (0, import_jsx_runtime.jsx)(HeadContent, {}) }), /* @__PURE__ */ (0, import_jsx_runtime.jsxs)("body", {
			className: "min-h-dvh bg-bg font-sans text-fg",
			children: [
				/* @__PURE__ */ (0, import_jsx_runtime.jsx)(PreviewHostBridge, {}),
				/* @__PURE__ */ (0, import_jsx_runtime.jsxs)(AuthProvider, { children: [/* @__PURE__ */ (0, import_jsx_runtime.jsx)(SiteHeader, {}), /* @__PURE__ */ (0, import_jsx_runtime.jsx)(Outlet, {})] }),
				/* @__PURE__ */ (0, import_jsx_runtime.jsx)(Scripts, {})
			]
		})]
	});
}
var $$splitComponentImporter$4 = () => import("./routes-O_tEwzrU.mjs");
var Route$6 = createFileRoute("/")({ component: lazyRouteComponent($$splitComponentImporter$4, "component") });
var $$splitComponentImporter$3 = () => import("./docs-BcuK0MUk.mjs");
var Route$5 = createFileRoute("/docs")({ component: lazyRouteComponent($$splitComponentImporter$3, "component") });
var $$splitComponentImporter$2 = () => import("./license-1NBA8iwP.mjs");
var Route$4 = createFileRoute("/license")({ component: lazyRouteComponent($$splitComponentImporter$2, "component") });
var $$splitComponentImporter$1 = () => import("./source-E47JDBit.mjs");
var Route$3 = createFileRoute("/source")({ component: lazyRouteComponent($$splitComponentImporter$1, "component") });
var $$splitComponentImporter = () => import("./workbench-CDUeO8q4.mjs");
var Route$2 = createFileRoute("/workbench")({ component: lazyRouteComponent($$splitComponentImporter, "component") });
var Lexer = class {
	tokens = [];
	i = 0;
	constructor(input) {
		this.tokens = tokenizeOData(input);
	}
	peek() {
		return this.tokens[this.i];
	}
	eat(expected) {
		const t = this.tokens[this.i];
		if (expected && t !== expected) throw new Error(`Expected ${expected}, got ${t ?? "end"}`);
		if (t === void 0) throw new Error("Unexpected end of $filter");
		this.i += 1;
		return t;
	}
};
function tokenizeOData(input) {
	const tokens = [];
	let i = 0;
	while (i < input.length) {
		const c = input[i];
		if (/\s/.test(c)) {
			i += 1;
			continue;
		}
		if (c === "'") {
			i += 1;
			let s = "'";
			while (i < input.length) {
				const ch = input[i];
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
			while (i < input.length && /[\w]/.test(input[i])) {
				s += input[i];
				i += 1;
			}
			tokens.push(s);
			continue;
		}
		if (/[-0-9]/.test(c)) {
			let s = "";
			while (i < input.length && /[0-9.T:+\-Z]/.test(input[i])) {
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
function parseODataFilter(input, entity) {
	const p = new Lexer(input.trim());
	const expr = parseOr(p, entity);
	if (p.peek() !== void 0) throw new Error(`Unexpected token ${p.peek()}`);
	return expr;
}
function parseOr(p, entity) {
	const args = [parseAnd(p, entity)];
	while (p.peek() === "or") {
		p.eat();
		args.push(parseAnd(p, entity));
	}
	return args.length === 1 ? args[0] : {
		kind: "logic",
		op: "or",
		args
	};
}
function parseAnd(p, entity) {
	const args = [parseNot(p, entity)];
	while (p.peek() === "and") {
		p.eat();
		args.push(parseNot(p, entity));
	}
	return args.length === 1 ? args[0] : {
		kind: "logic",
		op: "and",
		args
	};
}
function parseNot(p, entity) {
	if (p.peek() === "not") {
		p.eat();
		return {
			kind: "not",
			arg: parseNot(p, entity)
		};
	}
	return parseCmp(p, entity);
}
function parseCmp(p, entity) {
	if (p.peek() === "(") {
		p.eat("(");
		const inner = parseOr(p, entity);
		p.eat(")");
		return inner;
	}
	const left = parseValue(p, entity);
	const next = p.peek();
	if (next && [
		"eq",
		"ne",
		"gt",
		"ge",
		"lt",
		"le"
	].includes(next)) return {
		kind: "cmp",
		op: p.eat(),
		left,
		right: parseValue(p, entity)
	};
	if (next === "in") {
		p.eat();
		p.eat("(");
		const values = [parseValue(p, entity)];
		while (p.peek() === ",") {
			p.eat(",");
			values.push(parseValue(p, entity));
		}
		p.eat(")");
		return {
			kind: "in",
			path: left,
			values
		};
	}
	return left;
}
function parseValue(p, entity) {
	const t = p.peek();
	if (!t) throw new Error("Expected value in $filter");
	if (t.startsWith("'")) {
		p.eat();
		return {
			kind: "lit",
			value: t.slice(1, -1).replace(/''/g, "'")
		};
	}
	if (t === "true") {
		p.eat();
		return {
			kind: "lit",
			value: true
		};
	}
	if (t === "false") {
		p.eat();
		return {
			kind: "lit",
			value: false
		};
	}
	if (t === "null") {
		p.eat();
		return {
			kind: "lit",
			value: null
		};
	}
	if (/^-?\d/.test(t)) {
		p.eat();
		return {
			kind: "lit",
			value: t.includes(".") || t.includes("T") ? t.includes("T") ? t : Number(t) : Number(t)
		};
	}
	if ([
		"contains",
		"startswith",
		"endswith",
		"tolower",
		"toupper"
	].includes(t)) {
		const name = p.eat();
		p.eat("(");
		const args = [parseValue(p, entity)];
		while (p.peek() === ",") {
			p.eat(",");
			args.push(parseValue(p, entity));
		}
		p.eat(")");
		return {
			kind: "fn",
			name,
			args
		};
	}
	return parseODataPath(p, entity);
}
function parseODataPath(p, entity) {
	const parts = [odataToCore(p.eat(), entity)];
	let current = entity;
	while (p.peek() === "/") {
		p.eat("/");
		const ident = p.peek();
		if (ident === "any" || ident === "all") {
			const quant = p.eat();
			p.eat("(");
			const variable = p.eat();
			p.eat(":");
			const rel = current.relationships.find((r) => r.name === parts[parts.length - 1]);
			const pred = parseOr(p, rel ? entityByName(rel.destination) : current);
			p.eat(")");
			return {
				kind: "lambda",
				quant,
				path: parts,
				variable,
				pred
			};
		}
		const next = p.eat();
		const rel = current.relationships.find((r) => r.odata === next || r.name === next);
		const attr = current.attributes.find((a) => a.odata === next || a.name === next);
		if (rel) {
			parts.push(rel.name);
			current = entityByName(rel.destination);
		} else if (attr) parts.push(attr.name);
		else parts.push(next);
	}
	return {
		kind: "path",
		parts
	};
}
function odataToCore(name, entity) {
	const attr = entity.attributes.find((a) => a.odata === name || a.name === name);
	if (attr) return attr.name;
	const rel = entity.relationships.find((r) => r.odata === name || r.name === name);
	if (rel) return rel.name;
	return name;
}
var Parser = class {
	tokens;
	i = 0;
	constructor(input) {
		this.tokens = tokenize(input);
	}
	peek() {
		return this.tokens[this.i];
	}
	eat(expected) {
		const t = this.tokens[this.i];
		if (expected && t !== expected) throw new Error(`Expected ${expected}, got ${t ?? "end"}`);
		if (t === void 0) throw new Error("Unexpected end of predicate");
		this.i += 1;
		return t;
	}
	parse() {
		if (this.tokens.length === 0) throw new Error("Empty predicate");
		const expr = this.parseOr();
		if (this.i !== this.tokens.length) throw new Error(`Unexpected token ${this.peek()}`);
		return expr;
	}
	parseOr() {
		const args = [this.parseAnd()];
		while (this.peek() && /^or$/i.test(this.peek())) {
			this.eat();
			args.push(this.parseAnd());
		}
		return args.length === 1 ? args[0] : {
			kind: "logic",
			op: "or",
			args
		};
	}
	parseAnd() {
		const args = [this.parseNot()];
		while (this.peek() && /^and$/i.test(this.peek())) {
			this.eat();
			args.push(this.parseNot());
		}
		return args.length === 1 ? args[0] : {
			kind: "logic",
			op: "and",
			args
		};
	}
	parseNot() {
		if (this.peek() && /^not$/i.test(this.peek())) {
			this.eat();
			return {
				kind: "not",
				arg: this.parseNot()
			};
		}
		return this.parseCmp();
	}
	parseCmp() {
		if (this.peek() === "(") {
			this.eat("(");
			const inner = this.parseOr();
			this.eat(")");
			return inner;
		}
		let quant;
		if (this.peek() && /^(any|all)$/i.test(this.peek())) quant = this.eat().toLowerCase();
		const left = this.parsePath();
		if (quant) {
			if (!this.peek()) throw new Error("Expected operator after ANY/ALL");
			const { op, options } = parseOperator(this.eat());
			const pred = {
				kind: "cmp",
				op,
				left: {
					kind: "path",
					parts: ["x"]
				},
				right: this.parseValue(),
				options
			};
			return {
				kind: "lambda",
				quant,
				path: left.parts,
				variable: "x",
				pred
			};
		}
		const next = this.peek();
		if (!next) return left;
		if (/^in$/i.test(next)) {
			this.eat();
			return {
				kind: "in",
				path: left,
				values: this.parseList()
			};
		}
		if (/^between$/i.test(next)) {
			this.eat();
			const values = this.parseList();
			if (values.length !== 2) throw new Error("BETWEEN expects two values");
			return {
				kind: "between",
				path: left,
				low: values[0],
				high: values[1]
			};
		}
		if (isOperatorToken(next)) {
			const { op, options, fn } = parseOperator(this.eat());
			const right = this.parseValue();
			if (fn) return {
				kind: "fn",
				name: fn,
				args: options?.includes("c") ? wrapLower(left, right) : [left, right]
			};
			return {
				kind: "cmp",
				op,
				left,
				right,
				options
			};
		}
		return left;
	}
	parsePath() {
		const first = this.eat();
		if (!/^[$A-Za-z_][\w$]*$/.test(first)) throw new Error(`Expected key path, got ${first}`);
		const parts = [first];
		while (this.peek() === ".") {
			this.eat(".");
			parts.push(this.eat());
		}
		return {
			kind: "path",
			parts
		};
	}
	parseValue() {
		const t = this.peek();
		if (!t) throw new Error("Expected value");
		if (t === "(") return {
			kind: "lit",
			value: this.parseList().map((v) => v.kind === "lit" ? v.value : v)
		};
		if (t.startsWith("\"") || t.startsWith("'")) {
			this.eat();
			return {
				kind: "lit",
				value: unquote(t)
			};
		}
		if (/^(yes|true)$/i.test(t)) {
			this.eat();
			return {
				kind: "lit",
				value: true
			};
		}
		if (/^(no|false)$/i.test(t)) {
			this.eat();
			return {
				kind: "lit",
				value: false
			};
		}
		if (/^(nil|null)$/i.test(t)) {
			this.eat();
			return {
				kind: "lit",
				value: null
			};
		}
		if (/^-?\d/.test(t)) {
			this.eat();
			return {
				kind: "lit",
				value: t.includes(".") ? Number(t) : Number(t)
			};
		}
		return this.parsePath();
	}
	parseList() {
		const t = this.peek();
		if (t === "{" || t === "(") {
			this.eat();
			const close = t === "{" ? "}" : ")";
			const values = [];
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
};
function wrapLower(a, b) {
	return [{
		kind: "fn",
		name: "tolower",
		args: [a]
	}, {
		kind: "fn",
		name: "tolower",
		args: [b]
	}];
}
function isOperatorToken(t) {
	return /^(==|!=|<=|>=|=|<|>|contains|beginswith|endswith)/i.test(t);
}
function parseOperator(raw) {
	const m = raw.match(/^(==|!=|<=|>=|=|<|>|contains|beginswith|endswith)(?:\[([cd]+)\])?$/i);
	if (!m) throw new Error(`Unknown operator ${raw}`);
	const opTok = m[1].toLowerCase();
	const options = m[2]?.toLowerCase();
	if (opTok === "contains") return {
		op: "eq",
		options,
		fn: "contains"
	};
	if (opTok === "beginswith") return {
		op: "eq",
		options,
		fn: "startswith"
	};
	if (opTok === "endswith") return {
		op: "eq",
		options,
		fn: "endswith"
	};
	return {
		op: {
			"==": "eq",
			"=": "eq",
			"!=": "ne",
			"<": "lt",
			">": "gt",
			"<=": "le",
			">=": "ge"
		}[opTok] ?? "eq",
		options
	};
}
function unquote(t) {
	const q = t[0];
	let s = t.slice(1, -1);
	if (q === "\"") s = s.replace(/\\"/g, "\"").replace(/\\\\/g, "\\");
	else s = s.replace(/''/g, "'");
	return s;
}
function tokenize(input) {
	const tokens = [];
	let i = 0;
	while (i < input.length) {
		const c = input[i];
		if (/\s/.test(c)) {
			i += 1;
			continue;
		}
		if (c === "\"" || c === "'") {
			const q = c;
			i += 1;
			let s = q;
			while (i < input.length) {
				const ch = input[i];
				s += ch;
				i += 1;
				if (q === "'" && ch === "'" && input[i] === "'") {
					s += input[i];
					i += 1;
					continue;
				}
				if (ch === q && (q === "\"" ? s[s.length - 2] !== "\\" : true)) break;
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
			while (i < input.length && /[\w]/.test(input[i])) {
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
			while (i < input.length && /[0-9.]/.test(input[i])) {
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
function parsePredicate(input) {
	return new Parser(input.trim()).parse();
}
function mapPath(parts, entity) {
	const out = [];
	let current = entity;
	for (let i = 0; i < parts.length; i++) {
		const part = parts[i];
		if (!current) {
			out.push(part);
			continue;
		}
		const attr = current.attributes.find((a) => a.name === part);
		if (attr) {
			out.push(attr.odata);
			current = void 0;
			continue;
		}
		const rel = current.relationships.find((r) => r.name === part);
		if (rel) {
			out.push(rel.odata);
			current = entityByName(rel.destination);
			continue;
		}
		out.push(part);
		current = void 0;
	}
	return out;
}
function toODataFilter(expr, entity) {
	switch (expr.kind) {
		case "lit": return literal(expr.value);
		case "path": return mapPath(expr.parts, entity).join("/");
		case "cmp": {
			const l = toODataFilter(expr.left, entity);
			const r = toODataFilter(expr.right, entity);
			if (expr.options?.includes("c")) return `tolower(${l}) ${expr.op} tolower(${r})`;
			return `${l} ${expr.op} ${r}`;
		}
		case "logic": return expr.args.map((a) => `(${toODataFilter(a, entity)})`).join(` ${expr.op} `);
		case "not": return `not (${toODataFilter(expr.arg, entity)})`;
		case "fn": return `${expr.name}(${expr.args.map((a) => toODataFilter(a, entity)).join(", ")})`;
		case "in": return `${toODataFilter(expr.path, entity)} in (${expr.values.map((v) => toODataFilter(v, entity)).join(", ")})`;
		case "between": return `(${toODataFilter(expr.path, entity)} ge ${toODataFilter(expr.low, entity)} and ${toODataFilter(expr.path, entity)} le ${toODataFilter(expr.high, entity)})`;
		case "lambda": {
			const path = mapPath(expr.path, entity).join("/");
			const innerEntity = resolvePathEntity(entity, expr.path);
			const pred = toODataFilter(expr.pred, innerEntity);
			return `${path}/${expr.quant}(${expr.variable}: ${pred})`;
		}
	}
}
function resolvePathEntity(entity, parts) {
	let current = entity;
	for (const part of parts) {
		const rel = current.relationships.find((r) => r.name === part);
		if (rel) current = entityByName(rel.destination);
	}
	return current;
}
function literal(value) {
	if (value === null || value === void 0) return "null";
	if (typeof value === "boolean") return value ? "true" : "false";
	if (typeof value === "number") return String(value);
	if (typeof value === "string") {
		if (/^\d{4}-\d{2}-\d{2}T/.test(value)) return value;
		return `'${value.replace(/'/g, "''")}'`;
	}
	return `'${String(value)}'`;
}
function evaluate(expr, row, entity, collections) {
	const v = evalExpr(expr, row, entity, collections);
	return Boolean(v);
}
function evalExpr(expr, row, entity, collections) {
	switch (expr.kind) {
		case "lit": return expr.value;
		case "path": return readPath(expr.parts, row, entity, collections);
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
		case "not": return !evalExpr(expr.arg, row, entity, collections);
		case "fn": {
			const [a, b] = expr.args.map((a) => evalExpr(a, row, entity, collections));
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
			const pred = (item) => Boolean(evalExpr(expr.pred, item, dest, collections));
			return expr.quant === "any" ? related.some(pred) : related.every(pred);
		}
	}
}
function readPath(parts, row, entity, collections) {
	if (parts.length === 1) return row[parts[0]];
	const rel = entity.relationships.find((r) => r.name === parts[0]);
	if (!rel) return void 0;
	const related = relatedRows(row, entity, rel.name, collections);
	const dest = entityByName(rel.destination);
	if (rel.toMany) return related.map((r) => readPath(parts.slice(1), r, dest, collections));
	const one = related[0];
	if (!one) return void 0;
	return readPath(parts.slice(1), one, dest, collections);
}
function relatedRows(row, entity, relName, collections) {
	const rel = entity.relationships.find((r) => r.name === relName);
	if (!rel) return [];
	const dest = entityByName(rel.destination);
	const destRows = collections[dest.name] ?? [];
	if (rel.toMany) {
		const key = entity.attributes.find((a) => a.key)?.name ?? "id";
		const fk = rel.fk ?? `${entity.name[0].toLowerCase()}${entity.name.slice(1)}Id`;
		return destRows.filter((d) => d[fk] === row[key]);
	}
	const fk = rel.fk ?? `${rel.name}Id`;
	const destKey = dest.attributes.find((a) => a.key)?.name ?? "id";
	return destRows.filter((d) => d[destKey] === row[fk]);
}
function compare(op, l, r) {
	if (l == null || r == null) {
		if (op === "eq") return l == r;
		if (op === "ne") return l != r;
		return false;
	}
	const lv = l;
	const rv = r;
	switch (op) {
		case "eq": return l === r || typeof l === "number" && typeof r === "number" && l === r;
		case "ne": return l !== r;
		case "gt": return lv > rv;
		case "ge": return lv >= rv;
		case "lt": return lv < rv;
		case "le": return lv <= rv;
	}
}
function translateFetch(request, serviceRoot = "/odata") {
	const entity = entityByName(request.entity);
	const query = {};
	const notes = [];
	const storeMethods = [{
		method: "executeRequest:withContext:error:",
		detail: `NSFetchRequest · ${request.entity} · ${request.resultType}`
	}];
	if (request.predicate?.trim()) {
		query.$filter = toODataFilter(parsePredicate(request.predicate), entity);
		notes.push(`NSPredicate → $filter`);
	}
	if (request.sort.length) {
		query.$orderby = request.sort.map((s) => {
			const name = entity.attributes.find((a) => a.name === s.key)?.odata ?? s.key;
			return s.ascending ? name : `${name} desc`;
		}).join(",");
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
			storeMethods
		};
	}
	if (request.resultType === "dictionary" && request.propertiesToFetch?.length) {
		query.$select = request.propertiesToFetch.map((n) => entity.attributes.find((a) => a.name === n)?.odata ?? n).join(",");
		notes.push("propertiesToFetch → $select");
	}
	if (request.relationshipKeyPathsForPrefetching?.length) {
		query.$expand = request.relationshipKeyPathsForPrefetching.map((n) => entity.relationships.find((r) => r.name === n)?.odata ?? n).join(",");
		notes.push("relationshipKeyPathsForPrefetching → $expand");
		storeMethods.push({
			method: "newValueForRelationship:forObjectWithID:withContext:error:",
			detail: "Satisfied from $expand payload — no extra round trip"
		});
	}
	if (request.returnsObjectsAsFaults === false) {
		notes.push("returnsObjectsAsFaults = false → materialize NSIncrementalStoreNode now");
		storeMethods.push({
			method: "newValuesForObjectWithID:withContext:error:",
			detail: "Nodes cached from this payload; later faults are local"
		});
	} else if (request.resultType === "managedObject") storeMethods.push({
		method: "newValuesForObjectWithID:withContext:error:",
		detail: "Fired later, per fault, as GET EntitySet(key)"
	});
	const qs = encodeQuery(query);
	const path = `${serviceRoot}/${entity.entitySet}`;
	return {
		path,
		query,
		url: qs ? `${path}?${qs}` : path,
		method: "GET",
		notes,
		storeMethods
	};
}
function encodeQuery(query) {
	return Object.entries(query).map(([key, value]) => `${key}=${encodeURIComponent(value)}`).join("&");
}
function keyLiteral(value) {
	return typeof value === "string" ? `'${value.replace(/'/g, "''")}'` : String(value);
}
function resourcePath(entitySet, key) {
	const entries = Object.entries(key);
	if (entries.length === 1) return `${entitySet}(${keyLiteral(entries[0][1])})`;
	return `${entitySet}(${entries.map(([k, v]) => `${k}=${keyLiteral(v)}`).join(",")})`;
}
function cloneSeed() {
	const src = seedData();
	const out = {};
	for (const [k, rows] of Object.entries(src)) out[k] = rows.map((r) => ({ ...r }));
	return out;
}
var ODataEngine = class ODataEngine {
	data;
	sequences = {};
	constructor(data) {
		this.data = data ?? cloneSeed();
		for (const entity of SCHEMA.entities) {
			const key = entity.attributes.find((a) => a.key);
			if (key?.type === "Edm.String") continue;
			const max = (this.data[entity.name] ?? []).reduce((m, r) => Math.max(m, Number(r[key?.name ?? "id"] ?? 0)), 0);
			this.sequences[entity.name] = max;
		}
	}
	clone() {
		const copy = {};
		for (const [k, rows] of Object.entries(this.data)) copy[k] = rows.map((r) => ({ ...r }));
		const next = new ODataEngine(copy);
		next.sequences = { ...this.sequences };
		return next;
	}
	handle(req) {
		const method = req.method.toUpperCase();
		const raw = req.path.replace(/^\/+/, "").replace(/^odata\/?/, "");
		const serviceRoot = req.serviceRoot ?? "/odata";
		if (raw === "" || raw === "/") return json(200, this.serviceDocument(serviceRoot));
		if (raw === "$metadata") {
			if ((req.headers?.accept ?? req.headers?.Accept ?? "").includes("application/json")) return json(200, this.metadataJson());
			return {
				status: 200,
				headers: { "content-type": "application/xml;charset=utf-8" },
				body: this.metadataXml(),
				text: this.metadataXml()
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
					text: String(rows.length)
				};
			}
			if (parsed.key) {
				const entity = entityBySet(parsed.entitySet);
				const row = this.find(entity, parsed.key);
				if (!row) return error(404, "Not found");
				if (parsed.nav) return this.handleNav(method, entity, row, parsed.nav, req, serviceRoot);
				if (method === "GET") return json(200, this.serializeEntity(entity, row, req.query.get("$expand"), serviceRoot, true));
				if (method === "PATCH" || method === "PUT") return this.patch(entity, row, req.body, req.headers);
				if (method === "DELETE") {
					this.remove(entity, row);
					return {
						status: 204,
						headers: {},
						body: null
					};
				}
				return error(405, "Method not allowed");
			}
			const entity = entityBySet(parsed.entitySet);
			if (method === "GET") {
				const payload = this.querySet(parsed.entitySet, req.query, true).map((row) => this.serializeEntity(entity, row, req.query.get("$expand"), serviceRoot, false));
				const body = {
					"@odata.context": `${serviceRoot}/$metadata#${entity.entitySet}`,
					value: payload
				};
				if (req.query.get("$count") === "true") body["@odata.count"] = this.querySet(parsed.entitySet, req.query, false).length;
				return json(200, body);
			}
			if (method === "POST") return this.insert(entity, req.body, serviceRoot);
			return error(405, "Method not allowed");
		} catch (err) {
			return error(400, err instanceof Error ? err.message : String(err));
		}
	}
	handleNav(method, entity, row, nav, req, serviceRoot) {
		const rel = entity.relationships.find((r) => r.odata === nav || r.name === nav);
		if (!rel) return error(404, `Unknown navigation ${nav}`);
		const dest = entityByName(rel.destination);
		const related = relatedRows(row, entity, rel.name, this.data);
		if (method !== "GET") return error(405, "Method not allowed");
		if (rel.toMany) return json(200, {
			"@odata.context": `${serviceRoot}/$metadata#${dest.entitySet}`,
			value: related.map((r) => this.serializeEntity(dest, r, null, serviceRoot, false))
		});
		const one = related[0];
		if (!one) return {
			status: 204,
			headers: {},
			body: null
		};
		return json(200, this.serializeEntity(dest, one, null, serviceRoot, true));
	}
	querySet(entitySet, query, applyPage) {
		const entity = entityBySet(entitySet);
		let rows = [...this.data[entity.name] ?? []];
		const filter = query.get("$filter");
		if (filter) {
			const ast = parseODataFilter(filter, entity);
			rows = rows.filter((row) => evaluate(ast, row, entity, this.data));
		}
		const orderby = query.get("$orderby");
		if (orderby) rows = sortRows(rows, entity, orderby);
		if (applyPage) {
			const skip = Number(query.get("$skip") ?? 0);
			const top = query.get("$top") != null ? Number(query.get("$top")) : void 0;
			if (skip) rows = rows.slice(skip);
			if (top != null) rows = rows.slice(0, top);
		}
		return rows;
	}
	find(entity, key) {
		const keyAttr = entity.attributes.find((a) => a.key);
		const raw = key[keyAttr.odata] ?? key[keyAttr.name] ?? Object.values(key)[0];
		return (this.data[entity.name] ?? []).find((r) => String(r[keyAttr.name]) === String(raw));
	}
	insert(entity, body, serviceRoot) {
		const payload = body ?? {};
		const row = this.fromOData(entity, payload);
		const keyAttr = entity.attributes.find((a) => a.key);
		if (row[keyAttr.name] == null) {
			if (keyAttr.type === "Edm.String") row[keyAttr.name] = `NEW${Date.now().toString(36).toUpperCase()}`;
			else {
				this.sequences[entity.name] = (this.sequences[entity.name] ?? 0) + 1;
				row[keyAttr.name] = this.sequences[entity.name];
			}
		}
		row.__etag = 1;
		this.data[entity.name] = [...this.data[entity.name] ?? [], row];
		return json(201, this.serializeEntity(entity, row, null, serviceRoot, true), { location: `${serviceRoot}/${resourcePath(entity.entitySet, { [keyAttr.odata]: row[keyAttr.name] })}` });
	}
	patch(entity, row, body, headers) {
		const ifMatch = headers?.["if-match"] ?? headers?.["If-Match"];
		if (ifMatch && ifMatch !== "*" && ifMatch !== etag(row.__etag)) return error(412, "Precondition Failed — ETag mismatch (optimistic lock)");
		const incoming = this.fromOData(entity, body ?? {});
		for (const [k, v] of Object.entries(incoming)) {
			if (k === "__etag") continue;
			row[k] = v;
		}
		row.__etag += 1;
		return json(200, this.serializeEntity(entity, row, null, "/odata", true));
	}
	remove(entity, row) {
		const keyAttr = entity.attributes.find((a) => a.key);
		this.data[entity.name] = (this.data[entity.name] ?? []).filter((r) => r[keyAttr.name] !== row[keyAttr.name]);
	}
	serializeEntity(entity, row, expand, serviceRoot, single) {
		const keyAttr = entity.attributes.find((a) => a.key);
		const keyVal = row[keyAttr.name];
		const out = {};
		if (single) out["@odata.context"] = `${serviceRoot}/$metadata#${entity.entitySet}/$entity`;
		out["@odata.id"] = `${serviceRoot}/${resourcePath(entity.entitySet, { [keyAttr.odata]: keyVal })}`;
		out["@odata.etag"] = etag(row.__etag);
		for (const attr of entity.attributes) out[attr.odata] = row[attr.name] ?? null;
		const expandSet = new Set((expand ?? "").split(",").map((s) => s.trim()).filter(Boolean));
		for (const rel of entity.relationships) {
			if (!expandSet.has(rel.odata) && !expandSet.has(rel.name)) continue;
			const dest = entityByName(rel.destination);
			const related = relatedRows(row, entity, rel.name, this.data);
			if (rel.toMany) out[rel.odata] = related.map((r) => this.serializeEntity(dest, r, null, serviceRoot, false));
			else {
				const one = related[0];
				out[rel.odata] = one ? this.serializeEntity(dest, one, null, serviceRoot, false) : null;
			}
		}
		if (expandSet.size === 0 && single) {}
		return out;
	}
	fromOData(entity, payload) {
		const row = { __etag: 1 };
		for (const attr of entity.attributes) if (payload[attr.odata] !== void 0) row[attr.name] = payload[attr.odata];
		else if (payload[attr.name] !== void 0) row[attr.name] = payload[attr.name];
		return row;
	}
	serviceDocument(serviceRoot) {
		return {
			"@odata.context": `${serviceRoot}/$metadata`,
			value: SCHEMA.entities.map((e) => ({
				name: e.entitySet,
				kind: "EntitySet",
				url: e.entitySet
			}))
		};
	}
	metadataJson() {
		return {
			$Version: "4.0",
			$EntityContainer: `${SCHEMA.namespace}.${SCHEMA.container}`,
			[SCHEMA.namespace]: Object.fromEntries(SCHEMA.entities.map((e) => [e.name, {
				$Kind: "EntityType",
				$Key: e.attributes.filter((a) => a.key).map((a) => a.odata),
				...Object.fromEntries(e.attributes.map((a) => [a.odata, {
					$Type: a.type,
					$Nullable: a.optional
				}])),
				...Object.fromEntries(e.relationships.map((r) => [r.odata, {
					$Kind: "NavigationProperty",
					$Type: r.toMany ? `Collection(${SCHEMA.namespace}.${r.destination})` : `${SCHEMA.namespace}.${r.destination}`,
					$Partner: entityByName(r.destination).relationships.find((x) => x.name === r.inverse)?.odata
				}]))
			}]))
		};
	}
	metadataXml() {
		const types = SCHEMA.entities.map((e) => {
			const keys = e.attributes.filter((a) => a.key).map((a) => `<PropertyRef Name="${a.odata}"/>`).join("");
			const props = e.attributes.map((a) => `<Property Name="${a.odata}" Type="${a.type}" Nullable="${a.optional ? "true" : "false"}"/>`).join("");
			const nav = e.relationships.map((r) => {
				const type = r.toMany ? `Collection(${SCHEMA.namespace}.${r.destination})` : `${SCHEMA.namespace}.${r.destination}`;
				return `<NavigationProperty Name="${r.odata}" Type="${type}"/>`;
			}).join("");
			return `<EntityType Name="${e.name}"><Key>${keys}</Key>${props}${nav}</EntityType>`;
		}).join("");
		const sets = SCHEMA.entities.map((e) => `<EntitySet Name="${e.entitySet}" EntityType="${SCHEMA.namespace}.${e.name}"/>`).join("");
		return `<?xml version="1.0" encoding="utf-8"?>\n<edmx:Edmx Version="4.0" xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx"><edmx:DataServices><Schema Namespace="${SCHEMA.namespace}" xmlns="http://docs.oasis-open.org/odata/ns/edm">${types}<EntityContainer Name="${SCHEMA.container}">${sets}</EntityContainer></Schema></edmx:DataServices></edmx:Edmx>`;
	}
};
function sortRows(rows, entity, orderby) {
	const clauses = orderby.split(",").map((c) => {
		const [raw, dir] = c.trim().split(/\s+/);
		return {
			key: entity.attributes.find((a) => a.odata === raw || a.name === raw)?.name ?? raw,
			desc: (dir ?? "asc").toLowerCase() === "desc"
		};
	});
	return [...rows].sort((a, b) => {
		for (const c of clauses) {
			const av = a[c.key];
			const bv = b[c.key];
			if (av == bv) continue;
			if (av == null) return 1;
			if (bv == null) return -1;
			const cmp = av < bv ? -1 : 1;
			return c.desc ? -cmp : cmp;
		}
		return 0;
	});
}
function parseResource(raw) {
	const trimmed = raw.replace(/\/+$/, "");
	if (!trimmed) return null;
	const count = /\/\$count$/.test(trimmed);
	const navMatch = trimmed.replace(/\/\$count$/, "").match(/^([A-Za-z_][\w]*)(?:\(([^)]+)\))?(?:\/([A-Za-z_][\w]*))?$/);
	if (!navMatch) return null;
	const entitySet = navMatch[1];
	const keyRaw = navMatch[2];
	const nav = navMatch[3];
	let key;
	if (keyRaw) {
		key = {};
		if (keyRaw.includes("=")) for (const part of keyRaw.split(",")) {
			const [k, v] = part.split("=");
			key[k.trim()] = parseKeyValue(v.trim());
		}
		else key.value = parseKeyValue(keyRaw);
	}
	return {
		entitySet,
		key,
		nav,
		count
	};
}
function parseKeyValue(raw) {
	if (raw.startsWith("'") && raw.endsWith("'")) return raw.slice(1, -1).replace(/''/g, "'");
	const n = Number(raw);
	return Number.isNaN(n) ? raw : n;
}
function etag(version) {
	return `W/"${version}"`;
}
function json(status, body, extra) {
	return {
		status,
		headers: {
			"content-type": "application/json;odata.metadata=minimal;charset=utf-8",
			odata_version: "4.0",
			...extra
		},
		body
	};
}
function error(status, message) {
	return {
		status,
		headers: { "content-type": "application/json" },
		body: { error: {
			code: String(status),
			message
		} }
	};
}
var singleton = null;
function getSharedEngine() {
	singleton ??= new ODataEngine();
	return singleton;
}
async function handleODataRequest(request) {
	const url = new URL(request.url);
	let body;
	if (request.method !== "GET" && request.method !== "HEAD" && request.method !== "OPTIONS") {
		const text = await request.text();
		if (text) try {
			body = JSON.parse(text);
		} catch {
			body = text;
		}
	}
	const headers = {};
	request.headers.forEach((value, key) => {
		headers[key] = value;
	});
	const result = getSharedEngine().handle({
		method: request.method,
		path: url.pathname,
		query: url.searchParams,
		body,
		headers,
		serviceRoot: "/odata"
	});
	const responseHeaders = new Headers();
	for (const [k, v] of Object.entries(result.headers)) responseHeaders.set(k, v);
	if (result.status === 204) return new Response(null, {
		status: 204,
		headers: responseHeaders
	});
	if (typeof result.text === "string" && result.headers["content-type"]?.includes("xml")) return new Response(result.text, {
		status: result.status,
		headers: responseHeaders
	});
	if (typeof result.text === "string" && result.headers["content-type"]?.includes("text/plain")) return new Response(result.text, {
		status: result.status,
		headers: responseHeaders
	});
	return Response.json(result.body, {
		status: result.status,
		headers: responseHeaders
	});
}
var Route$1 = createFileRoute("/odata/")({ server: { handlers: { GET: ({ request }) => handleODataRequest(request) } } });
var Route = createFileRoute("/odata/$")({ server: { handlers: {
	GET: ({ request }) => handleODataRequest(request),
	POST: ({ request }) => handleODataRequest(request),
	PATCH: ({ request }) => handleODataRequest(request),
	PUT: ({ request }) => handleODataRequest(request),
	DELETE: ({ request }) => handleODataRequest(request)
} } });
var IndexRoute = Route$6.update({
	id: "/",
	path: "/",
	getParentRoute: () => Route$7
});
var DocsRoute = Route$5.update({
	id: "/docs",
	path: "/docs",
	getParentRoute: () => Route$7
});
var LicenseRoute = Route$4.update({
	id: "/license",
	path: "/license",
	getParentRoute: () => Route$7
});
var SourceRoute = Route$3.update({
	id: "/source",
	path: "/source",
	getParentRoute: () => Route$7
});
var WorkbenchRoute = Route$2.update({
	id: "/workbench",
	path: "/workbench",
	getParentRoute: () => Route$7
});
var OdataIndexRoute = Route$1.update({
	id: "/odata/",
	path: "/odata/",
	getParentRoute: () => Route$7
});
var rootRouteChildren = {
	IndexRoute,
	DocsRoute,
	LicenseRoute,
	SourceRoute,
	WorkbenchRoute,
	OdataSplatRoute: Route.update({
		id: "/odata/$",
		path: "/odata/$",
		getParentRoute: () => Route$7
	}),
	OdataIndexRoute
};
var routeTree = Route$7._addFileChildren(rootRouteChildren)._addFileTypes();
var router_exports = /* @__PURE__ */ __exportAll({ getRouter: () => getRouter });
function getRouter() {
	return createRouter({
		routeTree,
		defaultErrorComponent: AppErrorComponent
	});
}
//#endregion
export { cn as a, entityByName as c, translateFetch as i, ODataEngine as n, FETCH_PRESETS as o, resourcePath as r, SCHEMA as s, router_exports as t };
