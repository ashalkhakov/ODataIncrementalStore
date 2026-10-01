// ODataIncrementalStore — who is asking a service.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A service signs no one in: it is a relying party. An identity provider
// (OIDC, with passwords, passkeys or FIDO2 keys as it likes) signs the user
// in, and something the service trusts tells it who that is. Its
// authenticator hears it for each request, and the request carries the
// principal it found to every handler and operation (request.principal),
// so -predicateForVisibleObjectsInRequest: can scope rows to the caller.
//
// ODataTrustedHeaderAuthenticator takes the caller from headers that a
// reverse proxy sets once it has checked them with the provider
// (oauth2-proxy, Authelia, Caddy's forward_auth, nginx's auth_request).
// Anyone who can reach the service can send those headers too, so it is
// for a service that only the proxy can reach (ODataHTTPServer listens on
// loopback by default), and the proxy has to replace the headers, never
// pass on a client's; a secret header the proxy adds makes sure of the
// first.
//
// Without such a proxy, a client sends the access token the provider gave
// it (Authorization: Bearer ...), and the service checks it: by its
// signature, with the provider's published keys (ODataJWTAuthenticator,
// for a token that is a JWT), or by asking the provider
// (ODataTokenIntrospectionAuthenticator, for any token). Anything else is
// an ODataAuthenticator of the application's own.
//
// A $batch is authenticated once, as a whole: its requests are the batch's
// principal's, whatever headers they carry inside it.

#pragma once
#import "ODataService.h"

NS_ASSUME_NONNULL_BEGIN

// Who a request is from: the provider's subject (OIDC's sub, a user name),
// and what else is known of them.
@interface ODataPrincipal : NSObject
- (instancetype)initWithSubject:(NSString *)subject claims:(nullable NSDictionary<NSString *, id> *)claims NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSString *subject;
// email, preferred_username, groups (an array), ... as the authenticator
// found them.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *claims;
// What the caller may do, as OAuth has it: the scope claim (text, space
// separated) or scp (an array). Empty when there is neither.
@property (nonatomic, readonly, copy) NSSet<NSString *> *scopes;
@end

@protocol ODataAuthenticator <NSObject>
// Who sent the request. Finish the reply with an ODataPrincipal, or with
// nil when it names no one (answered 401, unless the service allows
// anonymous requests); fail it with an ODataServiceError to refuse it (401,
// or 403). It may defer and answer later, as a handler does, within the
// service's replyTimeout.
- (void)authenticateRequest:(ODataRequest *)request reply:(ODataReply *)reply;
@optional
// The WWW-Authenticate header of a 401. Default: Bearer.
- (NSString *)challengeForRequest:(ODataRequest *)request;
// How a client signs in, for $metadata: an Authorization vocabulary record
// as JSON CSDL has it ({"@type": "Org.OData.Authorization.V1.OpenIDConnect",
// "Name": ..., "IssuerUrl": ...}), written into Authorizations, and with
// requiredScopes (when the authenticator has them) into SecuritySchemes.
- (nullable NSDictionary<NSString *, id> *)authorizationDescription;
@end

// An authenticator asked about a request no service is answering (yet), for
// a host that asks once for all its routes (ODataServer's authentication
// stage), and what it answered: who is asking, or why they are refused.
// The target is sent the action, with this, once, on any thread: now, or
// when a deferred authenticator answers (within timeout; 0: no limit).
@interface ODataAuthentication : NSObject
+ (void)authenticateURLRequest:(NSURLRequest *)request with:(id<ODataAuthenticator>)authenticator
                       timeout:(NSTimeInterval)timeout target:(id)target action:(SEL)action;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) NSURLRequest *URLRequest;
// nil: no one (whether that is let in is the host's to say).
@property (nonatomic, readonly, strong, nullable) ODataPrincipal *principal;
// A refusal (ODataServiceError, 401 or 403), and for a 401 the
// WWW-Authenticate challenge the authenticator gives with it.
@property (nonatomic, readonly, strong, nullable) NSError *error;
@property (nonatomic, readonly, copy, nullable) NSString *challenge;
@end

