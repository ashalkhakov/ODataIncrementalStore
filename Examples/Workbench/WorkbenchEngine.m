// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WorkbenchEngine.h"
#import <string.h>
#include <math.h>

@implementation WorkbenchLogEntry
@end

static NSString *WBDecode(NSString *s)
{
  if (!s.length) return @"";
  NSString *spaced = [s stringByReplacingOccurrencesOfString:@"+" withString:@" "];
  return [spaced stringByRemovingPercentEncoding] ?: spaced;
}

// The navigation properties: set -> name -> (the set it leads to, to-many).
static NSDictionary *WBNavigation(void)
{
  static NSDictionary *table;
  if (!table) {
    table = @{
      @"Products": @{ @"Category": @[ @"Categories", @NO ], @"Suppliers": @[ @"Suppliers", @YES ], @"Stocks": @[ @"Stocks", @YES ] },
      @"Categories": @{ @"Products": @[ @"Products", @YES ] },
      @"Suppliers": @{ @"Products": @[ @"Products", @YES ] },
      @"Locations": @{ @"Stocks": @[ @"Stocks", @YES ] },
      @"Stocks": @{ @"Product": @[ @"Products", @NO ], @"Location": @[ @"Locations", @NO ] },
    };
  }
  return table;
}

// An entity while an expression is evaluated: its set, and its row.
@interface WBEntity : NSObject
@property (nonatomic, copy) NSString *set;
@property (nonatomic, strong) NSDictionary *row;
@end

@implementation WBEntity
+ (instancetype)entityInSet:(NSString *)set row:(NSDictionary *)row
{
  WBEntity *e = [[self alloc] init];
  e.set = set;
  e.row = row;
  return e;
}
@end

static void WBRefuse(NSString *why)
{
  @throw [NSException exceptionWithName:@"OData" reason:why userInfo:nil];
}

static NSDictionary *WBQuery(NSURL *url)
{
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  NSString *q = url.query;
  if (!q.length) return d;
  for (NSString *part in [q componentsSeparatedByString:@"&"]) {
    NSRange eq = [part rangeOfString:@"="];
    if (eq.location == NSNotFound) continue;
    d[WBDecode([part substringToIndex:eq.location])] = WBDecode([part substringFromIndex:eq.location + 1]);
  }
  return d;
}

static NSString *WBJSON(id obj)
{
  if (!obj || obj == [NSNull null]) return @"";
  NSError *err = nil;
  NSJSONWritingOptions opts = 0;
#ifdef NSJSONWritingPrettyPrinted
  opts = NSJSONWritingPrettyPrinted;
#endif
  NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:opts error:&err];
  if (!data) return [obj description];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *WBEtag(id version)
{
  return [NSString stringWithFormat:@"W/\"%@\"", version ?: @1];
}

@implementation WorkbenchEngine {
  NSDictionary *_aliases;  // the request's parameter aliases, while its expressions are evaluated
  NSMutableDictionary *_sets;   // entitySet → NSMutableArray of NSMutableDictionary (OData names)
  NSMutableDictionary *_seq;    // entitySet → NSNumber
  NSMutableArray *_log;
}

- (instancetype)initWithServiceRoot:(NSURL *)serviceRoot
{
  self = [super init];
  if (!self) return nil;
  _serviceRoot = [serviceRoot copy];
  _log = [NSMutableArray array];
  [self reset];
  return self;
}

- (NSArray *)log
{
  return [_log copy];
}

- (void)reset
{
  _sets = [NSMutableDictionary dictionary];
  _seq = [NSMutableDictionary dictionary];
  [_log removeAllObjects];
  [self seed];
}

- (NSMutableDictionary *)row:(NSDictionary *)values set:(NSString *)set
{
  NSMutableDictionary *row = [values mutableCopy];
  if (!row[@"__etag"]) row[@"__etag"] = @1;
  NSMutableArray *list = _sets[set];
  if (!list) {
    list = [NSMutableArray array];
    _sets[set] = list;
  }
  [list addObject:row];
  NSNumber *ident = row[@"id"] ?: row[@"ProductID"] ?: row[@"CategoryID"] ?: row[@"SupplierID"] ?: row[@"LocationID"] ?: row[@"StockID"];
  if ([ident respondsToSelector:@selector(integerValue)]) {
    NSInteger n = ident.integerValue;
    NSInteger cur = [_seq[set] integerValue];
    if (n > cur) _seq[set] = @(n);
  }
  return row;
}

