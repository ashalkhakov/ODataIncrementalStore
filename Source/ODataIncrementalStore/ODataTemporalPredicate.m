// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataTemporalPredicate.h"
#import <ODataKit/ODataPropertyMapper.h>

@interface ODataTemporalPredicate ()
@property (nonatomic, copy, nullable) NSDate *at;
@property (nonatomic, copy, nullable) NSDate *from;
@property (nonatomic, copy, nullable) NSDate *to;
@property (nonatomic) BOOL toInclusive;
@end

@implementation ODataTemporalPredicate

+ (instancetype)predicateAt:(NSDate *)date
{
  ODataTemporalPredicate *predicate = [[self alloc] init];
  predicate.at = date;
  return predicate;
}

+ (instancetype)predicateFrom:(NSDate *)from to:(NSDate *)to
{
  ODataTemporalPredicate *predicate = [[self alloc] init];
  predicate.from = from;
  predicate.to = to;
  return predicate;
}

+ (instancetype)predicateFrom:(NSDate *)from toInclusive:(NSDate *)to
{
  ODataTemporalPredicate *predicate = [self predicateFrom:from to:to];
  predicate.toInclusive = YES;
  return predicate;
}

+ (BOOL)supportsSecureCoding
{
  return YES;
}

// Archived as itself: gnustep-base's NSPredicate archives its subclasses
// as NSPredicate, as a class cluster would.
- (Class)classForCoder
{
  return [self class];
}

- (Class)classForKeyedArchiver
{
  return [self class];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
  self = [super init];
  if (!self) return nil;
  _at = [coder decodeObjectOfClass:[NSDate class] forKey:@"ODataAt"];
  _from = [coder decodeObjectOfClass:[NSDate class] forKey:@"ODataFrom"];
  _to = [coder decodeObjectOfClass:[NSDate class] forKey:@"ODataTo"];
  _toInclusive = [coder decodeBoolForKey:@"ODataToInclusive"];
  return _at || _from ? self : nil;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
  if (self.at) [coder encodeObject:self.at forKey:@"ODataAt"];
  if (self.from) [coder encodeObject:self.from forKey:@"ODataFrom"];
  if (self.to) [coder encodeObject:self.to forKey:@"ODataTo"];
  [coder encodeBool:self.toInclusive forKey:@"ODataToInclusive"];
}

// Immutable, as predicates are.
- (id)copyWithZone:(NSZone *)zone
{
  return self;
}

- (BOOL)isEqual:(id)other
{
  if (![other isKindOfClass:[ODataTemporalPredicate class]]) return NO;
  ODataTemporalPredicate *p = other;
  return (p.at == self.at || [p.at isEqual:self.at]) && (p.from == self.from || [p.from isEqual:self.from]) &&
         (p.to == self.to || [p.to isEqual:self.to]) && p.toInclusive == self.toInclusive;
}

- (NSUInteger)hash
{
  return self.at.hash ^ self.from.hash ^ self.to.hash;
}

- (NSString *)predicateFormat
{
  if (self.at) return [NSString stringWithFormat:@"ODATA_AT(%@)", self.at];
  return [NSString stringWithFormat:@"ODATA_FROM(%@, %@%@)", self.from, self.toInclusive ? @"inclusive " : @"", self.to ?: @"no end"];
}

- (NSString *)description
{
  return self.predicateFormat;
}

- (BOOL)evaluateWithObject:(id)object
{
  return [self evaluateWithObject:object substitutionVariables:nil];
}

// The object's period against the point or interval: closed-open, or
// closed-closed where the entity says so; no end (or 9999-12-31), none.
- (BOOL)evaluateWithObject:(id)object substitutionVariables:(NSDictionary *)variables
{
  NSEntityDescription *entity = [object isKindOfClass:[NSManagedObject class]] ? [(NSManagedObject *)object entity] : nil;
  while (entity.superentity) entity = entity.superentity;
  NSString *startName = entity.userInfo[ODataUserInfoPeriodStart], *endName = entity.userInfo[ODataUserInfoPeriodEnd];
  if (!startName || !endName) return NO;
  NSDate *start = [object valueForKey:startName], *end = [object valueForKey:endName];
  if (![start isKindOfClass:[NSDate class]]) return NO;
  if ([end isKindOfClass:[NSDate class]] && [end timeIntervalSinceReferenceDate] >= 252423907200.0) end = nil;  // 9999-12-31
  id closed = entity.userInfo[ODataUserInfoClosedClosedPeriods];
  BOOL closedClosed = [closed isEqual:@"YES"] || [closed isEqual:@YES];
  NSDate *from = self.at ?: self.from;
  NSDate *to = self.at ?: self.to;
  BOOL inclusive = self.at ? YES : self.toInclusive;
  // Ends after the interval begins ...
  if (end && !(closedClosed ? [end compare:from] != NSOrderedAscending : [end compare:from] == NSOrderedDescending)) return NO;
  // ... and begins before it ends.
  if (to && !(inclusive ? [start compare:to] != NSOrderedDescending : [start compare:to] == NSOrderedAscending)) return NO;
  return YES;
}

@end
