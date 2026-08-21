import type { EntityDef, RecordObject, Schema } from "./types";

export const SCHEMA: Schema = {
  namespace: "Northwind",
  container: "Northwind",
  entities: [
    {
      name: "Category",
      entitySet: "Categories",
      attributes: [
        { name: "id", odata: "CategoryID", type: "Edm.Int64", optional: false, key: true },
        { name: "name", odata: "CategoryName", type: "Edm.String", optional: false },
        { name: "detail", odata: "Description", type: "Edm.String", optional: true },
      ],
      relationships: [
        {
          name: "products",
          odata: "Products",
          destination: "Product",
          entitySet: "Products",
          toMany: true,
          inverse: "category",
          fk: "categoryId",
        },
      ],
    },
    {
      name: "Supplier",
      entitySet: "Suppliers",
      attributes: [
        { name: "id", odata: "SupplierID", type: "Edm.Int64", optional: false, key: true },
        { name: "companyName", odata: "CompanyName", type: "Edm.String", optional: false },
        { name: "city", odata: "City", type: "Edm.String", optional: true },
        { name: "country", odata: "Country", type: "Edm.String", optional: true },
      ],
      relationships: [
        {
          name: "products",
          odata: "Products",
          destination: "Product",
          entitySet: "Products",
          toMany: true,
          inverse: "supplier",
          fk: "supplierId",
        },
      ],
    },
    {
      name: "Product",
      entitySet: "Products",
      attributes: [
        { name: "id", odata: "ProductID", type: "Edm.Int64", optional: false, key: true },
        { name: "name", odata: "ProductName", type: "Edm.String", optional: false },
        { name: "quantityPerUnit", odata: "QuantityPerUnit", type: "Edm.String", optional: true },
        { name: "unitPrice", odata: "UnitPrice", type: "Edm.Decimal", optional: false },
        { name: "unitsInStock", odata: "UnitsInStock", type: "Edm.Int16", optional: false },
        { name: "discontinued", odata: "Discontinued", type: "Edm.Boolean", optional: false },
        { name: "categoryId", odata: "CategoryID", type: "Edm.Int64", optional: false },
        { name: "supplierId", odata: "SupplierID", type: "Edm.Int64", optional: false },
      ],
      relationships: [
        {
          name: "category",
          odata: "Category",
          destination: "Category",
          entitySet: "Categories",
          toMany: false,
          inverse: "products",
          fk: "categoryId",
        },
        {
          name: "supplier",
          odata: "Supplier",
          destination: "Supplier",
          entitySet: "Suppliers",
          toMany: false,
          inverse: "products",
          fk: "supplierId",
        },
        {
          name: "orderItems",
          odata: "Order_Details",
          destination: "OrderItem",
          entitySet: "OrderItems",
          toMany: true,
          inverse: "product",
          fk: "productId",
        },
      ],
    },
    {
      name: "Customer",
      entitySet: "Customers",
      attributes: [
        { name: "id", odata: "CustomerID", type: "Edm.String", optional: false, key: true },
        { name: "companyName", odata: "CompanyName", type: "Edm.String", optional: false },
        { name: "contactName", odata: "ContactName", type: "Edm.String", optional: true },
        { name: "city", odata: "City", type: "Edm.String", optional: true },
        { name: "country", odata: "Country", type: "Edm.String", optional: true },
      ],
      relationships: [
        {
          name: "orders",
          odata: "Orders",
          destination: "Order",
          entitySet: "Orders",
          toMany: true,
          inverse: "customer",
          fk: "customerId",
        },
      ],
    },
    {
      name: "Order",
      entitySet: "Orders",
      attributes: [
        { name: "id", odata: "OrderID", type: "Edm.Int64", optional: false, key: true },
        { name: "orderDate", odata: "OrderDate", type: "Edm.DateTimeOffset", optional: false },
        { name: "shippedDate", odata: "ShippedDate", type: "Edm.DateTimeOffset", optional: true },
        { name: "freight", odata: "Freight", type: "Edm.Decimal", optional: false },
        { name: "shipCity", odata: "ShipCity", type: "Edm.String", optional: true },
        { name: "customerId", odata: "CustomerID", type: "Edm.String", optional: false },
      ],
      relationships: [
        {
          name: "customer",
          odata: "Customer",
          destination: "Customer",
          entitySet: "Customers",
          toMany: false,
          inverse: "orders",
          fk: "customerId",
        },
        {
          name: "items",
          odata: "Order_Details",
          destination: "OrderItem",
          entitySet: "OrderItems",
          toMany: true,
          inverse: "order",
          fk: "orderId",
        },
      ],
    },
    {
      name: "OrderItem",
      entitySet: "OrderItems",
      attributes: [
        { name: "id", odata: "OrderDetailID", type: "Edm.Int64", optional: false, key: true },
        { name: "quantity", odata: "Quantity", type: "Edm.Int16", optional: false },
        { name: "unitPrice", odata: "UnitPrice", type: "Edm.Decimal", optional: false },
        { name: "discount", odata: "Discount", type: "Edm.Single", optional: false },
        { name: "orderId", odata: "OrderID", type: "Edm.Int64", optional: false },
        { name: "productId", odata: "ProductID", type: "Edm.Int64", optional: false },
      ],
      relationships: [
        {
          name: "order",
          odata: "Order",
          destination: "Order",
          entitySet: "Orders",
          toMany: false,
          inverse: "items",
          fk: "orderId",
        },
        {
          name: "product",
          odata: "Product",
          destination: "Product",
          entitySet: "Products",
          toMany: false,
          inverse: "orderItems",
          fk: "productId",
        },
      ],
    },
  ],
};

