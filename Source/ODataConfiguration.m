// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataConfiguration.h"

NSString * const ODataIncrementalStoreAccessTokenOption = @"ODataIncrementalStoreAccessToken";
NSString * const ODataIncrementalStoreUsernameOption = @"ODataIncrementalStoreUsername";
NSString * const ODataIncrementalStorePasswordOption = @"ODataIncrementalStorePassword";
NSString * const ODataIncrementalStoreTimeoutOption = @"ODataIncrementalStoreTimeout";
NSString * const ODataIncrementalStorePostOnObtainPermanentIDsOption = @"ODataIncrementalStorePostOnObtainPermanentIDs";
NSString * const ODataIncrementalStoreTransportOption = @"ODataIncrementalStoreTransport";
NSString * const ODataIncrementalStoreKeyAsSegmentOption = @"ODataIncrementalStoreKeyAsSegment";
NSString * const ODataIncrementalStoreMaxVersionOption = @"ODataIncrementalStoreMaxVersion";
NSString * const ODataIncrementalStoreIEEE754CompatibleOption = @"ODataIncrementalStoreIEEE754Compatible";
NSString * const ODataIncrementalStoreBatchSavesOption = @"ODataIncrementalStoreBatchSaves";
NSString * const ODataIncrementalStoreRequireMatchingModelOption = @"ODataIncrementalStoreRequireMatchingModel";
NSString * const ODataIncrementalStoreType = @"ODataIncrementalStore";

@implementation ODataConfiguration

- (instancetype)initWithURL:(NSURL *)url options:(NSDictionary *)options
{
  self = [super init];
  if (!self) return nil;
  NSString *abs = url.absoluteString ?: @"";
  if (abs.length && ![abs hasSuffix:@"/"]) {
    abs = [abs stringByAppendingString:@"/"];
  }
  _serviceRoot = [NSURL URLWithString:abs] ?: url;
  _accessToken = [options[ODataIncrementalStoreAccessTokenOption] copy];
  _username = [options[ODataIncrementalStoreUsernameOption] copy];
  _password = [options[ODataIncrementalStorePasswordOption] copy];
  id timeout = options[ODataIncrementalStoreTimeoutOption];
  _timeout = timeout ? [timeout doubleValue] : 60.0;
  _naming = ODataPropertyNamingPascalCase;
  id post = options[ODataIncrementalStorePostOnObtainPermanentIDsOption];
  _postOnObtainPermanentIDs = post ? [post boolValue] : YES;
  id ieee = options[ODataIncrementalStoreIEEE754CompatibleOption];
  _IEEE754Compatible = ieee ? [ieee boolValue] : YES;
  id batch = options[ODataIncrementalStoreBatchSavesOption];
  _batchSaves = batch ? [batch boolValue] : YES;
  id maxVersion = options[ODataIncrementalStoreMaxVersionOption];
  _maxVersion = [maxVersion isKindOfClass:[NSString class]] ? [maxVersion copy] : @"4.01";
  _version = @"4.0";
  _userAgent = @"ODataIncrementalStore/1.0 (LGPL-2.1; libobjc2)";
  return self;
}

- (NSString *)versionForService:(NSString *)serviceVersion
{
  BOOL service401 = [serviceVersion compare:@"4.01" options:NSNumericSearch] != NSOrderedAscending;
  BOOL client401 = [self.maxVersion compare:@"4.01" options:NSNumericSearch] != NSOrderedAscending;
  return service401 && client401 ? @"4.01" : @"4.0";
}

- (void)applyToRequest:(NSMutableURLRequest *)request
{
  // JSON is the default, not a rule: $metadata asks for XML and $count for
  // text, and a service answers 406 or 415 when Accept rules those out.
  // IEEE754Compatible=true: Int64 and Decimal as strings, both ways
  // (JSON Format section 3.2), so no digit goes through a double.
  NSString *json = self.IEEE754Compatible ? @"application/json;odata.metadata=minimal;IEEE754Compatible=true"
                                          : @"application/json;odata.metadata=minimal";
  if (![request valueForHTTPHeaderField:@"Accept"]) {
    [request setValue:json forHTTPHeaderField:@"Accept"];
  }
  if (request.HTTPBody.length && ![request valueForHTTPHeaderField:@"Content-Type"]) {
    [request setValue:json forHTTPHeaderField:@"Content-Type"];
  }
  [request setValue:self.version forHTTPHeaderField:@"OData-Version"];
  [request setValue:self.maxVersion forHTTPHeaderField:@"OData-MaxVersion"];
  [request setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];
  request.timeoutInterval = self.timeout;
  if (self.accessToken.length) {
    [request setValue:[NSString stringWithFormat:@"Bearer %@", self.accessToken] forHTTPHeaderField:@"Authorization"];
  } else if (self.username) {
    NSString *pair = [NSString stringWithFormat:@"%@:%@", self.username, self.password ?: @""];
    NSData *data = [pair dataUsingEncoding:NSUTF8StringEncoding];
    NSString *b64 = [data base64EncodedStringWithOptions:0];
    [request setValue:[NSString stringWithFormat:@"Basic %@", b64] forHTTPHeaderField:@"Authorization"];
  }
}

@end