- (void)seed
{
  [self row:@{ @"CategoryID": @1, @"CategoryName": @"Beverages" } set:@"Categories"];
  [self row:@{ @"CategoryID": @2, @"CategoryName": @"Condiments" } set:@"Categories"];
  [self row:@{ @"CategoryID": @3, @"CategoryName": @"Confections" } set:@"Categories"];
  [self row:@{ @"CategoryID": @4, @"CategoryName": @"Dairy Products" } set:@"Categories"];
  [self row:@{ @"CategoryID": @5, @"CategoryName": @"Produce" } set:@"Categories"];
  [self row:@{ @"CategoryID": @6, @"CategoryName": @"Seafood" } set:@"Categories"];

  [self row:@{ @"SupplierID": @1, @"CompanyName": @"Exotic Liquids", @"City": @"London", @"Country": @"UK" } set:@"Suppliers"];
  [self row:@{ @"SupplierID": @2, @"CompanyName": @"New Orleans Cajun Delights", @"City": @"New Orleans", @"Country": @"USA" } set:@"Suppliers"];
  [self row:@{ @"SupplierID": @3, @"CompanyName": @"Grandma Kelly's Homestead", @"City": @"Ann Arbor", @"Country": @"USA" } set:@"Suppliers"];
  [self row:@{ @"SupplierID": @4, @"CompanyName": @"Tokyo Traders", @"City": @"Tokyo", @"Country": @"Japan" } set:@"Suppliers"];
  [self row:@{ @"SupplierID": @5, @"CompanyName": @"Cooperativa de Quesos", @"City": @"Oviedo", @"Country": @"Spain" } set:@"Suppliers"];

  [self row:@{ @"LocationID": @1, @"LocationName": @"Warehouse North", @"City": @"Seattle", @"Country": @"USA" } set:@"Locations"];
  [self row:@{ @"LocationID": @2, @"LocationName": @"Dock 4", @"City": @"London", @"Country": @"UK" } set:@"Locations"];
  [self row:@{ @"LocationID": @3, @"LocationName": @"Cold Store", @"City": @"Tokyo", @"Country": @"Japan" } set:@"Locations"];

  void (^product)(NSInteger, NSString *, NSString *, double, BOOL, NSInteger, NSArray *) =
      ^(NSInteger pid, NSString *name, NSString *qpu, double price, BOOL disc, NSInteger cat, NSArray *sups) {
        [self row:@{
          @"ProductID": @(pid),
          @"ProductName": name,
          @"QuantityPerUnit": qpu,
          @"UnitPrice": @(price),
          @"Discontinued": @(disc),
          @"__categoryId": @(cat),
          @"__supplierIds": [sups mutableCopy]
        } set:@"Products"];
      };
  product(1, @"Chai", @"10 boxes x 20 bags", 18, NO, 1, @[ @1, @4 ]);
  product(2, @"Chang", @"24 - 12 oz bottles", 19, NO, 1, @[ @1 ]);
  product(3, @"Aniseed Syrup", @"12 - 550 ml bottles", 10, NO, 2, @[ @1 ]);
  product(4, @"Chef Anton's Cajun Seasoning", @"48 - 6 oz jars", 22, NO, 2, @[ @2 ]);
  product(5, @"Grandma's Boysenberry Spread", @"12 - 8 oz jars", 25, NO, 2, @[ @3 ]);
  product(6, @"Uncle Bob's Organic Dried Pears", @"12 - 1 lb pkgs.", 30, NO, 5, @[ @3 ]);
  product(7, @"Ikura", @"12 - 200 ml jars", 31, NO, 6, @[ @4 ]);
  product(8, @"Queso Cabrales", @"1 kg pkg.", 21, NO, 4, @[ @5 ]);
  product(9, @"Konbu", @"2 kg box", 6, NO, 6, @[ @4 ]);
  product(10, @"Tofu", @"40 - 100 g pkgs.", 23.25, NO, 5, @[ @4 ]);
  product(11, @"Sir Rodney's Marmalade", @"30 gift boxes", 81, NO, 3, @[ @3 ]);
  product(12, @"Côte de Blaye", @"12 - 75 cl bottles", 263.5, NO, 1, @[ @1 ]);
  product(13, @"Guaraná Fantástica", @"12 - 355 ml cans", 4.5, YES, 1, @[ @2 ]);
  product(14, @"NuNuCa Nuß-Nougat-Creme", @"20 - 450 g glasses", 14, NO, 3, @[ @3 ]);

  void (^stock)(NSInteger, NSInteger, NSInteger, NSInteger) = ^(NSInteger sid, NSInteger pid, NSInteger loc, NSInteger qty) {
    [self row:@{ @"StockID": @(sid), @"Quantity": @(qty), @"__productId": @(pid), @"__locationId": @(loc) } set:@"Stocks"];
  };
  stock(1, 1, 1, 39);
  stock(2, 1, 2, 12);
  stock(3, 2, 1, 17);
  stock(4, 4, 1, 53);
  stock(5, 7, 3, 31);
  stock(6, 11, 2, 40);
  stock(7, 12, 2, 8);
  stock(8, 13, 1, 20);
}

#pragma mark - Transport

// The service is in memory, so the exchange finishes before this returns.
- (void)startExchange:(ODataExchange *)exchange
{
  NSURLResponse *response = nil;
  exchange.data = [self sendRequest:exchange.request returningResponse:&response error:NULL];
  exchange.URLResponse = response;
  [exchange finish];
}

- (NSData *)sendRequest:(NSURLRequest *)request
      returningResponse:(NSURLResponse **)response
                  error:(NSError **)error
{
  NSDate *started = [NSDate date];
  NSString *method = request.HTTPMethod.uppercaseString ?: @"GET";
  NSDictionary *query = WBQuery(request.URL);
  NSString *bodyStr = request.HTTPBody.length
      ? [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding]
      : nil;
  id bodyJSON = nil;
  if (bodyStr.length) {
    bodyJSON = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
  }

  NSInteger status = 200;
  NSDictionary *headers = @{ @"Content-Type": @"application/json;odata.metadata=minimal", @"OData-Version": @"4.0" };
  NSData *data = nil;
  NSString *responseText = nil;

  @try {
    NSDictionary *out = [self handleMethod:method URL:request.URL query:query body:bodyJSON headers:request.allHTTPHeaderFields status:&status];
    if ([out[@"__text"] isKindOfClass:[NSString class]]) {
      responseText = out[@"__text"];
      data = [responseText dataUsingEncoding:NSUTF8StringEncoding];
      headers = @{ @"Content-Type": @"text/plain", @"OData-Version": @"4.0" };
    } else if (status == 204) {
      data = [NSData data];
      headers = @{ @"OData-Version": @"4.0" };
    } else {
      id payload = out[@"__body"] ?: out;
      responseText = WBJSON(payload);
      data = [responseText dataUsingEncoding:NSUTF8StringEncoding];
      NSMutableDictionary *h = [headers mutableCopy];
      if (out[@"__etag"]) h[@"ETag"] = out[@"__etag"];
      if (out[@"__location"]) h[@"Location"] = out[@"__location"];
      headers = h;
    }
  } @catch (NSException *ex) {
    status = 400;
    NSDictionary *err = @{ @"error": @{ @"code": @"400", @"message": ex.reason ?: @"bad request" } };
    responseText = WBJSON(err);
    data = [responseText dataUsingEncoding:NSUTF8StringEncoding];
  }

  if (response) {
    *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                            statusCode:status
                                           HTTPVersion:@"HTTP/1.1"
                                          headerFields:headers];
  }

  WorkbenchLogEntry *entry = [[WorkbenchLogEntry alloc] init];
  entry.method = method;
  entry.URL = request.URL.absoluteString ?: @"";
  entry.status = status;
  entry.requestHeaders = request.allHTTPHeaderFields;
  entry.requestData = request.HTTPBody;
  entry.responseHeaders = headers;
  entry.responseData = data ?: [NSData data];
  entry.date = started;
  entry.duration = -[started timeIntervalSinceNow];
  entry.storeHint = [self hintForURL:request.URL method:method];
  [_log insertObject:entry atIndex:0];
  if (_log.count > 48) [_log removeLastObject];
  if (self.didHandle) self.didHandle(entry);
  return data ?: [NSData data];
}

