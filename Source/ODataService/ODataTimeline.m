// ODataService — application time: timeline entity sets.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Periods are handled closed-open, with nil for no end: a closed-closed
// end (the last day) is one day more on the way in, one day less on the
// way out. The actions follow OData-Temporal section 4.3.2, as SQL's
// UPDATE and DELETE ... FOR PORTION OF do.

#import "ODataTimeline.h"
#import "ODataError.h"
#import "ODataValue.h"

static NSString * const OISTemporal = @"Org.OData.Temporal.V1";
static const NSTimeInterval OISDay = 86400;

@implementation OISTimeslice
@end

// 9999-12-31, midnight UTC: what an end that must be given is for no end.
static NSDate *OISLastDay(void)
{
  static NSDate *last;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSDateComponents *parts = [[NSDateComponents alloc] init];
    parts.year = 9999;
    parts.month = 12;
    parts.day = 31;
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    last = [calendar dateFromComponents:parts];
  });
  return last;
}

// a < b, with nil the end of time.
static BOOL OISBefore(NSDate *a, NSDate *b)
{
  if (!a) return NO;
  if (!b) return YES;
  return [a compare:b] == NSOrderedAscending;
}

@interface OISTimeline ()
@property (nonatomic, strong) NSEntityDescription *entity;
@property (nonatomic, strong) ODataPropertyMapper *mapper;
@property (nonatomic, strong, readwrite) NSAttributeDescription *startAttribute;
@property (nonatomic, strong, readwrite) NSAttributeDescription *endAttribute;
@property (nonatomic, copy, readwrite) NSArray<NSAttributeDescription *> *objectKey;
@property (nonatomic, readwrite) BOOL isDate;
@property (nonatomic, readwrite) BOOL closedClosed;
@end

@implementation OISTimeline

+ (instancetype)timelineOfEntity:(NSEntityDescription *)entity mapper:(ODataPropertyMapper *)mapper
{
  // The root's: a derived type's slices are the set's.
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  NSDictionary *userInfo = root.userInfo;
  NSAttributeDescription *start = root.attributesByName[userInfo[ODataUserInfoPeriodStart]];
  NSAttributeDescription *end = root.attributesByName[userInfo[ODataUserInfoPeriodEnd]];
  if (start.attributeType != NSDateAttributeType || end.attributeType != NSDateAttributeType) return nil;
  NSMutableArray *objectKey = [NSMutableArray array];
  for (NSString *name in [userInfo[ODataUserInfoObjectKey] componentsSeparatedByString:@","]) {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!trimmed.length) continue;
    NSAttributeDescription *attribute = root.attributesByName[trimmed];
    if (!attribute) return nil;
    [objectKey addObject:attribute];
  }
  OISTimeline *timeline = [[self alloc] init];
  timeline.entity = root;
  timeline.mapper = mapper;
  timeline.startAttribute = start;
  timeline.endAttribute = end;
  timeline.objectKey = objectKey;
  timeline.isDate = [[mapper.values typeNameOfAttribute:start] isEqualToString:@"Edm.Date"];
  id closed = userInfo[ODataUserInfoClosedClosedPeriods];
  timeline.closedClosed = timeline.isDate && ([closed isEqual:@"YES"] || [closed isEqual:@YES]);
  return timeline;
}

- (NSDictionary *)applicationTimeSupport
{
  NSDictionary *unit = self.isDate
      ? @{ @"@type": [OISTemporal stringByAppendingString:@".UnitOfTimeDate"], @"ClosedClosedPeriods": @(self.closedClosed) }
      : @{ @"@type": [OISTemporal stringByAppendingString:@".UnitOfTimeDateTimeOffset"], @"Precision": @0 };
  NSMutableArray *objectKey = [NSMutableArray array];
  for (NSAttributeDescription *attribute in self.objectKey) [objectKey addObject:@{ @"$PropertyPath": [self.mapper propertyForAttribute:attribute] }];
  NSMutableArray *actions = [NSMutableArray array];
  for (NSString *action in @[ @"Update", @"Upsert", @"Delete" ]) [actions addObject:[NSString stringWithFormat:@"%@.%@", OISTemporal, action]];
  return @{ @"UnitOfTime": unit,
            @"Timeline": @{ @"@type": [OISTemporal stringByAppendingString:@".TimelineVisible"],
                            @"PeriodStart": @{ @"$PropertyPath": [self.mapper propertyForAttribute:self.startAttribute] },
                            @"PeriodEnd": @{ @"$PropertyPath": [self.mapper propertyForAttribute:self.endAttribute] },
                            @"ObjectKey": objectKey },
            @"SupportedActions": actions };
}

