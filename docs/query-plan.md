# A query plan for the service's reads

(Writes are planned too: [write-plan.md](write-plan.md).)

How the service answers a read, as a database does: the request, parsed,
becomes a plan in a nested relational algebra; rewrite rules push what
the store can do into the store; what is left runs here. The plan is
`OISPlan` (`OISPlan.h`), made and run by `OISServiceCall+Plan.m`.

## Why

A read is parsed into ODataKit's types (`ODataQueryOptions`,
`ODataExpression`, `ODataApplyTransformation`) and was then run by
`OISServiceCall` along four paths that each did part of the same work
(before the plan):

| Path | What it decided on its own |
|---|---|
| `readCollection` → `didFetch` → `writeCollection` | `$filter` and `$orderby` to the store or here, paging and `$skiptoken`, `$count`, `$these` (a pre-read) |
| `readApplied` → `didFetchForApply` / `didFetchGroupedForApply` | leading filters to the store, the first grouping to the store, the rest here |
| `finishApplied` / `writeAppliedEntities` | the query's `$filter`, `$orderby`, `$count`, `$skip`, `$top` after `$apply`, their `$these` again, for entities and grouped rows apart |
| `expand:` → `membersOf:` | batched or one parent at a time, the nested options, their `$these` |

Hierarchy calls and `$these` cut across all four, each gap closed added a
pre-pass or a flag, and the store was reached two ways: reads through the
handler, expansions and hierarchies straight from the context.

## The algebra

A relation is a sequence of tuples: entities (managed objects, with what
`$compute` gave them) or grouped rows (nested dictionaries). Every read
is a tree of these operators:

| Operator | OData | Relational |
|---|---|---|
| **Scan**(set) | the entity set, as the caller may see it | base relation |
| **Select**(e) | `$filter`, `filter()`, a key | σ |
| **Extend**(e as n, …) | `$compute`, `compute()` | extended projection |
| **Sort**(items) | `$orderby`, `orderby()` | τ |
| **Limit**(skip, top) | `$skip`, `$top`, `skip()`, `top()` | |
| **Aggregate**(keys; aggregates) | `groupby`, `aggregate` | γ |
| **Rank**(method, n, e) | `topcount` and its kin | |
| **Unnest**(nav as alias, outer) | `join`, `outerjoin` | μ |
| **Nest**(nav, plan) | `$expand` | ν, of a plan correlated to each tuple |
| **Union**(plans) | `concat` | ∪ (in order) |
| **Closure**(set, qualifier) | a recursive hierarchy | recursion: its nodes and their ancestors |
| **Span**(attribute) | what `month()`, `day()`, `hour()`, `minute()` and `second()` range over | the earliest and latest value, as a scalar |
| **Related**(closure, …) | `ancestors`, `descendants` | semi-join with the closure |
| **Walk**(closure, order) | `traverse` | recursion, in tree order |
| **Bind**(name := scalar plan) | `$these/aggregate(…)`, `$these/$count`, a hierarchy function | a scalar subquery, computed once and bound |
| **Count** | `/$count`, `$count=true` | |
| **Changes**(set, token) | a delta link | base relation of the history |

Expressions in operators refer to bindings by name; a binding's value is
worked out once, before the operators that use it run. `$these` is a
Bind over the plan of the collection its option means (Data Aggregation
section 3.6): for `$filter` and `$compute` the input they filter or
extend; for `$orderby` what the `$filter` left; in `$apply`, the
transformation's input; within `$expand`, each parent's members.

## Logical and physical plans

The planner makes the logical plan: the operators, in the order the
request says them. Rewrite rules then make the physical plan, in which
some operators are fused into what the store does:

- **Store scan**(entity, predicate, sort, offset, limit, prefetch):
  Scan with the Select, Sort and Limit above it pushed down, as far as
  the predicate builder writes them and nothing below them ran here.
  A bound scalar is a parameter: the predicate can use it.
- **Store aggregate**: an Aggregate on a Store scan, where the store's
  grouping gives exactly what the in-memory one would.