- (NSString *)hintForURL:(NSURL *)url method:(NSString *)method
{
  NSString *path = [self relativePath:url];
  if ([method isEqualToString:@"PATCH"] || [method isEqualToString:@"POST"] || [method isEqualToString:@"DELETE"]) {
    return @"executeRequest:withContext:error:  (NSSaveChangesRequest)";
  }
  if ([path rangeOfString:@"/$count"].location != NSNotFound) {
    return @"executeRequest:withContext:error:  (NSCountResultType)";
  }
  if ([path rangeOfString:@")/"].location != NSNotFound) {
    return @"newValueForRelationship:forObjectWithID:withContext:error:";
  }
  if ([path rangeOfString:@"("].location != NSNotFound) {
    return @"newValuesForObjectWithID:withContext:error:";
  }
  return @"executeRequest:withContext:error:  (NSFetchRequest)";
}

- (NSString *)relativePath:(NSURL *)url
{
  NSString *abs = url.absoluteString ?: @"";
  NSString *root = self.serviceRoot.absoluteString ?: @"";
  NSRange q = [abs rangeOfString:@"?"];
  if (q.location != NSNotFound) abs = [abs substringToIndex:q.location];
  if (root.length && [abs hasPrefix:root]) abs = [abs substringFromIndex:root.length];
  while ([abs hasPrefix:@"/"]) abs = [abs substringFromIndex:1];
  if ([abs hasSuffix:@"/"]) abs = [abs substringToIndex:abs.length - 1];
  abs = WBDecode(abs);
  if ([abs isEqualToString:@"%24metadata"]) abs = @"$metadata";
  return abs;
}

#pragma mark - Dispatch

- (NSDictionary *)handleMethod:(NSString *)method
                           URL:(NSURL *)url
                         query:(NSDictionary *)query
                          body:(id)body
                       headers:(NSDictionary *)headers
                        status:(NSInteger *)status
{
  NSString *text = [self relativePath:url];
  if (!text.length || [text isEqualToString:@"odata"]) {
    *status = 200;
    NSMutableArray *sets = [NSMutableArray array];
    for (NSString *set in @[ @"Categories", @"Products", @"Suppliers", @"Locations", @"Stocks" ]) {
      [sets addObject:@{ @"name": set, @"kind": @"EntitySet", @"url": set }];
    }
    return @{ @"@odata.context": @"$metadata", @"value": sets };
  }
  if ([text isEqualToString:@"$metadata"]) {
    *status = 200;
    return @{ @"__text": [self metadataXML] };
  }

  // The path and the options, read by the library's parser; what does not
  // parse is a 400 with the parser's reason.
  NSError *error = nil;
  ODataResourcePath *path = [ODataResourcePath pathWithString:text error:&error];
  ODataQueryOptions *options = path ? [ODataQueryOptions optionsWithQuery:query error:&error] : nil;
  if (!options) WBRefuse(error.localizedDescription ?: @"bad request");
  _aliases = options.aliases;

  NSMutableArray *segments = [path.segments mutableCopy];
  BOOL count = [[segments.lastObject name] isEqualToString:@"$count"];
  if (count) [segments removeLastObject];
  ODataPathSegment *first = segments.firstObject;
  NSString *set = first.name;
  if (!_sets[set]) {
    *status = 404;
    return @{ @"error": @{ @"code": @"404", @"message": [NSString stringWithFormat:@"No entity set %@", set] } };
  }
  ODataExpression *key = first.keys.count == 1 ? first.keys.allValues.firstObject : nil;
  NSString *nav = segments.count > 1 ? [segments[1] name] : nil;

  if (key) {
    NSMutableDictionary *row = [self findSet:set key:key.value];
    if (!row) {
      *status = 404;
      return @{ @"error": @{ @"code": @"404", @"message": @"Not found" } };
    }
    if (nav.length) {
      *status = 200;
      return [self navigation:set row:row name:nav options:options];
    }
    if ([method isEqualToString:@"GET"]) {
      *status = 200;
      NSDictionary *payload = [self serialize:set row:row options:options single:YES];
      return @{ @"__body": payload, @"__etag": WBEtag(row[@"__etag"]) };
    }
    if ([method isEqualToString:@"PATCH"] || [method isEqualToString:@"PUT"]) {
      NSString *ifMatch = headers[@"If-Match"] ?: headers[@"if-match"];
      NSString *have = WBEtag(row[@"__etag"]);
      if (ifMatch.length && ![ifMatch isEqualToString:@"*"] && ![ifMatch isEqualToString:have]) {
        *status = 412;
        return @{ @"error": @{ @"code": @"412", @"message": @"Precondition Failed" } };
      }
      [self applyBody:body onto:row set:set];
      row[@"__etag"] = @([row[@"__etag"] integerValue] + 1);
      *status = 200;
      NSDictionary *payload = [self serialize:set row:row options:nil single:YES];
      return @{ @"__body": payload, @"__etag": WBEtag(row[@"__etag"]) };
    }
    if ([method isEqualToString:@"DELETE"]) {
      [_sets[set] removeObject:row];
      *status = 204;
      return @{};
    }
    *status = 405;
    return @{ @"error": @{ @"message": @"Method not allowed" } };
  }

  if ([method isEqualToString:@"GET"]) {
    NSArray *rows = [self rows:_sets[set] inSet:set options:options page:!count];
    if (count) {
      *status = 200;
      return @{ @"__text": [NSString stringWithFormat:@"%lu", (unsigned long)rows.count] };
    }
    NSMutableArray *value = [NSMutableArray array];
    for (NSMutableDictionary *row in rows) {
      [value addObject:[self serialize:set row:row options:options single:NO]];
    }
    *status = 200;
    NSMutableDictionary *bodyOut = [@{ @"@odata.context": [NSString stringWithFormat:@"$metadata#%@", set], @"value": value } mutableCopy];
    if (options.includeCount.boolValue) bodyOut[@"@odata.count"] = @([self rows:_sets[set] inSet:set options:options page:NO].count);
    return bodyOut;
  }
  if ([method isEqualToString:@"POST"]) {
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    row[@"__etag"] = @1;
    [self applyBody:body onto:row set:set];
    NSString *keyName = [self keyNameForSet:set];
    id existing = row[keyName];
    BOOL assign = (existing == nil || existing == [NSNull null]);
    if (!assign && [existing respondsToSelector:@selector(integerValue)] && [existing integerValue] == 0) {
      assign = YES;
    }
    if (assign) {
      NSInteger n = [_seq[set] integerValue] + 1;
      _seq[set] = @(n);
      row[keyName] = @(n);
    }
    [_sets[set] addObject:row];
    *status = 201;
    NSDictionary *payload = [self serialize:set row:row options:nil single:YES];
    NSString *loc = [NSString stringWithFormat:@"%@%@(%@)", self.serviceRoot.absoluteString, set, row[keyName]];
    return @{ @"__body": payload, @"__etag": WBEtag(row[@"__etag"]), @"__location": loc };
  }
  *status = 405;
  return @{ @"error": @{ @"message": @"Method not allowed" } };
}