@interface ODataTrustedHeaderAuthenticator : NSObject <ODataAuthenticator>
// The caller's subject from this header (X-Forwarded-User, Remote-User).
- (instancetype)initWithSubjectHeader:(NSString *)header NS_DESIGNATED_INITIALIZER;
// X-Forwarded-User, as oauth2-proxy sends it.
- (instancetype)init;
@property (nonatomic, readonly, copy) NSString *subjectHeader;
// Claims from other headers, claim name to header. Default: email from
// X-Forwarded-Email, preferred_username from
// X-Forwarded-Preferred-Username, groups from X-Forwarded-Groups.
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *claimHeaders;
// The claims whose header is a comma-separated list. Default: groups.
@property (nonatomic, copy) NSSet<NSString *> *listClaims;
// A header the proxy adds with a secret only it and the service know: a
// request without it did not come through the proxy, and is answered 401.
// nil (the default): none.
@property (nonatomic, copy, nullable) NSString *secretHeader;
@property (nonatomic, copy, nullable) NSString *secret;
@end

// An access token that is a JWT (RFC 9068), checked as RFC 8725 has it: its
// algorithm one of `algorithms` (never none, never HMAC, whatever the token
// says), its signature by one of the issuer's keys (never one the token
// names or carries), and then its claims: iss the issuer, aud including the
// audience, exp not past and nbf not ahead (within `leeway`), a sub (the
// principal's subject; every claim goes into its claims), and the scopes
// `requiredScopes` asks for (403 otherwise). A token typed other than JWT
// or at+jwt (an ID token, say) is refused. A request without a token names
// no one; one with a token that fails is answered 401 with
// WWW-Authenticate: Bearer error="invalid_token".
//
// The keys: `keySet` when given, or fetched from keySetURL, or from the
// jwks_uri of the issuer's discovery document
// (issuer/.well-known/openid-configuration, whose issuer must be the
// issuer), and fetched again after keySetLifetime, or when a token names a
// key they lack (a rotation), at most once a keySetRefetchInterval.
// Requests wait for a fetch (503 if it fails).
@interface ODataJWTAuthenticator : NSObject <ODataAuthenticator>
// issuer: exactly as the tokens' iss has it. audience: this service's
// name at the provider; nil takes any audience, which only suits a
// provider that issues tokens for nothing else.
- (instancetype)initWithIssuer:(NSString *)issuer audience:(nullable NSString *)audience NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSString *issuer;
@property (nonatomic, readonly, copy, nullable) NSString *audience;
@property (nonatomic, copy, nullable) NSURL *keySetURL;
// A JWK Set ({"keys": [...]}), used as it is and never fetched.
@property (nonatomic, copy, nullable) NSDictionary *keySet;
// Default: RS256, RS384, RS512, PS256, PS384, PS512, ES256, ES384, ES512.
@property (nonatomic, copy) NSSet<NSString *> *algorithms;
// Scopes every token needs, from its scope (space-separated) or scp.
@property (nonatomic, copy, nullable) NSSet<NSString *> *requiredScopes;
// Clock skew allowed for exp and nbf. Default: 60 seconds.
@property (nonatomic) NSTimeInterval leeway;
// How long fetched keys are used before they are fetched again. Default:
// an hour.
@property (nonatomic) NSTimeInterval keySetLifetime;
// How soon keys are fetched again for a token whose key they lack, so
// tokens with made-up key IDs cannot make the service fetch all the time.
// Default: 60 seconds.
@property (nonatomic) NSTimeInterval keySetRefetchInterval;
// How it fetches. Default: ODataDefaultTransport().
@property (nonatomic, strong) id<ODataTransport> transport;
@end

// Any access token, opaque or not, checked by asking the provider (RFC
// 7662): it is posted to the introspection endpoint with the service's own
// client credentials, and the provider says whether it is active, and
// whose. The answer is kept for cacheLifetime (never past the token's exp),
// by the token's SHA-256, so a client's next request does not ask again; a
// token revoked in that time is taken until then. The principal is sub (or
// username), with every member of the answer as its claims; iss, aud and
// scopes are checked as for a JWT when set. An endpoint that does not
// answer is a 503.
@interface ODataTokenIntrospectionAuthenticator : NSObject <ODataAuthenticator>
- (instancetype)initWithEndpoint:(NSURL *)endpoint clientID:(NSString *)clientID clientSecret:(NSString *)clientSecret NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSURL *endpoint;
@property (nonatomic, copy, nullable) NSString *issuer;
@property (nonatomic, copy, nullable) NSString *audience;
@property (nonatomic, copy, nullable) NSSet<NSString *> *requiredScopes;
// Default: 60 seconds. 0: every request asks.
@property (nonatomic) NSTimeInterval cacheLifetime;
@property (nonatomic, strong) id<ODataTransport> transport;
@end

NS_ASSUME_NONNULL_END