- **Store count**: Count of a Store scan.
- **Batched nest**: a Nest's members read once for a page of parents
  (inverse IN them; for a many-to-many, the parents again with the
  relationship, then the members), then split; the nested options'
  filter and order in that read, or where they ask for each parent's own
  `$these` or compute, run per parent here.
- **Dynamic properties**(set): the last step, for each open type's set
  among what the plan writes: the dynamic properties of all its
  entities there, rows and nested members alike, asked of its handler
  at once (`-dynamicPropertiesOfObjects:request:reply:`).

Everything else runs here, over what the store gave. `maxRowsInMemory`
bounds each operator that holds rows.

Only Store scan, Store aggregate, Store count, Changes and the Closure's
read reach the store, all through the handler (`-objectsForFetchRequest:
request:reply:` and its kin), asynchronously: expansions and hierarchies
included, so a handler that answers fetches itself is asked for them.

## Running it

The executor evaluates the physical plan from the top, each operator
over its input's relation. A step that reaches the store asks the
handler, with an `ODataReply` whose target is the call; every answer is
kept, by operator. An answer the handler gives at once is used at once;
one it gives later starts the evaluation again from the top, where all
that is known is not asked again. Expansions are worked out afresh on
each pass from what is known, so a pass cut short leaves none half done.

The rows of each operator are one relation: entities, or grouped rows
with their paths, with the names `compute` gave and the expansions
`expand()` asked for. The in-memory operators are `$apply`'s own
transformations (a `$filter` here is `filter()`, an `$orderby` here
`orderby()`), run by the code that runs `$apply`; each works out the
`$these` of its own input. A Bind is only where a store scan's filter
uses `$these`: its value is read first, by a scan of its own.

A join's members are read as an expansion's are, through the handler for
all the rows at once, even within a group's transformations. The spans
of dates are read first too, through the handler: the predicate builder
is given them rather than reading them itself.

A delta's changes are the handler's too (`-changesSince:request:reply:`,
by default the persistent history). The reads a write does (the rows it
refers to or changes, the keys it counts on from, the slices of a
temporal action) are in its plan ([write-plan.md](write-plan.md)), and go
through the handlers the same way.

## Explain

A service set to explain (`ODataService.explains`, off by default)
answers `GET <root>/$explain/<resource path>?<query>` with the plans,
not the rows:

For `Products?$filter=UnitPrice gt $these/aggregate(UnitPrice with
average)&$orderby=ProductName&$top=2&$expand=Category&$count=true`,
`physical` is:

```
Nest Category
Store scan Product where UnitPrice gt $these/aggregate(UnitPrice with average) sort ProductName, key top 2 page 2 with category
  $these/aggregate(UnitPrice with average) :=
    Value $these/aggregate(UnitPrice with average)
      Store scan Product at most 10000
$count :=
  Store count Product where UnitPrice gt $these/aggregate(UnitPrice with average)
    $these/aggregate(UnitPrice with average) :=
      Value $these/aggregate(UnitPrice with average)
        Store scan Product at most 10000
```

and `logical`, the request as it reads:

```
Nest Category
Limit top 2
  Sort ProductName
    Select UnitPrice gt $these/aggregate(UnitPrice with average)
      Scan Product
$count :=
  Count
    Sort ProductName
      ...
```

Where the read needs permissions (a handler's `readScopes`), `physical`
ends with them, one a line, each with the scopes any one of which allows
it: `Permission to read Categories: Categories.Read`. They are worked out
from the plan before it runs, and checked then.

The service logs the physical plan of each read when asked to
(`ODataService.logsPlans`). Tests assert plans beside answers: what went
to the store is a promise worth testing.

## Where it is used

Every read: collections (plain, or with `$apply`), `/$count`, single
entities, delta links, and the entities a response carries (an
operation's result, an insert's or an update's with
`return=representation`, a temporal action's slices), whose expansions
are Nests. Tests assert plans beside answers (`testExplain`), and a
handler that answers later is run against nested expansions, counts and
a grouping (`testHandlerSeesAndAnswersLater`).