- (NSString *)keyNameForSet:(NSString *)set
{
  if ([set isEqualToString:@"Products"]) return @"ProductID";
  if ([set isEqualToString:@"Categories"]) return @"CategoryID";
  if ([set isEqualToString:@"Suppliers"]) return @"SupplierID";
  if ([set isEqualToString:@"Locations"]) return @"LocationID";
  if ([set isEqualToString:@"Stocks"]) return @"StockID";
  return @"id";
}

- (NSMutableDictionary *)findSet:(NSString *)set key:(id)key
{
  NSString *keyName = [self keyNameForSet:set];
  for (NSMutableDictionary *row in _sets[set]) {
    if ([[row[keyName] description] isEqualToString:[key description]]) return row;
  }
  return nil;
}

// Rows of a set, filtered, sorted, and paged as the options say.
- (NSArray *)rows:(NSArray *)source inSet:(NSString *)set options:(ODataQueryOptions *)options page:(BOOL)page
{
  NSArray *rows = [source copy] ?: @[];
  if (options.filter) {
    NSMutableArray *kept = [NSMutableArray array];
    for (NSDictionary *row in rows) {
      if (WBTruthy([self valueOf:options.filter it:[WBEntity entityInSet:set row:row] variables:@{}])) [kept addObject:row];
    }
    rows = kept;
  }
  if (options.orderBy.count) {
    rows = [rows sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
      for (ODataOrderItem *item in options.orderBy) {
        id av = [self valueOf:item.expression it:[WBEntity entityInSet:set row:a] variables:@{}];
        id bv = [self valueOf:item.expression it:[WBEntity entityInSet:set row:b] variables:@{}];
        NSComparisonResult r = WBOrder(av, bv);
        if (r != NSOrderedSame) return item.descending ? -r : r;
      }
      return NSOrderedSame;
    }];
  }
  if (page) {
    NSInteger skip = options.skip.integerValue;
    NSInteger top = options.top ? options.top.integerValue : NSIntegerMax;
    if (skip > 0 || top < (NSInteger)rows.count) {
      NSInteger loc = MIN(skip, (NSInteger)rows.count);
      NSInteger len = MIN(top, (NSInteger)rows.count - loc);
      rows = [rows subarrayWithRange:NSMakeRange((NSUInteger)loc, (NSUInteger)MAX(0, len))];
    }
  }
  return rows;
}

#pragma mark - Expressions

static BOOL WBTruthy(id value)
{
  return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

static BOOL WBNull(id value)
{
  return !value || value == [NSNull null];
}

// null first, then numbers by value, anything else by its text.
static NSComparisonResult WBOrder(id a, id b)
{
  if (WBNull(a) && WBNull(b)) return NSOrderedSame;
  if (WBNull(a)) return NSOrderedAscending;
  if (WBNull(b)) return NSOrderedDescending;
  if ([a isKindOfClass:[NSNumber class]] && [b isKindOfClass:[NSNumber class]]) return [a compare:b];
  return [[a description] compare:[b description]];
}

static double WBNumber(id value)
{
  return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0;
}

static NSString *WBString(id value)
{
  if (WBNull(value)) return nil;
  return [value isKindOfClass:[NSString class]] ? value : [value description];
}

// A member of what an expression has come to: an entity's property or
// navigation property, a complex value's member.
- (id)member:(NSString *)name of:(id)base
{
  if ([base isKindOfClass:[WBEntity class]]) {
    WBEntity *entity = base;
    NSArray *navigation = WBNavigation()[entity.set][name];
    if (navigation) {
      NSArray *related = [self relatedOne:entity.set row:entity.row nav:name];
      if ([navigation[1] boolValue]) {
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *row in related) [out addObject:[WBEntity entityInSet:navigation[0] row:row]];
        return out;
      }
      NSDictionary *one = related.firstObject;
      return one ? [WBEntity entityInSet:navigation[0] row:one] : [NSNull null];
    }
    return entity.row[name] ?: [NSNull null];
  }
  if ([base isKindOfClass:[NSDictionary class]]) return base[name] ?: [NSNull null];
  return [NSNull null];
}

