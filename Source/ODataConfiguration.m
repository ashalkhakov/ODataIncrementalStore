// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataConfiguration.h"

NSString * const ODataIncrementalStoreAccessTokenOption = @"ODataIncrementalStoreAccessToken";
NSString * const ODataIncrementalStoreUsernameOption = @"ODataIncrementalStoreUsername";
NSString * const ODataIncrementalStorePasswordOption = @"ODataIncrementalStorePassword";
NSString * const ODataIncrementalStoreTimeoutOption = @"ODataIncrementalStoreTimeout";
NSString * const ODataIncrementalStorePostOnObtainPermanentIDsOption = @"ODataIncrementalStorePostOnObtainPermanentIDs";
NSString * const ODataIncrementalStoreTransportOption = @"ODataIncrementalStoreTransport";
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
  _userAgent = @"ODataIncrementalStore/1.0 (LGPL-2.1; libobjc2)";
  return self;
}

- (void)applyToRequest:(NSMutableURLRequest *)request
{
  [request setValue:@"application/json;odata.metadata=minimal" forHTTPHeaderField:@"Accept"];
  [request setValue:@"application/json;odata.metadata=minimal" forHTTPHeaderField:@"Content-Type"];
  [request setValue:@"4.0" forHTTPHeaderField:@"OData-Version"];
  [request setValue:@"4.0" forHTTPHeaderField:@"OData-MaxVersion"];
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
