// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "HSAuthentication.h"
#import "HSSignature.h"

// The scopes a token has: scope, space-separated, or scp, an array.
static NSSet *HSScopes(NSDictionary *claims)
{
  id scope = claims[@"scope"];
  if ([scope isKindOfClass:[NSString class]]) {
    return [NSSet setWithArray:[scope componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
  }
  id scp = claims[@"scp"];
  if ([scp isKindOfClass:[NSArray class]]) return [NSSet setWithArray:scp];
  if ([scp isKindOfClass:[NSString class]]) return [NSSet setWithArray:[scp componentsSeparatedByString:@" "]];
  return [NSSet set];
}

@implementation HSPrincipal

- (instancetype)initWithSubject:(NSString *)subject claims:(NSDictionary *)claims
{
  self = [super init];
  if (!self) return nil;
  _subject = [subject copy];
  _claims = [claims copy] ?: @{};
  return self;
}

- (NSSet<NSString *> *)scopes
{
  return HSScopes(self.claims);
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<HSPrincipal %@>", self.subject];
}

@end

#pragma mark - Replies

@interface HSAuthenticationReply ()
@property (nonatomic, strong, nullable) id target;
@property (nonatomic) SEL action;
@property (nonatomic, readwrite) BOOL finished;
@property (nonatomic, readwrite, strong, nullable) HSPrincipal *principal;
@property (nonatomic, readwrite, strong, nullable) NSError *error;
@end

@implementation HSAuthenticationReply

- (instancetype)initWithTarget:(id)target action:(SEL)action
{
  self = [super init];
  if (!self) return nil;
  _target = target;
  _action = action;
  return self;
}

- (void)setTimeout:(NSTimeInterval)timeout
{
  _timeout = timeout;
  if (timeout <= 0) return;
  HSAuthenticationReply *reply = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
    [reply failWithError:HSError(504, @"Who is asking could not be found out in time")];
  });
}

- (void)finishWithPrincipal:(HSPrincipal *)principal error:(NSError *)error
{
  id target;
  @synchronized (self) {
    if (self.finished) return;
    self.finished = YES;
    self.principal = principal;
    self.error = error;
    target = self.target;
    self.target = nil;
  }
  if (!target) return;
  void (*send)(id, SEL, id) = (void (*)(id, SEL, id))[target methodForSelector:self.action];
  send(target, self.action, self);
}

- (void)finishWithPrincipal:(HSPrincipal *)principal
{
  [self finishWithPrincipal:principal error:nil];
}

- (void)failWithError:(NSError *)error
{
  [self finishWithPrincipal:nil error:error ?: HSError(401, @"The request is refused")];
}

@end

#pragma mark - Fetching

@implementation HSFetch {
  id _target;
  SEL _action;
}

- (instancetype)initWithRequest:(NSURLRequest *)request target:(id)target action:(SEL)action
{
  self = [super init];
  if (!self) return nil;
  _request = [request copy];
  _target = target;
  _action = action;
  return self;
}

- (void)finish
{
  id target;
  @synchronized (self) {
    target = _target;
    _target = nil;
  }
  if (!target) return;
  void (*send)(id, SEL, id) = (void (*)(id, SEL, id))[target methodForSelector:_action];
  send(target, _action, self);
}

@end

#if defined(__APPLE__) || (defined(GS_HAVE_NSURLSESSION) && GS_HAVE_NSURLSESSION)
#define HS_HAVE_NSURLSESSION 1
#else
#define HS_HAVE_NSURLSESSION 0
#endif

#if HS_HAVE_NSURLSESSION
@interface HSSessionFetcher : NSObject <HSFetching>
@end

@implementation HSSessionFetcher
- (void)startFetch:(HSFetch *)fetch
{
  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:fetch.request
                                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    fetch.data = data;
    fetch.response = response;
    fetch.error = error;
    [fetch finish];
  }];
  [task resume];
}
@end
#endif

#if !defined(__APPLE__)
// gnustep-base without libcurl: a synchronous NSURLConnection on a thread of
// its own.
@interface HSConnectionFetcher : NSObject <HSFetching>
@end

@implementation HSConnectionFetcher
- (void)startFetch:(HSFetch *)fetch
{
  [NSThread detachNewThreadSelector:@selector(send:) toTarget:self withObject:fetch];
}

- (void)send:(HSFetch *)fetch
{
  @autoreleasepool {
    NSURLResponse *response = nil;
    NSError *error = nil;
    fetch.data = [NSURLConnection sendSynchronousRequest:fetch.request returningResponse:&response error:&error];
    fetch.response = response;
    fetch.error = error;
    [fetch finish];
  }
}
@end
#endif

