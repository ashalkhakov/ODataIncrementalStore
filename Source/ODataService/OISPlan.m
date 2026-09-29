// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "OISPlan.h"

@implementation OISPlanNode

+ (instancetype)operator:(OISPlanOperator)op input:(OISPlanNode *)input
{
  OISPlanNode *node = [[self alloc] init];
  node.op = op;
  node.input = input;
  node.bindings = @{};
  node.fixed = @[];
  node.fixedSummary = @"";
  node.filters = @[];
  node.order = @[];
  node.prefetch = @[];
  node.nests = @[];
  node.computed = @{};
  return node;
}

static NSString *OISJoined(NSArray *items, NSString *separator)
{
  return [[items valueForKey:@"description"] componentsJoinedByString:separator];
}

// What it does, on one line, as explain prints it.
- (NSString *)line
{
  NSMutableArray *parts = [NSMutableArray array];
  switch (self.op) {
    case OISPlanScan: [parts addObject:[NSString stringWithFormat:@"Scan %@", self.entity.name]]; break;
    case OISPlanObjects: [parts addObject:[NSString stringWithFormat:@"Objects (%lu)", (unsigned long)self.objects.count]]; break;
    case OISPlanChanges: [parts addObject:[NSString stringWithFormat:@"Changes of %@", self.entity.name]]; break;
    case OISPlanInput: [parts addObject:@"Input"]; break;
    case OISPlanSpan: [parts addObject:[NSString stringWithFormat:@"Span %@.%@", self.entity.name, self.attributeName]]; break;
    case OISPlanClosure:
      [parts addObject:[NSString stringWithFormat:@"Closure $root/%@#%@", [self.hierarchy componentsJoinedByString:@"/"], self.qualifier]];
      break;
    case OISPlanSelect: [parts addObject:[@"Select " stringByAppendingString:OISJoined(self.filters, @" and ")]]; break;
    case OISPlanSort: [parts addObject:[@"Sort " stringByAppendingString:OISJoined(self.order, @", ")]]; break;
    case OISPlanLimit: {
      [parts addObject:@"Limit"];
      if (self.skip) [parts addObject:[NSString stringWithFormat:@"skip %@", self.skip]];
      if (self.top) [parts addObject:[NSString stringWithFormat:@"top %@", self.top]];
      if (self.pageSize) [parts addObject:[NSString stringWithFormat:@"page %lu", (unsigned long)self.pageSize]];
      break;
    }
    case OISPlanApply: [parts addObject:[NSString stringWithFormat:@"Apply %@", self.transformation]]; break;
    case OISPlanNest: [parts addObject:[NSString stringWithFormat:@"Nest %@", self.item.isStar ? @"*" : [self.item.path componentsJoinedByString:@"/"]]]; break;
    case OISPlanValue: [parts addObject:[NSString stringWithFormat:@"Value %@", self.expression]]; break;
    case OISPlanCount: [parts addObject:@"Count"]; break;
    case OISPlanStoreScan:
    case OISPlanStoreCount: {
      [parts addObject:[NSString stringWithFormat:@"%@ %@", self.op == OISPlanStoreScan ? @"Store scan" : @"Store count", self.entity.name]];
      NSMutableArray *where = [NSMutableArray arrayWithArray:[self.filters valueForKey:@"description"]];
      if (self.search) [where addObject:[NSString stringWithFormat:@"search %@", self.search]];
      if (self.time) [where addObject:@"at its time"];
      if (self.fixedSummary.length) [where addObject:self.fixedSummary];
      if (where.count) [parts addObject:[@"where " stringByAppendingString:[where componentsJoinedByString:@" and "]]];
      if (self.op == OISPlanStoreScan) {
        NSMutableArray *sort = [NSMutableArray arrayWithArray:[self.order valueForKey:@"description"]];
        if (self.keyOrder) [sort addObject:@"key"];
        if (sort.count) [parts addObject:[@"sort " stringByAppendingString:[sort componentsJoinedByString:@", "]]];
        if (self.skip.unsignedIntegerValue) [parts addObject:[NSString stringWithFormat:@"skip %@", self.skip]];
        if (self.top) [parts addObject:[NSString stringWithFormat:@"top %@", self.top]];
        if (self.pageSize) [parts addObject:[NSString stringWithFormat:@"page %lu", (unsigned long)self.pageSize]];
        if (self.limit) [parts addObject:[NSString stringWithFormat:@"at most %lu", (unsigned long)self.limit]];
        if (self.prefetch.count) [parts addObject:[@"with " stringByAppendingString:[self.prefetch componentsJoinedByString:@", "]]];
      }
      break;
    }
    case OISPlanStoreAggregate: [parts addObject:[NSString stringWithFormat:@"Store aggregate %@", self.transformation]]; break;
  }
  if (self.op == OISPlanScan) {
    NSMutableArray *where = [NSMutableArray array];
    if (self.fixedSummary.length) [where addObject:self.fixedSummary];
    if (where.count) [parts addObject:[@"where " stringByAppendingString:[where componentsJoinedByString:@" and "]]];
  }
  return [parts componentsJoinedByString:@" "];
}

- (void)describeInto:(NSMutableString *)text depth:(NSUInteger)depth
{
  NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
  [text appendFormat:@"%@%@\n", indent, [self line]];
  for (NSString *name in [self.bindings.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [text appendFormat:@"%@  %@ :=\n", indent, name];
    [self.bindings[name] describeInto:text depth:depth + 2];
  }
  if (self.nested) {
    [text appendFormat:@"%@  each:\n", indent];
    [self.nested describeInto:text depth:depth + 2];
  }
  for (OISPlanNode *nest in self.nests) [nest describeInto:text depth:depth + 1];
  [self.input describeInto:text depth:depth + 1];
}

- (NSString *)treeDescription
{
  NSMutableString *text = [NSMutableString string];
  [self describeInto:text depth:0];
  return text;
}

- (NSString *)description
{
  return [self line];
}

@end

@implementation OISRelation

+ (instancetype)relationOfRows:(NSArray *)rows
{
  OISRelation *relation = [[self alloc] init];
  relation.rows = rows ?: @[];
  relation.computed = [NSMutableDictionary dictionary];
  relation.expansions = [NSMutableArray array];
  return relation;
}

- (id)copyWithZone:(NSZone *)zone
{
  OISRelation *copy = [OISRelation relationOfRows:self.rows];
  copy.shape = [self.shape mutableCopy];
  copy.computed = [self.computed mutableCopy];
  copy.expansions = [self.expansions mutableCopy];
  copy.hasMore = self.hasMore;
  copy.count = self.count;
  return copy;
}

@end

@implementation OISPlan

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _nests = @[];
  _closures = @[];
  _spans = @[];
  return self;
}

- (NSString *)treeDescription
{
  NSMutableString *text = [NSMutableString string];
  for (OISPlanNode *closure in self.closures) [closure describeInto:text depth:0];
  for (OISPlanNode *span in self.spans) [span describeInto:text depth:0];
  for (OISPlanNode *nest in self.nests) [nest describeInto:text depth:0];
  [self.root describeInto:text depth:0];
  if (self.count) {
    [text appendString:@"$count :=\n"];
    [self.count describeInto:text depth:1];
  }
  return text;
}

@end