- (id)valueOf:(ODataExpression *)e it:(WBEntity *)it variables:(NSDictionary *)variables
{
  switch (e.kind) {
    case ODataExpressionLiteral:
      return e.value ?: [NSNull null];
    case ODataExpressionVariable:
      if ([e.name isEqualToString:@"$it"] || [e.name isEqualToString:@"$root"]) return it;
      return variables[e.name] ?: [NSNull null];
    case ODataExpressionAlias: {
      ODataExpression *value = _aliases[e.name];
      if (!value) WBRefuse([NSString stringWithFormat:@"No value for @%@", e.name]);
      return [self valueOf:value it:it variables:variables];
    }
    case ODataExpressionMember:
      return [self member:e.name of:e.operand ? [self valueOf:e.operand it:it variables:variables] : it];
    case ODataExpressionCast:
      return e.operand ? [self valueOf:e.operand it:it variables:variables] : it;
    case ODataExpressionCount: {
      id collection = [self valueOf:e.operand it:it variables:variables];
      return @([collection isKindOfClass:[NSArray class]] ? [(NSArray *)collection count] : 0);
    }
    case ODataExpressionList: {
      NSMutableArray *items = [NSMutableArray array];
      for (ODataExpression *item in e.arguments) [items addObject:[self valueOf:item it:it variables:variables]];
      return items;
    }
    case ODataExpressionUnary: {
      id value = [self valueOf:e.operand it:it variables:variables];
      if ([e.name isEqualToString:@"not"]) return @(!WBTruthy(value));
      return WBNull(value) ? [NSNull null] : @(-WBNumber(value));
    }
    case ODataExpressionLambda: {
      id collection = [self valueOf:e.operand it:it variables:variables];
      NSArray *items = [collection isKindOfClass:[NSArray class]] ? collection : @[];
      BOOL any = [e.name isEqualToString:@"any"];
      if (!e.body) return @(items.count > 0);
      for (id item in items) {
        NSMutableDictionary *inner = [variables mutableCopy];
        inner[e.variable] = item;
        BOOL holds = WBTruthy([self valueOf:e.body it:it variables:inner]);
        if (any && holds) return @YES;
        if (!any && !holds) return @NO;
      }
      return @(!any);
    }
    case ODataExpressionBinary:
      return [self binary:e it:it variables:variables];
    case ODataExpressionCall:
      return [self call:e it:it variables:variables];
  }
  return [NSNull null];
}

- (id)binary:(ODataExpression *)e it:(WBEntity *)it variables:(NSDictionary *)variables
{
  NSString *op = e.name;
  if ([op isEqualToString:@"and"]) {
    return @(WBTruthy([self valueOf:e.left it:it variables:variables]) && WBTruthy([self valueOf:e.right it:it variables:variables]));
  }
  if ([op isEqualToString:@"or"]) {
    return @(WBTruthy([self valueOf:e.left it:it variables:variables]) || WBTruthy([self valueOf:e.right it:it variables:variables]));
  }
  id left = [self valueOf:e.left it:it variables:variables];
  id right = [self valueOf:e.right it:it variables:variables];
  if ([@[ @"eq", @"ne", @"gt", @"ge", @"lt", @"le" ] containsObject:op]) {
    if ([op isEqualToString:@"eq"] || [op isEqualToString:@"ne"]) {
      BOOL equal = (WBNull(left) && WBNull(right)) ||
                   (!WBNull(left) && !WBNull(right) && WBOrder(left, right) == NSOrderedSame);
      return @([op isEqualToString:@"eq"] ? equal : !equal);
    }
    if (WBNull(left) || WBNull(right)) return @NO;
    return @([self compare:left op:op right:right]);
  }
  if ([op isEqualToString:@"in"]) {
    for (id item in [right isKindOfClass:[NSArray class]] ? right : @[]) {
      if (WBOrder(left, item) == NSOrderedSame) return @YES;
    }
    return @NO;
  }
  if ([op isEqualToString:@"has"]) {
    long long flags = (long long)WBNumber(left), bits = (long long)WBNumber(right);
    return @((flags & bits) == bits);
  }
  if (WBNull(left) || WBNull(right)) return [NSNull null];
  double a = WBNumber(left), b = WBNumber(right);
  if ([op isEqualToString:@"add"]) return @(a + b);
  if ([op isEqualToString:@"sub"]) return @(a - b);
  if ([op isEqualToString:@"mul"]) return @(a * b);
  if ([op isEqualToString:@"div"] || [op isEqualToString:@"divby"]) return b == 0 ? [NSNull null] : @(a / b);
  if ([op isEqualToString:@"mod"]) return b == 0 ? [NSNull null] : @(fmod(a, b));
  WBRefuse([NSString stringWithFormat:@"No operator %@", op]);
  return nil;
}