id<HSFetching> HSDefaultFetcher(void)
{
  static id<HSFetching> fetcher;
  @synchronized ([HSFetch class]) {
    if (!fetcher) {
#if HS_HAVE_NSURLSESSION
      if (NSClassFromString(@"NSURLSession")) fetcher = [[HSSessionFetcher alloc] init];
#endif
#if !defined(__APPLE__)
      if (!fetcher) fetcher = [[HSConnectionFetcher alloc] init];
#endif
    }
  }
  return fetcher;
}

// Equal, taking as long whatever the difference: a secret compared byte by
// byte, stopping at the first that differs, tells how much of a guess was
// right.
static BOOL HSSecretsEqual(NSString *given, NSString *expected)
{
  NSData *a = [given dataUsingEncoding:NSUTF8StringEncoding];
  NSData *b = [expected dataUsingEncoding:NSUTF8StringEncoding];
  const unsigned char *x = a.bytes, *y = b.bytes;
  unsigned char difference = a.length == b.length ? 0 : 1;
  for (NSUInteger i = 0; i < b.length; i++) difference |= (i < a.length ? x[i] : 0) ^ y[i];
  return difference == 0;
}

@implementation HSTrustedHeaderAuthenticator

- (instancetype)initWithSubjectHeader:(NSString *)header
{
  self = [super init];
  if (!self) return nil;
  _subjectHeader = [header copy];
  _claimHeaders = @{ @"email": @"X-Forwarded-Email",
                     @"preferred_username": @"X-Forwarded-Preferred-Username",
                     @"groups": @"X-Forwarded-Groups" };
  _listClaims = [NSSet setWithObject:@"groups"];
  return self;
}

- (instancetype)init
{
  return [self initWithSubjectHeader:@"X-Forwarded-User"];
}

- (void)authenticateRequest:(HSRequest *)request reply:(HSAuthenticationReply *)reply
{
  if (self.secretHeader.length && self.secret.length) {
    NSString *given = [request valueForHeader:self.secretHeader];
    if (!given || !HSSecretsEqual(given, self.secret)) {
      [reply failWithError:HSError(401, @"The request did not come through the service's proxy")];
      return;
    }
  }
  NSString *subject = [[request valueForHeader:self.subjectHeader] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (!subject.length) {
    [reply finishWithPrincipal:nil];
    return;
  }
  NSMutableDictionary *claims = [NSMutableDictionary dictionary];
  for (NSString *claim in self.claimHeaders) {
    NSString *value = [request valueForHeader:self.claimHeaders[claim]];
    if (!value.length) continue;
    if ([self.listClaims containsObject:claim]) {
      NSMutableArray *items = [NSMutableArray array];
      for (NSString *item in [value componentsSeparatedByString:@","]) {
        NSString *trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length) [items addObject:trimmed];
      }
      claims[claim] = items;
    } else {
      claims[claim] = value;
    }
  }
  [reply finishWithPrincipal:[[HSPrincipal alloc] initWithSubject:subject claims:claims]];
}

@end

#pragma mark - Bearer tokens

// Why a token was refused, for the challenge (RFC 6750 section 3).
static NSString * const HSBearerErrorKey = @"HSBearerError";