export function entityByName(name: string): EntityDef {
  const found = SCHEMA.entities.find((e) => e.name === name);
  if (!found) throw new Error(`Unknown entity ${name}`);
  return found;
}

export function entityBySet(set: string): EntityDef {
  const found = SCHEMA.entities.find((e) => e.entitySet === set);
  if (!found) throw new Error(`Unknown entity set ${set}`);
  return found;
}

function rec(values: Record<string, unknown>, etag = 1): RecordObject {
  return { ...values, __etag: etag } as RecordObject;
}

export function seedData(): Record<string, RecordObject[]> {
  return {
    Category: [
      rec({ id: 1, name: "Beverages", detail: "Soft drinks, coffees, teas, beers" }),
      rec({ id: 2, name: "Condiments", detail: "Sweet and savory sauces, relishes" }),
      rec({ id: 3, name: "Confections", detail: "Desserts, candies, and sweet breads" }),
      rec({ id: 4, name: "Dairy Products", detail: "Cheeses" }),
      rec({ id: 5, name: "Produce", detail: "Dried fruit and bean curd" }),
      rec({ id: 6, name: "Seafood", detail: "Seaweed and fish" }),
    ],
    Supplier: [
      rec({ id: 1, companyName: "Exotic Liquids", city: "London", country: "UK" }),
      rec({ id: 2, companyName: "New Orleans Cajun Delights", city: "New Orleans", country: "USA" }),
      rec({ id: 3, companyName: "Grandma Kelly's Homestead", city: "Ann Arbor", country: "USA" }),
      rec({ id: 4, companyName: "Tokyo Traders", city: "Tokyo", country: "Japan" }),
      rec({ id: 5, companyName: "Cooperativa de Quesos", city: "Oviedo", country: "Spain" }),
    ],
    Product: [
      rec({ id: 1, name: "Chai", quantityPerUnit: "10 boxes x 20 bags", unitPrice: 18, unitsInStock: 39, discontinued: false, categoryId: 1, supplierId: 1 }),
      rec({ id: 2, name: "Chang", quantityPerUnit: "24 - 12 oz bottles", unitPrice: 19, unitsInStock: 17, discontinued: false, categoryId: 1, supplierId: 1 }),
      rec({ id: 3, name: "Aniseed Syrup", quantityPerUnit: "12 - 550 ml bottles", unitPrice: 10, unitsInStock: 13, discontinued: false, categoryId: 2, supplierId: 1 }),
      rec({ id: 4, name: "Chef Anton's Cajun Seasoning", quantityPerUnit: "48 - 6 oz jars", unitPrice: 22, unitsInStock: 53, discontinued: false, categoryId: 2, supplierId: 2 }),
      rec({ id: 5, name: "Grandma's Boysenberry Spread", quantityPerUnit: "12 - 8 oz jars", unitPrice: 25, unitsInStock: 120, discontinued: false, categoryId: 2, supplierId: 3 }),
      rec({ id: 6, name: "Uncle Bob's Organic Dried Pears", quantityPerUnit: "12 - 1 lb pkgs.", unitPrice: 30, unitsInStock: 15, discontinued: false, categoryId: 5, supplierId: 3 }),
      rec({ id: 7, name: "Ikura", quantityPerUnit: "12 - 200 ml jars", unitPrice: 31, unitsInStock: 31, discontinued: false, categoryId: 6, supplierId: 4 }),
      rec({ id: 8, name: "Queso Cabrales", quantityPerUnit: "1 kg pkg.", unitPrice: 21, unitsInStock: 22, discontinued: false, categoryId: 4, supplierId: 5 }),
      rec({ id: 9, name: "Konbu", quantityPerUnit: "2 kg box", unitPrice: 6, unitsInStock: 24, discontinued: false, categoryId: 6, supplierId: 4 }),
      rec({ id: 10, name: "Tofu", quantityPerUnit: "40 - 100 g pkgs.", unitPrice: 23.25, unitsInStock: 35, discontinued: false, categoryId: 5, supplierId: 4 }),
      rec({ id: 11, name: "Sir Rodney's Marmalade", quantityPerUnit: "30 gift boxes", unitPrice: 81, unitsInStock: 40, discontinued: false, categoryId: 3, supplierId: 3 }),
      rec({ id: 12, name: "Côte de Blaye", quantityPerUnit: "12 - 75 cl bottles", unitPrice: 263.5, unitsInStock: 17, discontinued: false, categoryId: 1, supplierId: 1 }),
      rec({ id: 13, name: "Guaraná Fantástica", quantityPerUnit: "12 - 355 ml cans", unitPrice: 4.5, unitsInStock: 20, discontinued: true, categoryId: 1, supplierId: 2 }),
      rec({ id: 14, name: "NuNuCa Nuß-Nougat-Creme", quantityPerUnit: "20 - 450 g glasses", unitPrice: 14, unitsInStock: 76, discontinued: false, categoryId: 3, supplierId: 3 }),
    ],
    Customer: [
      rec({ id: "ALFKI", companyName: "Alfreds Futterkiste", contactName: "Maria Anders", city: "Berlin", country: "Germany" }),
      rec({ id: "ANATR", companyName: "Ana Trujillo Emparedados", contactName: "Ana Trujillo", city: "México D.F.", country: "Mexico" }),
      rec({ id: "ANTON", companyName: "Antonio Moreno Taquería", contactName: "Antonio Moreno", city: "México D.F.", country: "Mexico" }),
      rec({ id: "AROUT", companyName: "Around the Horn", contactName: "Thomas Hardy", city: "London", country: "UK" }),
      rec({ id: "BERGS", companyName: "Berglunds snabbköp", contactName: "Christina Berglund", city: "Luleå", country: "Sweden" }),
      rec({ id: "BLAUS", companyName: "Blauer See Delikatessen", contactName: "Hanna Moos", city: "Mannheim", country: "Germany" }),
    ],
    Order: [
      rec({ id: 10248, orderDate: "2024-07-04T00:00:00Z", shippedDate: "2024-07-16T00:00:00Z", freight: 32.38, shipCity: "Reims", customerId: "ALFKI" }),
      rec({ id: 10249, orderDate: "2024-07-05T00:00:00Z", shippedDate: "2024-07-10T00:00:00Z", freight: 11.61, shipCity: "Münster", customerId: "ALFKI" }),
      rec({ id: 10250, orderDate: "2024-07-08T00:00:00Z", shippedDate: "2024-07-12T00:00:00Z", freight: 65.83, shipCity: "Rio de Janeiro", customerId: "ANATR" }),
      rec({ id: 10251, orderDate: "2024-07-08T00:00:00Z", shippedDate: "2024-07-15T00:00:00Z", freight: 41.34, shipCity: "Lyon", customerId: "ANTON" }),
      rec({ id: 10252, orderDate: "2024-07-09T00:00:00Z", shippedDate: "2024-07-11T00:00:00Z", freight: 51.3, shipCity: "Charleroi", customerId: "AROUT" }),
      rec({ id: 10253, orderDate: "2024-07-10T00:00:00Z", shippedDate: null, freight: 58.17, shipCity: "Rio de Janeiro", customerId: "ANATR" }),
      rec({ id: 10254, orderDate: "2024-07-11T00:00:00Z", shippedDate: "2024-07-23T00:00:00Z", freight: 22.98, shipCity: "Bern", customerId: "BERGS" }),
      rec({ id: 10255, orderDate: "2024-07-12T00:00:00Z", shippedDate: "2024-07-15T00:00:00Z", freight: 148.33, shipCity: "Genève", customerId: "BLAUS" }),
    ],
    OrderItem: [
      rec({ id: 1, quantity: 12, unitPrice: 14, discount: 0, orderId: 10248, productId: 11 }),
      rec({ id: 2, quantity: 10, unitPrice: 18, discount: 0, orderId: 10248, productId: 1 }),
      rec({ id: 3, quantity: 5, unitPrice: 9.8, discount: 0, orderId: 10249, productId: 3 }),
      rec({ id: 4, quantity: 9, unitPrice: 42.4, discount: 0.15, orderId: 10250, productId: 12 }),
      rec({ id: 5, quantity: 40, unitPrice: 7.7, discount: 0.15, orderId: 10250, productId: 9 }),
      rec({ id: 6, quantity: 10, unitPrice: 16.8, discount: 0.05, orderId: 10251, productId: 8 }),
      rec({ id: 7, quantity: 35, unitPrice: 16.8, discount: 0.05, orderId: 10251, productId: 4 }),
      rec({ id: 8, quantity: 15, unitPrice: 64.8, discount: 0.05, orderId: 10252, productId: 11 }),
      rec({ id: 9, quantity: 21, unitPrice: 2, discount: 0, orderId: 10252, productId: 13 }),
      rec({ id: 10, quantity: 20, unitPrice: 10, discount: 0.2, orderId: 10253, productId: 3 }),
      rec({ id: 11, quantity: 12, unitPrice: 18, discount: 0, orderId: 10254, productId: 1 }),
      rec({ id: 12, quantity: 6, unitPrice: 31, discount: 0, orderId: 10254, productId: 7 }),
      rec({ id: 13, quantity: 15, unitPrice: 15.2, discount: 0, orderId: 10255, productId: 2 }),
      rec({ id: 14, quantity: 2, unitPrice: 263.5, discount: 0, orderId: 10255, productId: 12 }),
      rec({ id: 15, quantity: 20, unitPrice: 23.25, discount: 0, orderId: 10249, productId: 10 }),
    ],
  };
}