// The canonical functions this service knows (Part 2 section 5.1.1.5-7).
- (id)call:(ODataExpression *)e it:(WBEntity *)it variables:(NSDictionary *)variables
{
  if (e.namedArguments) WBRefuse([NSString stringWithFormat:@"This service has no function %@", e.name]);
  NSMutableArray *args = [NSMutableArray array];
  for (ODataExpression *argument in e.arguments) [args addObject:[self valueOf:argument it:it variables:variables]];
  NSString *name = e.name;
  NSString *s0 = args.count > 0 ? WBString(args[0]) : nil;
  NSString *s1 = args.count > 1 ? WBString(args[1]) : nil;
  if ([name isEqualToString:@"contains"]) return @(s0 && s1 && [s0 rangeOfString:s1].location != NSNotFound);
  if ([name isEqualToString:@"startswith"]) return @(s0 && s1 && [s0 hasPrefix:s1]);
  if ([name isEqualToString:@"endswith"]) return @(s0 && s1 && [s0 hasSuffix:s1]);
  if ([name isEqualToString:@"tolower"]) return s0 ? s0.lowercaseString : [NSNull null];
  if ([name isEqualToString:@"toupper"]) return s0 ? s0.uppercaseString : [NSNull null];
  if ([name isEqualToString:@"trim"]) return s0 ? [s0 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : [NSNull null];
  if ([name isEqualToString:@"length"]) return s0 ? @(s0.length) : [NSNull null];
  if ([name isEqualToString:@"concat"]) return (s0 && s1) ? [s0 stringByAppendingString:s1] : [NSNull null];
  if ([name isEqualToString:@"indexof"]) {
    if (!s0 || !s1) return [NSNull null];
    NSRange r = [s0 rangeOfString:s1];
    return @(r.location == NSNotFound ? -1 : (NSInteger)r.location);
  }
  if ([name isEqualToString:@"substring"]) {
    if (!s0 || args.count < 2) return [NSNull null];
    NSUInteger from = MIN((NSUInteger)MAX(0, (NSInteger)WBNumber(args[1])), s0.length);
    NSUInteger length = args.count > 2 ? MIN((NSUInteger)MAX(0, (NSInteger)WBNumber(args[2])), s0.length - from) : s0.length - from;
    return [s0 substringWithRange:NSMakeRange(from, length)];
  }
  if ([name isEqualToString:@"round"]) return WBNull(args.firstObject) ? [NSNull null] : @(round(WBNumber(args[0])));
  if ([name isEqualToString:@"floor"]) return WBNull(args.firstObject) ? [NSNull null] : @(floor(WBNumber(args[0])));
  if ([name isEqualToString:@"ceiling"]) return WBNull(args.firstObject) ? [NSNull null] : @(ceil(WBNumber(args[0])));
  if ([name isEqualToString:@"matchesPattern"]) WBRefuse(@"matchesPattern is OData 4.01; this service speaks 4.0");
  WBRefuse([NSString stringWithFormat:@"This service has no function %@", name]);
  return nil;
}











- (BOOL)compare:(id)left op:(NSString *)op right:(id)right
{
  if (left == [NSNull null]) left = nil;
  if (right == [NSNull null]) right = nil;
  if ([op isEqualToString:@"eq"]) return (left == right) || [left isEqual:right] || [[left description] isEqualToString:[right description]];
  if ([op isEqualToString:@"ne"]) return !((left == right) || [left isEqual:right] || (left && right && [[left description] isEqualToString:[right description]]));
  double a = [left respondsToSelector:@selector(doubleValue)] ? [left doubleValue] : 0;
  double b = [right respondsToSelector:@selector(doubleValue)] ? [right doubleValue] : 0;
  if ([left isKindOfClass:[NSString class]] || [right isKindOfClass:[NSString class]]) {
    NSComparisonResult r = [[left description] ?: @"" compare:[right description] ?: @""];
    if ([op isEqualToString:@"gt"]) return r == NSOrderedDescending;
    if ([op isEqualToString:@"ge"]) return r != NSOrderedAscending;
    if ([op isEqualToString:@"lt"]) return r == NSOrderedAscending;
    if ([op isEqualToString:@"le"]) return r != NSOrderedDescending;
  }
  if ([op isEqualToString:@"gt"]) return a > b;
  if ([op isEqualToString:@"ge"]) return a >= b;
  if ([op isEqualToString:@"lt"]) return a < b;
  if ([op isEqualToString:@"le"]) return a <= b;
  return NO;
}


- (NSString *)destinationSet:(NSString *)set nav:(NSArray *)nav
{
  return WBNavigation()[set][nav.lastObject][0] ?: nav.lastObject;
}


- (NSArray *)relatedOne:(NSString *)set row:(NSDictionary *)row nav:(NSString *)nav
{
  if (([nav isEqualToString:@"Category"] || [nav isEqualToString:@"Categories"]) && [set isEqualToString:@"Products"]) {
    return [self rows:@"Categories" key:@"CategoryID" value:row[@"__categoryId"]];
  }
  if ([nav isEqualToString:@"Products"] && [set isEqualToString:@"Categories"]) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *p in _sets[@"Products"]) {
      if ([p[@"__categoryId"] isEqual:row[@"CategoryID"]]) [out addObject:p];
    }
    return out;
  }
  if (([nav isEqualToString:@"Suppliers"] || [nav isEqualToString:@"Supplier"]) && [set isEqualToString:@"Products"]) {
    NSMutableArray *out = [NSMutableArray array];
    for (id sid in row[@"__supplierIds"] ?: @[]) {
      [out addObjectsFromArray:[self rows:@"Suppliers" key:@"SupplierID" value:sid]];
    }
    return out;
  }
  if ([nav isEqualToString:@"Products"] && [set isEqualToString:@"Suppliers"]) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *p in _sets[@"Products"]) {
      if ([p[@"__supplierIds"] containsObject:row[@"SupplierID"]]) [out addObject:p];
    }
    return out;
  }
  if (([nav isEqualToString:@"Stocks"] || [nav isEqualToString:@"Stock"]) && [set isEqualToString:@"Products"]) {
    return [self rows:@"Stocks" key:@"__productId" value:row[@"ProductID"]];
  }
  if (([nav isEqualToString:@"Stocks"] || [nav isEqualToString:@"Stock"]) && [set isEqualToString:@"Locations"]) {
    return [self rows:@"Stocks" key:@"__locationId" value:row[@"LocationID"]];
  }
  if (([nav isEqualToString:@"Product"] || [nav isEqualToString:@"Products"]) && [set isEqualToString:@"Stocks"]) {
    return [self rows:@"Products" key:@"ProductID" value:row[@"__productId"]];
  }
  if ([nav isEqualToString:@"Location"] && [set isEqualToString:@"Stocks"]) {
    return [self rows:@"Locations" key:@"LocationID" value:row[@"__locationId"]];
  }
  return @[];
}

