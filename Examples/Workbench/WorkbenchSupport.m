// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WorkbenchSupport.h"

id WBCellValue(id value)
{
  if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]]) {
    NSMutableArray *parts = [NSMutableArray array];
    for (id item in value) [parts addObject:[WBCellValue(item) description]];
    return [NSString stringWithFormat:@"[%@]", [parts componentsJoinedByString:@", "]];
  }
  if ([value isKindOfClass:[NSDictionary class]]) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in [[value allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
      [parts addObject:[NSString stringWithFormat:@"%@: %@", key, WBCellValue(value[key])]];
    }
    return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
  }
  if (value == [NSNull null]) return @"null";
  if ([value isKindOfClass:[NSDate class]]) {
    // A day as a day; a moment in UTC.
    static NSDateFormatter *day, *moment;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      day = [[NSDateFormatter alloc] init];
      day.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
      day.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
      day.dateFormat = @"yyyy-MM-dd";
      moment = [[NSDateFormatter alloc] init];
      moment.locale = day.locale;
      moment.timeZone = day.timeZone;
      moment.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    });
    NSTimeInterval seconds = [value timeIntervalSince1970];
    return fmod(seconds, 86400) == 0 ? [day stringFromDate:value] : [moment stringFromDate:value];
  }
  return value;
}

BOOL WBIsKey(NSAttributeDescription *attribute)
{
  id flag = attribute.userInfo[ODataUserInfoKey];
  return [flag isEqual:@"YES"] || [flag isEqual:@YES];
}

NSDate *WBDate(NSString *text)
{
  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
  formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  for (NSString *format in @[ @"yyyy-MM-dd", @"yyyy-MM-dd'T'HH:mm:ss'Z'", @"yyyy-MM-dd'T'HH:mm:ssZZZZZ" ]) {
    formatter.dateFormat = format;
    NSDate *date = [formatter dateFromString:trimmed];
    if (date) return date;
  }
  return nil;
}

NSError *WBError(NSInteger code, NSString *text)
{
  return [NSError errorWithDomain:@"Workbench" code:code userInfo:@{ NSLocalizedDescriptionKey: text ?: @"failed" }];
}

NSArray<NSString *> *WBColumnNames(NSEntityDescription *entity, BOOL builtIn)
{
  if (builtIn) {
    NSString *name = entity.name;
    if ([name isEqualToString:@"Product"]) return @[ @"id", @"name", @"unitPrice", @"discontinued", @"version" ];
    if ([name isEqualToString:@"Budget"]) return @[ @"id", @"category", @"from", @"to", @"amount" ];
    if ([name isEqualToString:@"Picture"]) return @[ @"id", @"name" ];
    if ([name isEqualToString:@"Supplier"]) return @[ @"id", @"companyName", @"city", @"country" ];
    if ([name isEqualToString:@"Location"]) return @[ @"id", @"name", @"city", @"country" ];
    if ([name isEqualToString:@"Stock"]) return @[ @"id", @"quantity" ];
    if ([name isEqualToString:@"Category"]) return @[ @"id", @"name" ];
  }
  NSMutableArray *keys = [NSMutableArray array], *names = [NSMutableArray array], *plain = [NSMutableArray array];
  NSMutableArray *references = [NSMutableArray array], *rest = [NSMutableArray array];
  for (NSString *name in [entity.attributesByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSAttributeDescription *attr = entity.attributesByName[name];
    if (WBIsKey(attr)) [keys addObject:name];
    else if (attr.attributeType == NSTransformableAttributeType || attr.attributeType == NSBinaryDataAttributeType) [rest addObject:name];
    else if ([name isEqualToString:@"name"] || [name hasSuffix:@"Name"]) [names addObject:name];
    else if ([name hasSuffix:@"ID"] || [name hasSuffix:@"Id"]) [references addObject:name];  // most likely a foreign key
    else [plain addObject:name];
  }
  NSMutableArray *all = [keys mutableCopy];
  for (NSArray *group in @[ names, plain, references, rest ]) [all addObjectsFromArray:group];
  return all.count > 7 ? [all subarrayWithRange:NSMakeRange(0, 7)] : all;
}

NSString *WBTitleOf(NSManagedObject *object, BOOL builtIn)
{
  NSDictionary *attrs = object.entity.attributesByName;
  NSMutableArray *candidates = [@[ @"name", @"title", @"userName", @"productName", @"companyName", @"categoryName" ] mutableCopy];
  for (NSString *attr in [attrs.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if ([attr hasSuffix:@"Name"] && [attrs[attr] attributeType] == NSStringAttributeType) [candidates addObject:attr];
  }
  @try {
    for (NSString *candidate in candidates) {
      if (!attrs[candidate]) continue;
      id value = [object valueForKey:candidate];
      if (value) return [value description];
    }
    for (NSString *key in WBColumnNames(object.entity, builtIn)) {
      id value = [object valueForKey:key];
      if (value) return [NSString stringWithFormat:@"%@ = %@", key, value];
    }
  } @catch (NSException *ex) {
    return ex.reason;
  }
  return object.objectID.URIRepresentation.lastPathComponent;
}

NSString *WBAddressOf(NSManagedObject *object)
{
  NSPersistentStore *store = object.objectID.persistentStore;
  if (object.objectID.isTemporaryID || ![store isKindOfClass:[NSIncrementalStore class]]) return @"(not saved)";
  id reference = [(NSIncrementalStore *)store referenceObjectForObjectID:object.objectID];
  return [ODataResourceIdentifier identifierFromReference:reference].path ?: [reference description];
}

NSString *WBDescribe(NSManagedObject *object)
{
  NSMutableString *text = [NSMutableString stringWithFormat:@"%@ %@\n", object.entity.name, WBAddressOf(object)];
  NSArray *attrs = [[object.entity.attributesByName allKeys] sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *name in attrs) {
    @try {
      [text appendFormat:@"  %@ = %@\n", name, WBCellValue([object valueForKey:name]) ?: @"nil"];
    } @catch (NSException *ex) {
      [text appendFormat:@"  %@ fault failed (%@)\n", name, ex.reason];
    }
  }
  return text;
}

void WBSend(id target, SEL action, id argument)
{
  if (!target || !action || ![target respondsToSelector:action]) return;
  void (*send)(id, SEL, id) = (void (*)(id, SEL, id))[target methodForSelector:action];
  send(target, action, argument);
}