- (NSString *)filterFrom:(NSString *)from to:(NSString *)to inclusive:(BOOL)inclusive
{
  NSString *start = [self.mapper propertyForAttribute:self.startAttribute];
  NSString *end = [self.mapper propertyForAttribute:self.endAttribute];
  // The slice ends after the interval begins (or has no end) ...
  NSString *after = [NSString stringWithFormat:@"%@ %@ %@", end, self.closedClosed ? @"ge" : @"gt", from];
  if (self.endAttribute.isOptional) after = [NSString stringWithFormat:@"(%@ or %@ eq null)", after, end];
  if (!to) return after;
  // ... and begins before it ends.
  return [NSString stringWithFormat:@"%@ %@ %@ and %@", start, inclusive ? @"le" : @"lt", to, after];
}

#pragma mark Periods

- (NSDate *)startOf:(id)slice
{
  return [slice valueForKey:self.startAttribute.name];
}

- (NSDate *)endOf:(id)slice
{
  return [self endFromStored:[slice valueForKey:self.endAttribute.name]];
}

- (NSDate *)endFromStored:(id)stored
{
  if (![stored isKindOfClass:[NSDate class]] || [stored compare:OISLastDay()] != NSOrderedAscending) return nil;
  return self.closedClosed ? [stored dateByAddingTimeInterval:OISDay] : stored;
}

- (id)storedEnd:(NSDate *)end
{
  if (!end) return self.endAttribute.isOptional ? [NSNull null] : OISLastDay();
  return self.closedClosed ? [end dateByAddingTimeInterval:-OISDay] : end;
}

// A slice's period as values to write.
- (NSMutableDictionary *)periodStart:(NSDate *)start end:(NSDate *)end
{
  return [@{ self.startAttribute.name: start, self.endAttribute.name: [self storedEnd:end] } mutableCopy];
}

// Another slice like this one, for another period: its values but its key.
- (NSMutableDictionary *)valuesOf:(NSManagedObject *)slice
{
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  NSSet *keys = [NSSet setWithArray:[[self.mapper keyAttributesForEntity:self.entity] valueForKey:@"name"]];
  for (NSString *name in slice.entity.attributesByName) {
    NSAttributeDescription *attribute = slice.entity.attributesByName[name];
    Class derived = NSClassFromString(@"NSDerivedAttributeDescription");
    if ([keys containsObject:name] || attribute.isTransient || (derived && [attribute isKindOfClass:derived])) continue;
    id value = [slice valueForKey:name];
    if (value) values[name] = value;
  }
  for (NSString *name in slice.entity.relationshipsByName) {
    NSRelationshipDescription *relationship = slice.entity.relationshipsByName[name];
    if (relationship.isToMany) continue;
    id value = [slice valueForKey:name];
    if (value) values[name] = value;
  }
  return values;
}

- (NSManagedObject *)copyOf:(NSManagedObject *)slice start:(NSDate *)start end:(NSDate *)end
                     writer:(id<OISTimelineWriting>)writer error:(NSError **)error
{
  NSMutableDictionary *values = [self valuesOf:slice];
  values[self.startAttribute.name] = start;
  id stored = [self storedEnd:end];
  if (stored == [NSNull null]) [values removeObjectForKey:self.endAttribute.name];
  else values[self.endAttribute.name] = stored;
  return [writer timelineInsertValues:values entity:slice.entity error:error];
}

#pragma mark Actions

- (BOOL)slice:(NSManagedObject *)slice hasObjectKeyOf:(NSDictionary *)delta
{
  for (NSAttributeDescription *attribute in self.objectKey) {
    id wanted = delta[attribute.name];
    if (wanted && ![[slice valueForKey:attribute.name] isEqual:wanted]) return NO;
  }
  return YES;
}