- (NSArray *)rows:(NSString *)set key:(NSString *)key value:(id)value
{
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary *r in _sets[set]) {
    if ([[r[key] description] isEqualToString:[value description]]) [out addObject:r];
  }
  return out;
}

- (NSDictionary *)navigation:(NSString *)set row:(NSDictionary *)row name:(NSString *)name options:(ODataQueryOptions *)options
{
  NSArray *navigation = WBNavigation()[set][name];
  if (!navigation) WBRefuse([NSString stringWithFormat:@"%@ has no navigation property %@", set, name]);
  NSString *dest = navigation[0];
  NSArray *related = [self relatedOne:set row:row nav:name];
  if ([navigation[1] boolValue]) {
    NSMutableArray *value = [NSMutableArray array];
    for (NSDictionary *r in [self rows:related inSet:dest options:options page:YES]) {
      [value addObject:[self serialize:dest row:r options:options single:NO]];
    }
    return @{ @"@odata.context": [NSString stringWithFormat:@"$metadata#%@", dest], @"value": value };
  }
  NSDictionary *one = related.firstObject;
  if (!one) return @{};
  return @{ @"__body": [self serialize:dest row:one options:options single:YES] };
}

// A row as JSON: the properties $select names (all without it, the key
// always), and the navigation properties $expand names, each with its own
// options: a nested $filter, $orderby, $top, $skip on a collection, and a
// nested $select and $expand.
- (NSDictionary *)serialize:(NSString *)set row:(NSDictionary *)row options:(ODataQueryOptions *)options single:(BOOL)single
{
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  NSString *keyName = [self keyNameForSet:set];
  NSString *root = self.serviceRoot.absoluteString ?: @"";
  out[@"@odata.id"] = [NSString stringWithFormat:@"%@%@(%@)", root, set, row[keyName]];
  out[@"@odata.etag"] = WBEtag(row[@"__etag"]);
  if (single) out[@"@odata.context"] = [NSString stringWithFormat:@"$metadata#%@/$entity", set];
  NSMutableSet *selected = nil;
  for (ODataSelectItem *item in options.select) {
    if (item.isStar) {
      selected = nil;
      break;
    }
    if (!selected) selected = [NSMutableSet setWithObject:keyName];
    [selected addObject:item.path.lastObject];
  }
  for (NSString *k in row) {
    if ([k hasPrefix:@"__"] || (selected && ![selected containsObject:k])) continue;
    out[k] = row[k];
  }
  for (ODataExpandItem *item in options.expand) {
    NSArray *names = item.isStar ? [WBNavigation()[set] allKeys] : @[ item.path.firstObject ?: @"" ];
    for (NSString *name in names) {
      NSArray *navigation = WBNavigation()[set][name];
      if (!navigation) WBRefuse([NSString stringWithFormat:@"%@ has no navigation property %@", set, name]);
      NSString *dest = navigation[0];
      NSArray *related = [self relatedOne:set row:row nav:name];
      if ([navigation[1] boolValue]) {
        NSMutableArray *value = [NSMutableArray array];
        for (NSDictionary *r in [self rows:related inSet:dest options:item.options page:YES]) {
          [value addObject:[self serialize:dest row:r options:item.options single:NO]];
        }
        out[name] = value;
      } else {
        NSDictionary *one = related.firstObject;
        out[name] = one ? [self serialize:dest row:one options:item.options single:NO] : [NSNull null];
      }
    }
  }
  return out;
}

- (void)applyBody:(id)body onto:(NSMutableDictionary *)row set:(NSString *)set
{
  if (![body isKindOfClass:[NSDictionary class]]) return;
  NSDictionary *map = body;
  [map enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
    NSString *k = key;  // gnustep-base types the key id<NSCopying>
    (void)stop;
    if ([k hasPrefix:@"@"]) return;
    if ([k hasSuffix:@"@odata.bind"] && [obj isKindOfClass:[NSString class]]) {
      NSString *nav = [k substringToIndex:k.length - 11];
      NSString *ref = (NSString *)obj;
      NSRange open = [ref rangeOfString:@"(" options:NSBackwardsSearch];
      NSRange close = [ref rangeOfString:@")" options:NSBackwardsSearch];
      if (open.location != NSNotFound && close.location > open.location) {
        NSString *raw = [ref substringWithRange:NSMakeRange(open.location + 1, close.location - open.location - 1)];
        if ([raw hasPrefix:@"'"] && [raw hasSuffix:@"'"] && raw.length >= 2) {
          raw = [raw substringWithRange:NSMakeRange(1, raw.length - 2)];
        }
        if ([nav isEqualToString:@"Category"]) row[@"__categoryId"] = @([raw integerValue]);
        else if ([nav isEqualToString:@"Product"]) row[@"__productId"] = @([raw integerValue]);
        else if ([nav isEqualToString:@"Location"]) row[@"__locationId"] = @([raw integerValue]);
      }
      return;
    }
    if ([k isEqualToString:@"Category"] && [obj isKindOfClass:[NSDictionary class]]) {
      row[@"__categoryId"] = obj[@"CategoryID"] ?: obj[@"id"];
      return;
    }
    if (obj == [NSNull null]) {
      [row removeObjectForKey:k];
      return;
    }
    row[k] = obj;
  }];
  (void)set;
}