export const FETCH_PRESETS: { label: string; request: import("./types").FetchRequest }[] = [
  {
    label: "All products",
    request: { entity: "Product", sort: [{ key: "name", ascending: true }], resultType: "managedObject" },
  },
  {
    label: "Priced over 20, in stock",
    request: {
      entity: "Product",
      predicate: "unitPrice > 20 AND unitsInStock > 0 AND discontinued == NO",
      sort: [{ key: "unitPrice", ascending: false }],
      resultType: "managedObject",
    },
  },
  {
    label: "Beverages, expand category",
    request: {
      entity: "Product",
      predicate: 'category.name == "Beverages"',
      sort: [{ key: "name", ascending: true }],
      relationshipKeyPathsForPrefetching: ["category"],
      resultType: "managedObject",
    },
  },
  {
    label: "Top 5 by price (dictionary)",
    request: {
      entity: "Product",
      sort: [{ key: "unitPrice", ascending: false }],
      fetchLimit: 5,
      propertiesToFetch: ["name", "unitPrice"],
      resultType: "dictionary",
    },
  },
  {
    label: "Count discontinued",
    request: {
      entity: "Product",
      predicate: "discontinued == YES",
      sort: [],
      resultType: "count",
    },
  },
  {
    label: "German customers",
    request: {
      entity: "Customer",
      predicate: 'country == "Germany"',
      sort: [{ key: "companyName", ascending: true }],
      resultType: "managedObject",
    },
  },
  {
    label: "Unshipped orders, expand customer",
    request: {
      entity: "Order",
      predicate: "shippedDate == nil",
      sort: [{ key: "orderDate", ascending: false }],
      relationshipKeyPathsForPrefetching: ["customer"],
      resultType: "managedObject",
    },
  },
  {
    label: "Orders for ALFKI",
    request: {
      entity: "Order",
      predicate: 'customerId == "ALFKI"',
      sort: [{ key: "orderDate", ascending: true }],
      relationshipKeyPathsForPrefetching: ["items"],
      resultType: "managedObject",
    },
  },
  {
    label: "Name begins with C",
    request: {
      entity: "Product",
      predicate: 'name BEGINSWITH[cd] "c"',
      sort: [{ key: "name", ascending: true }],
      resultType: "managedObject",
    },
  },
];
