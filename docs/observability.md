# Observability

What a server built on HTTPServerKit says about itself, and how to listen:
logs, metrics, traces, health. `ois-serve` has all of it; an application
of its own (`HSApplication`) has it by the same settings.

## Logs

Two kinds of line, both on standard error, both through the shared `HSLog`
(`<HTTPServerKit/HSLog.h>`), so an application that sends them elsewhere
overrides one method (`-writeLine:`).

- **The access log**, a line per request (`AccessLog`, on by default):
  time, level (`warn` for a 5xx, or slower than `SlowRequestThreshold`),
  remote, principal, method, target, route pattern, operation, status,
  bytes, `duration_ms`, `request_id`, `trace_id`, `span_id`, user agent.
- **Everything else**: start and stop, warnings about settings, a handler
  that raised, a store that failed, an identity provider that did not
  answer. Each line names its component (`ODataService`,
  `HSJWTAuthenticator`, the application's name) and carries the request's
  `request_id`, `trace_id` and `span_id` when it is about one.

| Setting | |
|---|---|
| `AccessLog` | `YES` (text), `json`, or `NO` |
| `LogFormat` | `text` or `json`; default `json` when `AccessLog` is |
| `LogLevel` | `debug`, `info` (default), `warn`, `error` |

As JSON, a log collector (Loki, Elasticsearch, CloudWatch) reads each line
as it is, and puts it beside the trace with the same `trace_id`:

```json
{"time":"2026-10-01T16:35:13.820Z","level":"error","component":"ODataService",
 "message":"GET /odata/Orders failed: ...","request_id":"450176ae-...","trace_id":"4bf92f35...","span_id":"0c215883..."}
```

As text, the same is `ODataService: error: GET /odata/Orders failed: ...
(request_id=..., span_id=..., trace_id=...)`.

## Metrics

Prometheus's text format at `/metrics` (`MetricsPath`), on the admin
listener when there is one (`AdminPort`). Labels are route patterns,
operations, entities and reasons, never paths, tokens or names, so a client
cannot make up new series.

| Metric | Labels | |
|---|---|---|
| `http_requests_total` | method, route, status | |
| `http_request_duration_seconds` | method, route | histogram |
| `http_response_size_bytes` | method, route | histogram |
| `http_requests_in_flight` | | gauge |
| `http_operations_total` | route, operation, method, status | an OData entity set, an OpenAPI operationId |
| `http_auth_failures_total` | reason | 401s and 403s, below |
| `http_auth_provider_requests_total` | endpoint, outcome | the identity provider: `discovery`, `keys`, `introspection`; a status, or `error` |
| `http_auth_provider_request_duration_seconds` | endpoint | histogram |
| `odata_plan_duration_seconds` | entity | reading and planning a request |
| `odata_execution_duration_seconds` | entity | running the plan, store requests included |
| `odata_store_request_duration_seconds` | operation, entity | `fetch`, `count`, `aggregate`, `changes`, `write`, `save` |
| `odata_store_errors_total` | operation, entity | |
| `odata_store_rows_total` | entity | rows the store answered with |
| `otel_exporter_spans_total` | outcome | `exported`, `failed`, `dropped` |
| `process_start_time_seconds`, `process_resident_memory_bytes`, `httpserverkit_build_info` | | |

`http_auth_failures_total`'s reason is the authenticator's when it gives
one: `malformed`, `algorithm`, `token_type`, `unknown_key`, `signature`,
`issuer`, `audience`, `no_expiry`, `expired`, `not_yet_valid`,
`no_subject`, `insufficient_scope`, `inactive` (introspection),
`proxy_secret`, `provider_unavailable` (the provider did not answer: a
503), `timeout`. Otherwise `unauthenticated` for a 401 and `forbidden` for
a 403. A rise in `expired` is clients that do not refresh; in `signature`
or `unknown_key`, a key rotation the server has not caught up with, or
forgeries; in `provider_unavailable`, the provider.

The store's metrics time a handler's answer, which is the store's unless
the handler does something else: a slow `fetch Product` with many
`odata_store_rows_total` is a query reading more than it returns.

## Traces

Each request is a trace, or a part of one: the caller's `traceparent` is
taken (a proxy's, a client's), and the server's spans go under it. They
are exported over OTLP/HTTP (JSON) to an OpenTelemetry Collector, or to
anything that takes OTLP on port 4318 (Jaeger, Tempo, Honeycomb, Datadog's
agent).

```
GET /odata/*                          server     http.route, http.response.status_code, client.address, ...
├─ authenticate                       internal   auth.outcome, auth.failure_reason
│  └─ GET keys                        client     the identity provider, when its keys are fetched
└─ ODataService GET Orders            internal   odata.resource, http.response.status_code
   ├─ plan                            internal   odata.plan (the plan's tree), odata.plan.kind
   └─ execute                         internal
      ├─ fetch Order                  internal   db.system.name, db.collection.name, db.response.returned_rows
      │  └─ (the store's own spans, when it traces: below)
      ├─ count Order
      └─ save Order                   internal   odata.inserted, odata.updated, odata.deleted
```

A `$batch` is one `ODataService POST $batch` span, with each of its
requests' spans under it.

### Turning it on

Nothing is recorded until an endpoint is named, by a setting or by
OpenTelemetry's own variables:

| Setting | Variable | |
|---|---|---|
| `OTLPEndpoint` | `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://collector:4318`; `/v1/traces` is added |
| | `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | the whole traces URL |
| | `OTEL_EXPORTER_OTLP_HEADERS` | `api-key=...,tenant=...` |
| `TraceSampleRatio` | `OTEL_TRACES_SAMPLER`, `OTEL_TRACES_SAMPLER_ARG` | default: every trace (`parentbased_always_on`) |
| `ServiceName` | `OTEL_SERVICE_NAME` | default: the process's name |
| | `OTEL_RESOURCE_ATTRIBUTES` | `deployment.environment=prod,...` |
| | `OTEL_SDK_DISABLED`, `OTEL_TRACES_EXPORTER=none` | off |

```sh
docker run -e OIS_MODEL=... -e OTEL_EXPORTER_OTLP_ENDPOINT=http://otelcol:4318 \
           -e OTEL_SERVICE_NAME=orders-api ois-serve
```

Sampling is by trace: a new trace is sampled by `TraceSampleRatio`, and a
caller's choice (the `traceparent`'s flag) is kept, so a trace is whole or
absent. Spans go out in batches (every 5 seconds, or 512 at a time), from a
thread of their own; a collector that is away is asked again within 10
seconds, and a queue that fills (2048) drops spans rather than make
requests wait. `otel_exporter_spans_total` and a warning (at most one a
minute) say so. On `SIGTERM` the last spans are sent before the process
exits. Only OTLP over HTTP with JSON is spoken: `OTEL_EXPORTER_OTLP_PROTOCOL`
`grpc` or `http/protobuf` is refused at start, not ignored.

### Spans of one's own

OTelKit (`<OTelKit/OTelKit.h>`) is a library of its own, Foundation only,
which HTTPServerKit and ODataService use. A handler adds to the request's
span, or makes its own under it:

```objc
- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply
{
  [request.span setAttribute:@(cart.items.count) forKey:@"cart.items"];
  OTSpan *charge = [[OTTracer tracerNamed:@"Billing" version:@"1.0"]
                     startSpanNamed:@"charge" kind:OTSpanKindClient parent:request.span.context attributes:nil];
  ...
  [charge end];
}
```

An ODataService handler sees the request's trace as its `traceparent`
header; its store requests are already spans.

## A store that traces: FreeCoreData

The service's spans stop at the store's door: `fetch Order` says how long
the store took, not what it did. A Core Data that traces its own work (the
SQL it ran, rows decoded, faults fired) puts its spans under that one. The
approach, so that FreeCoreData does not link OTelKit or know of ODataKit:

**The current span.** The service makes each store request's span current
on its thread while the store works (`-[OTSpan becomeCurrent]`).
FreeCoreData does all of a store's work on the calling thread, under the
coordinator's lock (a private queue context's queue, the main queue, or the
caller's thread), so a span it starts on that thread finds its parent
there, with nothing handed through Core Data's API.

**A protocol of its own.** FreeCoreData declares what it calls, with
OTelKit's selectors, and is handed an object that answers them:

```objc
// CDTracing.h, in FreeCoreData
@protocol CDSpan <NSObject>
- (void)setAttribute:(nullable id)value forKey:(NSString *)key;
- (void)recordError:(NSError *)error;
- (void)end;
@end

@protocol CDTracer <NSObject>
// Under this thread's current span, and current until it ends.
- (id<CDSpan>)startSpanNamed:(NSString *)name attributes:(nullable NSDictionary<NSString *, id> *)attributes;
@end

@interface NSPersistentStoreCoordinator (CDTracing)
// nil (the default): nothing is traced, and nothing costs more than a nil test.
+ (void)cd_setTracer:(nullable id<CDTracer>)tracer;
+ (nullable id<CDTracer>)cd_tracer;
@end
```

`OTTracer` and `OTSpan` answer those selectors as they are, so any OTelKit
tracer is a `CDTracer`. ODataService's module hands one over when the
class method is there (`ODataServiceModule`, by `respondsToSelector:`), so
nothing changes on either side when it is not; an application without
ODataService calls `cd_setTracer:` itself, with the tracer as
`(id<CDTracer>)`.

**Where the spans go**, from the store's call paths:

- `-[CDSQLStore execute:parameters:error:]` (PostgreSQL, MySQL), where
  every statement passes: a span per statement, `db.query.text` (with
  parameters as `?`, never their values), `db.system.name`, rows.
- SQLite: `prepareStatement()` has the text but not the time; a span from
  prepare to the statement's finalize, or `sqlite3_trace_v2` with
  `SQLITE_TRACE_PROFILE` on the handle, which gives both.
- `-[NSManagedObjectContext save:]`: a span over `_coordinatorLocked_save:`,
  its retries an event each.

Kept to what a trace needs: a span per statement, not per row, and no
values (a value may be anyone's data).

## Health

`/health` (`HealthPath`) answers 200 while the process runs; `/ready`
(`ReadyPath`) answers whether to send it requests: 503 while it drains, or
while a readiness check (a mounted service's store, an application's own
`HSReadinessCheck`) fails or does not answer in five seconds. On
`SIGTERM` it turns not ready, waits `DrainDelay` for a load balancer to
notice, stops accepting, and gives the requests under way
`ShutdownTimeout`.