// The token of Authorization: Bearer <token>; nil for none, or another
// scheme.
static NSString *HSBearerToken(HSRequest *request)
{
  NSString *authorization = [request valueForHeader:@"Authorization"];
  NSRange space = [authorization rangeOfString:@" "];
  if (space.location == NSNotFound) return nil;
  if ([[authorization substringToIndex:space.location] caseInsensitiveCompare:@"Bearer"] != NSOrderedSame) return nil;
  NSString *token = [[authorization substringFromIndex:space.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  return token.length ? token : nil;
}

static void HSRefuse(HSRequest *request, HSAuthenticationReply *reply, NSInteger status, NSString *code, NSString *description)
{
  request.userInfo[HSBearerErrorKey] = @{ @"error": code, @"description": description };
  [reply failWithError:HSError(status, description)];
}

// A token without the scopes every request needs: 403, the challenge
// naming them (insufficient_scope).
static void HSRefuseScopes(HSAuthenticationReply *reply, NSArray<NSString *> *scopes)
{
  NSString *description = [NSString stringWithFormat:@"The token needs the scopes %@", [scopes componentsJoinedByString:@" "]];
  NSMutableDictionary *info = [HSError(403, description).userInfo mutableCopy];
  info[HSErrorScopesKey] = scopes;
  [reply failWithError:[NSError errorWithDomain:HSErrorDomain code:403 userInfo:info]];
}

static NSString *HSBearerChallenge(HSRequest *request)
{
  NSMutableString *challenge = [NSMutableString stringWithString:@"Bearer realm=\"api\""];
  NSDictionary *refusal = request.userInfo[HSBearerErrorKey];
  if (refusal) {
    NSCharacterSet *unsafe = [NSCharacterSet characterSetWithCharactersInString:@"\"\\"];
    NSString *description = [[refusal[@"description"] componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@"'"];
    [challenge appendFormat:@", error=\"%@\", error_description=\"%@\"", refusal[@"error"], description];
  }
  return challenge;
}

// What is wrong with a token's claims, or nil: iss, aud, exp, nbf, sub.
static NSString *HSClaimsProblem(NSDictionary *claims, NSString *issuer, NSString *audience, NSTimeInterval leeway, BOOL needsExpiry)
{
  if (issuer && ![claims[@"iss"] isEqual:issuer]) return @"The token is not from this service's issuer";
  if (audience) {
    id aud = claims[@"aud"];
    BOOL ours = [aud isEqual:audience] || ([aud isKindOfClass:[NSArray class]] && [aud containsObject:audience]);
    if (!ours) return @"The token is not for this service";
  }
  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  id exp = claims[@"exp"];
  if (![exp isKindOfClass:[NSNumber class]]) {
    if (needsExpiry) return @"The token has no expiry";
  } else if ([exp doubleValue] + leeway <= now) {
    return @"The token has expired";
  }
  id nbf = claims[@"nbf"];
  if ([nbf isKindOfClass:[NSNumber class]] && [nbf doubleValue] - leeway > now) return @"The token is not valid yet";
  return nil;
}


// The principal, when the token's claims hold: 401 or 403 otherwise.
static HSPrincipal *HSCheckedPrincipal(HSRequest *request, HSAuthenticationReply *reply, NSDictionary *claims, NSString *subject,
                                    NSSet *requiredScopes)
{
  if (![subject isKindOfClass:[NSString class]] || ![subject length]) {
    HSRefuse(request, reply, 401, @"invalid_token", @"The token names no subject");
    return nil;
  }
  if (requiredScopes.count && ![requiredScopes isSubsetOfSet:HSScopes(claims)]) {
    HSRefuseScopes(reply, [requiredScopes.allObjects sortedArrayUsingSelector:@selector(compare:)]);
    return nil;
  }
  return [[HSPrincipal alloc] initWithSubject:subject claims:claims];
}

// A JSON object from the body of a 200, or nil.
static NSDictionary *HSJSONObject(HSFetch *fetch)
{
  NSHTTPURLResponse *http = [fetch.response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)fetch.response : nil;
  if (fetch.error || http.statusCode != 200 || !fetch.data.length) return nil;
  id json = [NSJSONSerialization JSONObjectWithData:fetch.data options:0 error:NULL];
  return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

typedef void (^HSFetched)(NSDictionary *json);

// GET or POST, the completion called with the JSON object of a 200, or nil.
@interface HSJSONFetch : NSObject
+ (void)request:(NSURLRequest *)request fetcher:(id<HSFetching>)fetcher then:(HSFetched)then;
@end

@implementation HSJSONFetch
+ (void)request:(NSURLRequest *)request fetcher:(id<HSFetching>)fetcher then:(HSFetched)then
{
  HSFetch *fetch = [[HSFetch alloc] initWithRequest:request target:self action:@selector(didFetch:)];
  fetch.context = [then copy];
  [fetcher startFetch:fetch];
}

+ (void)didFetch:(HSFetch *)fetch
{
  HSFetched then = fetch.context;
  then(HSJSONObject(fetch));
}
@end

#pragma mark - JWT

@implementation HSJWTAuthenticator {
  NSArray<NSDictionary *> *_fetchedKeys;
  NSDate *_fetchedAt;
  NSURL *_discoveredKeySetURL;
  NSMutableArray<void (^)(NSArray *keys, NSError *error)> *_waiters;
  BOOL _fetching;
}

- (instancetype)initWithIssuer:(NSString *)issuer audience:(NSString *)audience
{
  self = [super init];
  if (!self) return nil;
  _issuer = [issuer copy];
  _audience = [audience copy];
  _algorithms = HSSignatureAlgorithms();
  _leeway = 60;
  _keySetLifetime = 3600;
  _keySetRefetchInterval = 60;
  _fetcher = HSDefaultFetcher();
  _waiters = [NSMutableArray array];
  return self;
}

- (NSString *)challengeForRequest:(HSRequest *)request
{
  return HSBearerChallenge(request);
}

- (NSDictionary *)authorizationDescription
{
  return @{ @"@type": @"Org.OData.Authorization.V1.OpenIDConnect", @"Name": @"OpenIDConnect",
            @"Description": @"An access token from the issuer, as Authorization: Bearer", @"IssuerUrl": self.issuer };
}

- (void)authenticateRequest:(HSRequest *)request reply:(HSAuthenticationReply *)reply
{
  NSString *token = HSBearerToken(request);
  if (!token) {
    [reply finishWithPrincipal:nil];
    return;
  }
  NSArray<NSString *> *parts = [token componentsSeparatedByString:@"."];
  NSData *headerData = parts.count == 3 ? HSBase64URLDecode(parts[0]) : nil;
  NSData *payloadData = parts.count == 3 ? HSBase64URLDecode(parts[1]) : nil;
  NSData *signature = parts.count == 3 ? HSBase64URLDecode(parts[2]) : nil;
  NSDictionary *header = headerData ? [NSJSONSerialization JSONObjectWithData:headerData options:0 error:NULL] : nil;
  NSDictionary *claims = payloadData ? [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:NULL] : nil;
  if (![header isKindOfClass:[NSDictionary class]] || ![claims isKindOfClass:[NSDictionary class]] || !signature) {
    HSRefuse(request, reply, 401, @"invalid_token", @"The token is not a signed JWT");
    return;
  }
  // The algorithm is the service's to choose, not the token's: none and
  // HMAC (with the public key as its secret) are the classic forgeries.
  NSString *alg = header[@"alg"];
  if (![alg isKindOfClass:[NSString class]] || ![self.algorithms containsObject:alg] || ![HSSignatureAlgorithms() containsObject:alg]) {
    HSRefuse(request, reply, 401, @"invalid_token", [NSString stringWithFormat:@"The token's algorithm %@ is not taken here", alg]);
    return;
  }
  if (header[@"crit"]) {
    HSRefuse(request, reply, 401, @"invalid_token", @"The token has critical header parameters this service does not know");
    return;
  }
  id typ = header[@"typ"];
  if (typ) {
    NSString *type = [typ isKindOfClass:[NSString class]] ? [typ lowercaseString] : @"";
    if (![@[ @"jwt", @"at+jwt", @"application/at+jwt" ] containsObject:type]) {
      HSRefuse(request, reply, 401, @"invalid_token", [NSString stringWithFormat:@"A %@ is not an access token", typ]);
      return;
    }
  }
  id kid = header[@"kid"];
  if (kid && ![kid isKindOfClass:[NSString class]]) kid = nil;
  NSData *input = [[NSString stringWithFormat:@"%@.%@", parts[0], parts[1]] dataUsingEncoding:NSASCIIStringEncoding];

  void (^check)(NSArray *) = ^(NSArray *keys) {
    [self check:request reply:reply alg:alg kid:kid input:input signature:signature claims:claims keys:keys];
  };
  NSArray *keys = [self currentKeysForKid:kid];
  if (keys) {
    check(keys);
    return;
  }
  [self fetchKeysThen:^(NSArray *fetched, NSError *error) {
    if (error) {
      [reply failWithError:error];
    } else {
      check(fetched);
    }
  }];
}

- (void)check:(HSRequest *)request reply:(HSAuthenticationReply *)reply alg:(NSString *)alg kid:(NSString *)kid
        input:(NSData *)input signature:(NSData *)signature claims:(NSDictionary *)claims keys:(NSArray *)keys
{
  // The key the token names; without a name, each key there is.
  BOOL verified = NO;
  NSString *reason = kid ? [NSString stringWithFormat:@"The issuer has no key %@", kid] : @"The issuer has no key";
  for (NSDictionary *key in keys) {
    if (![key isKindOfClass:[NSDictionary class]]) continue;
    if (kid && ![key[@"kid"] isEqual:kid]) continue;
    NSString *why = nil;
    if (HSVerifyJWS(alg, key, input, signature, &why)) {
      verified = YES;
      break;
    }
    reason = [NSString stringWithFormat:@"The token's signature: %@", why];
  }
  if (!verified) {
    HSRefuse(request, reply, 401, @"invalid_token", reason);
    return;
  }
  NSString *problem = HSClaimsProblem(claims, self.issuer, self.audience, self.leeway, YES);
  if (problem) {
    HSRefuse(request, reply, 401, @"invalid_token", problem);
    return;
  }
  HSPrincipal *principal = HSCheckedPrincipal(request, reply, claims, claims[@"sub"], self.requiredScopes);
  if (principal) [reply finishWithPrincipal:principal];
}

#pragma mark Keys

// The keys to check a token with now, or nil when they are to be fetched:
// none yet, too old, or without the token's key (rotated, maybe) and not
// fetched within keySetRefetchInterval.
- (NSArray *)currentKeysForKid:(NSString *)kid
{
  NSDictionary *given = self.keySet;
  if (given) {
    id keys = given[@"keys"];
    return [keys isKindOfClass:[NSArray class]] ? keys : @[];
  }
  @synchronized (self) {
    if (!_fetchedKeys || -[_fetchedAt timeIntervalSinceNow] > self.keySetLifetime) return nil;
    if (kid && -[_fetchedAt timeIntervalSinceNow] >= self.keySetRefetchInterval) {
      BOOL known = NO;
      for (NSDictionary *key in _fetchedKeys) {
        if ([key isKindOfClass:[NSDictionary class]] && [key[@"kid"] isEqual:kid]) known = YES;
      }
      if (!known) return nil;
    }
    return _fetchedKeys;
  }
}

- (void)fetchKeysThen:(void (^)(NSArray *keys, NSError *error))then
{
  @synchronized (self) {
    [_waiters addObject:[then copy]];
    if (_fetching) return;
    _fetching = YES;
  }
  NSURL *keySetURL = self.keySetURL;
  @synchronized (self) {
    if (!keySetURL) keySetURL = _discoveredKeySetURL;
  }
  if (keySetURL) {
    [self fetchKeySet:keySetURL];
    return;
  }
  // OpenID Connect Discovery 1.0, section 4.
  NSString *base = [self.issuer hasSuffix:@"/"] ? [self.issuer substringToIndex:self.issuer.length - 1] : self.issuer;
  NSURL *discovery = [NSURL URLWithString:[base stringByAppendingString:@"/.well-known/openid-configuration"]];
  if (!discovery) {
    [self fetched:nil failure:@"The issuer is not a URL"];
    return;
  }
  [HSJSONFetch request:[NSURLRequest requestWithURL:discovery] fetcher:self.fetcher then:^(NSDictionary *json) {
    NSURL *found = [json[@"jwks_uri"] isKindOfClass:[NSString class]] ? [NSURL URLWithString:json[@"jwks_uri"]] : nil;
    if (!json || ![json[@"issuer"] isEqual:self.issuer] || !found) {
      [self fetched:nil failure:@"The issuer's discovery document does not name its keys"];
      return;
    }
    @synchronized (self) {
      self->_discoveredKeySetURL = found;
    }
    [self fetchKeySet:found];
  }];
}

- (void)fetchKeySet:(NSURL *)url
{
  [HSJSONFetch request:[NSURLRequest requestWithURL:url] fetcher:self.fetcher then:^(NSDictionary *json) {
    NSArray *keys = [json[@"keys"] isKindOfClass:[NSArray class]] ? json[@"keys"] : nil;
    [self fetched:keys failure:keys ? nil : @"The issuer's keys could not be fetched"];
  }];
}

- (void)fetched:(NSArray *)keys failure:(NSString *)failure
{
  NSArray *waiters;
  @synchronized (self) {
    if (keys) {
      _fetchedKeys = keys;
      _fetchedAt = [NSDate date];
    }
    waiters = [_waiters copy];
    [_waiters removeAllObjects];
    _fetching = NO;
  }
  if (failure) NSLog(@"HSJWTAuthenticator: %@", failure);
  NSError *error = failure ? HSError(503, failure) : nil;
  for (void (^waiter)(NSArray *, NSError *) in waiters) waiter(keys, error);
}

@end

#pragma mark - Introspection

static NSString *HSFormEncoded(NSString *text)
{
  NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
  [allowed addCharactersInString:@"-._~"];
  return [text stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

@implementation HSTokenIntrospectionAuthenticator {
  NSString *_clientID;
  NSString *_clientSecret;
  // The token's SHA-256 -> @[ until, principal claims or NSNull ].
  NSMutableDictionary<NSData *, NSArray *> *_answers;
}

- (instancetype)initWithEndpoint:(NSURL *)endpoint clientID:(NSString *)clientID clientSecret:(NSString *)clientSecret
{
  self = [super init];
  if (!self) return nil;
  _endpoint = [endpoint copy];
  _clientID = [clientID copy];
  _clientSecret = [clientSecret copy];
  _cacheLifetime = 60;
  _fetcher = HSDefaultFetcher();
  _answers = [NSMutableDictionary dictionary];
  return self;
}

- (NSString *)challengeForRequest:(HSRequest *)request
{
  return HSBearerChallenge(request);
}

- (NSDictionary *)authorizationDescription
{
  return @{ @"@type": @"Org.OData.Authorization.V1.Http", @"Name": @"Bearer", @"Scheme": @"bearer",
            @"Description": @"An access token from the identity provider, as Authorization: Bearer" };
}

- (void)authenticateRequest:(HSRequest *)request reply:(HSAuthenticationReply *)reply
{
  NSString *token = HSBearerToken(request);
  if (!token) {
    [reply finishWithPrincipal:nil];
    return;
  }
  NSData *digest = HSSHA256([token dataUsingEncoding:NSUTF8StringEncoding]);
  NSArray *kept;
  @synchronized (self) {
    kept = _answers[digest];
    if (kept && [kept[0] timeIntervalSinceNow] <= 0) {
      [_answers removeObjectForKey:digest];
      kept = nil;
    }
  }
  if (kept) {
    [self answer:request reply:reply claims:kept[1] == [NSNull null] ? nil : kept[1]];
    return;
  }

  // RFC 7662 section 2.1, with the client's credentials as RFC 6749
  // section 2.3.1 has them.
  NSMutableURLRequest *post = [NSMutableURLRequest requestWithURL:self.endpoint];
  post.HTTPMethod = @"POST";
  [post setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
  [post setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  NSString *credentials = [NSString stringWithFormat:@"%@:%@", HSFormEncoded(_clientID), HSFormEncoded(_clientSecret)];
  NSString *basic = [[credentials dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
  [post setValue:[@"Basic " stringByAppendingString:basic] forHTTPHeaderField:@"Authorization"];
  post.HTTPBody = [[NSString stringWithFormat:@"token=%@&token_type_hint=access_token", HSFormEncoded(token)] dataUsingEncoding:NSUTF8StringEncoding];
  [HSJSONFetch request:post fetcher:self.fetcher then:^(NSDictionary *json) {
    if (!json) {
      NSLog(@"HSTokenIntrospectionAuthenticator: %@ did not answer", self.endpoint);
      [reply failWithError:HSError(503, @"The identity provider could not be asked about the token")];
      return;
    }
    NSDictionary *claims = [json[@"active"] isEqual:@YES] ? json : nil;
    [self keep:claims for:digest];
    [self answer:request reply:reply claims:claims];
  }];
}

- (void)keep:(NSDictionary *)claims for:(NSData *)digest
{
  if (self.cacheLifetime <= 0) return;
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:self.cacheLifetime];
  id exp = claims[@"exp"];
  if ([exp isKindOfClass:[NSNumber class]]) {
    NSDate *expiry = [NSDate dateWithTimeIntervalSince1970:[exp doubleValue]];
    until = [until earlierDate:expiry];
  }
  @synchronized (self) {
    // Bounded: past a limit, what has lapsed goes, and failing that all.
    if (_answers.count >= 10000) {
      for (NSData *key in _answers.allKeys) {
        if ([_answers[key][0] timeIntervalSinceNow] <= 0) [_answers removeObjectForKey:key];
      }
      if (_answers.count >= 10000) [_answers removeAllObjects];
    }
    _answers[digest] = @[ until, claims ?: [NSNull null] ];
  }
}

- (void)answer:(HSRequest *)request reply:(HSAuthenticationReply *)reply claims:(NSDictionary *)claims
{
  if (!claims) {
    HSRefuse(request, reply, 401, @"invalid_token", @"The token is not active");
    return;
  }
  NSString *problem = HSClaimsProblem(claims, self.issuer, self.audience, 0, NO);
  if (problem) {
    HSRefuse(request, reply, 401, @"invalid_token", problem);
    return;
  }
  id subject = claims[@"sub"] ?: claims[@"username"];
  HSPrincipal *principal = HSCheckedPrincipal(request, reply, claims, subject, self.requiredScopes);
  if (principal) [reply finishWithPrincipal:principal];
}

@end