// The Catalog, as the store's model has it (Examples/Catalog).
- (NSString *)metadataXML
{
  return @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"
         @"<edmx:Edmx Version=\"4.0\" xmlns:edmx=\"http://docs.oasis-open.org/odata/ns/edmx\">"
         @"<edmx:DataServices><Schema Namespace=\"Catalog\" xmlns=\"http://docs.oasis-open.org/odata/ns/edm\">"
         @"<EntityType Name=\"Category\"><Key><PropertyRef Name=\"CategoryID\"/></Key>"
         @"<Property Name=\"CategoryID\" Type=\"Edm.Int32\" Nullable=\"false\"/><Property Name=\"CategoryName\" Type=\"Edm.String\"/>"
         @"<NavigationProperty Name=\"Products\" Type=\"Collection(Catalog.Product)\" Partner=\"Category\"/></EntityType>"
         @"<EntityType Name=\"Product\"><Key><PropertyRef Name=\"ProductID\"/></Key>"
         @"<Property Name=\"ProductID\" Type=\"Edm.Int32\" Nullable=\"false\"/><Property Name=\"ProductName\" Type=\"Edm.String\"/>"
         @"<Property Name=\"QuantityPerUnit\" Type=\"Edm.String\"/><Property Name=\"UnitPrice\" Type=\"Edm.Decimal\"/>"
         @"<Property Name=\"Discontinued\" Type=\"Edm.Boolean\"/>"
         @"<NavigationProperty Name=\"Category\" Type=\"Catalog.Category\" Partner=\"Products\"/>"
         @"<NavigationProperty Name=\"Suppliers\" Type=\"Collection(Catalog.Supplier)\" Partner=\"Products\"/>"
         @"<NavigationProperty Name=\"Stocks\" Type=\"Collection(Catalog.Stock)\" Partner=\"Product\"/></EntityType>"
         @"<EntityType Name=\"Supplier\"><Key><PropertyRef Name=\"SupplierID\"/></Key>"
         @"<Property Name=\"SupplierID\" Type=\"Edm.Int32\" Nullable=\"false\"/><Property Name=\"CompanyName\" Type=\"Edm.String\"/>"
         @"<Property Name=\"City\" Type=\"Edm.String\"/><Property Name=\"Country\" Type=\"Edm.String\"/>"
         @"<NavigationProperty Name=\"Products\" Type=\"Collection(Catalog.Product)\" Partner=\"Suppliers\"/></EntityType>"
         @"<EntityType Name=\"Location\"><Key><PropertyRef Name=\"LocationID\"/></Key>"
         @"<Property Name=\"LocationID\" Type=\"Edm.Int32\" Nullable=\"false\"/><Property Name=\"LocationName\" Type=\"Edm.String\"/>"
         @"<Property Name=\"City\" Type=\"Edm.String\"/><Property Name=\"Country\" Type=\"Edm.String\"/>"
         @"<NavigationProperty Name=\"Stocks\" Type=\"Collection(Catalog.Stock)\" Partner=\"Location\"/></EntityType>"
         @"<EntityType Name=\"Stock\"><Key><PropertyRef Name=\"StockID\"/></Key>"
         @"<Property Name=\"StockID\" Type=\"Edm.Int32\" Nullable=\"false\"/><Property Name=\"Quantity\" Type=\"Edm.Int16\" Nullable=\"false\"/>"
         @"<NavigationProperty Name=\"Product\" Type=\"Catalog.Product\" Nullable=\"false\" Partner=\"Stocks\"/>"
         @"<NavigationProperty Name=\"Location\" Type=\"Catalog.Location\" Nullable=\"false\" Partner=\"Stocks\"/></EntityType>"
         @"<EntityContainer Name=\"Container\">"
         @"<EntitySet Name=\"Categories\" EntityType=\"Catalog.Category\"/><EntitySet Name=\"Products\" EntityType=\"Catalog.Product\"/>"
         @"<EntitySet Name=\"Suppliers\" EntityType=\"Catalog.Supplier\"/><EntitySet Name=\"Locations\" EntityType=\"Catalog.Location\"/>"
         @"<EntitySet Name=\"Stocks\" EntityType=\"Catalog.Stock\"/>"
         @"</EntityContainer></Schema></edmx:DataServices></edmx:Edmx>";
}

@end

@implementation WorkbenchNetworkTransport

- (void)startExchange:(ODataExchange *)exchange
{
  ODataExchange *inner = [[ODataExchange alloc] initWithRequest:exchange.request target:self action:@selector(innerDidFinish:)];
  inner.context = @[ exchange, [NSDate date] ];
  [ODataDefaultTransport() startExchange:inner];
}

- (void)innerDidFinish:(ODataExchange *)inner
{
  ODataExchange *outer = inner.context[0];
  NSDate *started = inner.context[1];
  outer.URLResponse = inner.URLResponse;
  outer.data = inner.data;
  outer.error = inner.error;

  WorkbenchLogEntry *entry = [[WorkbenchLogEntry alloc] init];
  NSURLRequest *request = inner.request;
  entry.method = request.HTTPMethod.uppercaseString ?: @"GET";
  entry.URL = request.URL.absoluteString ?: @"";
  NSHTTPURLResponse *http = [inner.URLResponse isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)inner.URLResponse : nil;
  entry.status = http.statusCode;
  entry.requestHeaders = request.allHTTPHeaderFields;
  entry.requestData = request.HTTPBody;
  entry.responseHeaders = http.allHeaderFields;
  entry.responseData = inner.data;
  entry.failure = inner.error.localizedDescription;
  entry.date = started;
  entry.duration = -[started timeIntervalSinceNow];
  entry.storeHint = @"";
  void (^report)(WorkbenchLogEntry *) = self.didHandle;
  // The main thread may be waiting for this very exchange: report later,
  // never wait for it.
  if (report) [self performSelectorOnMainThread:@selector(report:) withObject:@[ [report copy], entry ] waitUntilDone:NO];
  [outer finish];
}

- (void)report:(NSArray *)blockAndEntry
{
  void (^report)(WorkbenchLogEntry *) = blockAndEntry[0];
  report(blockAndEntry[1]);
}

@end