- (NSArray *)objectKeyOf:(id)slice
{
  NSMutableArray *key = [NSMutableArray array];
  for (NSAttributeDescription *attribute in self.objectKey) [key addObject:[slice valueForKey:attribute.name] ?: [NSNull null]];
  return key;
}

- (NSArray *)perform:(NSString *)action deltas:(NSArray *)deltas candidates:(NSArray *)candidates
              writer:(id<OISTimelineWriting>)writer error:(NSError **)error
{
  BOOL upsert = [action isEqualToString:@"Upsert"];
  BOOL delete = [action isEqualToString:@"Delete"];
  NSMutableArray *slices = [candidates mutableCopy];
  NSMutableArray *results = [NSMutableArray array];
  NSSet *keys = [NSSet setWithArray:[[self.mapper keyAttributesForEntity:self.entity] valueForKey:@"name"]];
  for (NSDictionary *delta in deltas) {
    NSDate *from = [delta[self.startAttribute.name] isKindOfClass:[NSDate class]] ? delta[self.startAttribute.name] : nil;
    NSDate *to = [self endFromStored:delta[self.endAttribute.name]];
    if (!from) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"A delta time slice has its %@", [self.mapper propertyForAttribute:self.startAttribute]]);
      return nil;
    }
    if (!OISBefore(from, to)) {
      if (error) *error = ODataServiceError(400, @"A delta time slice's period ends after it starts");
      return nil;
    }
    // What changes: the rest of the delta, not its period or keys.
    NSMutableDictionary *changes = [delta mutableCopy];
    [changes removeObjectsForKeys:@[ self.startAttribute.name, self.endAttribute.name ]];
    [changes removeObjectsForKeys:keys.allObjects];

    // The slices of its objects whose periods overlap its own, in order.
    NSMutableArray *selected = [NSMutableArray array];
    for (NSManagedObject *slice in slices) {
      if (![self slice:slice hasObjectKeyOf:delta]) continue;
      if (OISBefore([self startOf:slice], to) && OISBefore(from, [self endOf:slice])) [selected addObject:slice];
    }
    [selected sortUsingComparator:^NSComparisonResult(NSManagedObject *a, NSManagedObject *b) {
      return [[self startOf:a] compare:[self startOf:b]];
    }];

    if (delete) {
      for (NSManagedObject *slice in selected) {
        NSDate *start = [self startOf:slice], *end = [self endOf:slice];
        NSMutableDictionary *taken = [self valuesOf:slice];
        NSDate *takenStart = OISBefore(start, from) ? from : start;
        NSDate *takenEnd = OISBefore(to, end) ? to : end;
        taken[self.startAttribute.name] = takenStart;
        id stored = [self storedEnd:takenEnd];
        if (stored == [NSNull null]) [taken removeObjectForKey:self.endAttribute.name];
        else taken[self.endAttribute.name] = stored;
        OISTimeslice *gone = [[OISTimeslice alloc] init];
        gone.values = taken;
        [results addObject:gone];
        BOOL keepsBefore = OISBefore(start, from), keepsAfter = OISBefore(to, end);
        BOOL written;
        if (keepsBefore && keepsAfter) {
          NSManagedObject *after = [self copyOf:slice start:to end:end writer:writer error:error];
          if (after) [slices addObject:after];
          written = after && [writer timelineUpdate:slice values:[self periodStart:start end:from] error:error];
        } else if (keepsBefore) {
          written = [writer timelineUpdate:slice values:[self periodStart:start end:from] error:error];
        } else if (keepsAfter) {
          written = [writer timelineUpdate:slice values:[self periodStart:to end:end] error:error];
        } else {
          written = [writer timelineDelete:slice error:error];
          [slices removeObject:slice];
        }
        if (!written) return nil;
      }
      continue;
    }

    NSMutableArray *changed = [NSMutableArray array];
    for (NSManagedObject *slice in selected) {
      NSDate *start = [self startOf:slice], *end = [self endOf:slice];
      if (OISBefore(start, from)) {
        NSManagedObject *before = [self copyOf:slice start:start end:from writer:writer error:error];
        if (!before) return nil;
        [slices addObject:before];
        [changed addObject:before];
        start = from;
      }
      if (OISBefore(to, end)) {
        NSManagedObject *after = [self copyOf:slice start:to end:end writer:writer error:error];
        if (!after) return nil;
        [slices addObject:after];
        [changed addObject:after];
        end = to;
      }
      NSMutableDictionary *values = [self periodStart:start end:end];
      [values addEntriesFromDictionary:changes];
      if (![writer timelineUpdate:slice values:values error:error]) return nil;
      [changed addObject:slice];
    }

    if (upsert) {
      // The gaps in the period, for each object it touched (or, touching
      // none, the one its object key names): filled from the slice just
      // before, where there is one, else from the delta alone.
      NSMutableDictionary *groups = [NSMutableDictionary dictionary];
      for (NSManagedObject *slice in selected) {
        NSArray *key = [self objectKeyOf:slice];
        if (!groups[key]) groups[key] = [NSMutableArray array];
        [groups[key] addObject:slice];
      }
      if (!groups.count) {
        for (NSAttributeDescription *attribute in self.objectKey) {
          if (!delta[attribute.name]) {
            if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"A new time slice needs its %@", [self.mapper propertyForAttribute:attribute]]);
            return nil;
          }
        }
        groups[[self objectKeyOf:delta]] = [NSMutableArray array];
      }
      for (NSArray *key in groups) {
        NSMutableArray *gaps = [NSMutableArray array];
        NSDate *cursor = from;
        for (NSManagedObject *slice in groups[key]) {
          if (OISBefore(cursor, [self startOf:slice])) [gaps addObject:@[ cursor, [self startOf:slice] ]];
          NSDate *end = [self endOf:slice];
          if (!end) {
            cursor = nil;
            break;
          }
          if (OISBefore(cursor, end)) cursor = end;
        }
        if (cursor && OISBefore(cursor, to)) [gaps addObject:to ? @[ cursor, to ] : @[ cursor ]];
        for (NSArray *gap in gaps) {
          NSDate *start = gap[0], *end = gap.count > 1 ? gap[1] : nil;
          NSManagedObject *preceding = nil;
          for (NSManagedObject *slice in slices) {
            if (![[self objectKeyOf:slice] isEqual:key]) continue;
            NSDate *sliceEnd = [self endOf:slice];
            if (sliceEnd && [sliceEnd isEqualToDate:start]) preceding = slice;
          }
          NSMutableDictionary *values = preceding ? [self valuesOf:preceding] : [NSMutableDictionary dictionary];
          for (NSUInteger i = 0; i < self.objectKey.count; i++) {
            if (key[i] != [NSNull null]) values[self.objectKey[i].name] = key[i];
          }
          [values addEntriesFromDictionary:changes];
          values[self.startAttribute.name] = start;
          id stored = [self storedEnd:end];
          if (stored == [NSNull null]) [values removeObjectForKey:self.endAttribute.name];
          else values[self.endAttribute.name] = stored;
          NSManagedObject *made = [writer timelineInsertValues:values entity:self.entity error:error];
          if (!made) return nil;
          [slices addObject:made];
          [changed addObject:made];
        }
      }
    }
    for (NSManagedObject *slice in changed) {
      OISTimeslice *result = [[OISTimeslice alloc] init];
      result.object = slice;
      [results addObject:result];
    }
  }
  // The same slice once, the latest; in order of object and period.
  NSMutableArray *unique = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  for (OISTimeslice *result in results.reverseObjectEnumerator) {
    if (result.object && [seen containsObject:[NSValue valueWithNonretainedObject:result.object]]) continue;
    if (result.object) [seen addObject:[NSValue valueWithNonretainedObject:result.object]];
    [unique insertObject:result atIndex:0];
  }
  [unique sortUsingComparator:^NSComparisonResult(OISTimeslice *a, OISTimeslice *b) {
    NSArray *ka = [self objectKeyOf:a.object ?: a.values], *kb = [self objectKeyOf:b.object ?: b.values];
    if (![ka isEqual:kb]) return [ka.description compare:kb.description];
    return [[self startOf:a.object ?: a.values] compare:[self startOf:b.object ?: b.values]];
  }];
  return unique;
}

@end
