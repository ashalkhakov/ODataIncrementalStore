// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataHierarchyPredicate.h"

@interface ODataHierarchyPredicate ()
@property (nonatomic) ODataHierarchyTest test;
@property (nonatomic, copy) NSString *qualifier;
@property (nonatomic, strong, nullable) id node;
@property (nonatomic, copy, nullable) NSString *nodeKeyPath;
@property (nonatomic) NSUInteger maxDistance;
@property (nonatomic) BOOL includeSelf;
@end

@implementation ODataHierarchyPredicate

+ (instancetype)predicateWithTest:(ODataHierarchyTest)test hierarchy:(NSString *)qualifier node:(id)node
{
  return [self predicateWithTest:test hierarchy:qualifier node:node nodeKeyPath:nil maxDistance:0 includeSelf:NO];
}

+ (instancetype)predicateWithTest:(ODataHierarchyTest)test hierarchy:(NSString *)qualifier node:(id)node
                      nodeKeyPath:(NSString *)nodeKeyPath maxDistance:(NSUInteger)maxDistance includeSelf:(BOOL)includeSelf
{
  ODataHierarchyPredicate *predicate = [[self alloc] init];
  predicate.test = test;
  predicate.qualifier = qualifier;
  predicate.node = node;
  predicate.nodeKeyPath = nodeKeyPath;
  predicate.maxDistance = maxDistance;
  predicate.includeSelf = includeSelf;
  return predicate;
}

- (NSString *)functionName
{
  switch (self.test) {
    case ODataHierarchyIsNode: return @"isnode";
    case ODataHierarchyIsRoot: return @"isroot";
    case ODataHierarchyIsLeaf: return @"isleaf";
    case ODataHierarchyIsAncestor: return @"isancestor";
    case ODataHierarchyIsDescendant: return @"isdescendant";
    case ODataHierarchyIsSibling: return @"issibling";
  }
  return @"isnode";
}

+ (NSEntityDescription *)entityOfHierarchy:(NSString *)qualifier model:(NSManagedObjectModel *)model mapper:(ODataPropertyMapper *)mapper
                               nodeKeyPath:(NSString **)nodeKeyPath parent:(NSRelationshipDescription **)parent
{
  NSString *term = [@"Org.OData.Aggregation.V1.RecursiveHierarchy#" stringByAppendingString:qualifier];
  for (NSEntityDescription *entity in model.entities) {
    NSDictionary *record = [mapper annotationsOfProperty:nil entity:entity][term];
    if (![record isKindOfClass:[NSDictionary class]]) continue;
    id node = record[@"NodeProperty"], up = record[@"ParentNavigationProperty"];
    NSString *nodePath = [node isKindOfClass:[NSDictionary class]] ? node[@"$PropertyPath"] : node;
    NSString *parentPath = [up isKindOfClass:[NSDictionary class]] ? (up[@"$NavigationPropertyPath"] ?: up[@"$PropertyPath"]) : up;
    if (![nodePath isKindOfClass:[NSString class]] || ![parentPath isKindOfClass:[NSString class]]) return nil;
    // The node property's key path, through to-one relationships.
    NSMutableArray *keys = [NSMutableArray array];
    NSEntityDescription *at = entity;
    NSPropertyDescription *property = nil;
    for (NSString *wire in [nodePath componentsSeparatedByString:@"/"]) {
      property = at ? [mapper propertyForWireName:wire entity:at] : nil;
      if (!property) return nil;
      [keys addObject:property.name];
      NSRelationshipDescription *through = [property isKindOfClass:[NSRelationshipDescription class]] ? (NSRelationshipDescription *)property : nil;
      if (through.isToMany) return nil;
      at = through.destinationEntity;
    }
    NSRelationshipDescription *relationship = (NSRelationshipDescription *)[mapper propertyForWireName:parentPath entity:entity];
    if (![property isKindOfClass:[NSAttributeDescription class]] || ![relationship isKindOfClass:[NSRelationshipDescription class]]) return nil;
    if (nodeKeyPath) *nodeKeyPath = [keys componentsJoinedByString:@"."];
    if (parent) *parent = relationship;
    return entity;
  }
  return nil;
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
  _test = [coder decodeIntegerForKey:@"ODataTest"];
  _qualifier = [coder decodeObjectOfClass:[NSString class] forKey:@"ODataQualifier"];
  NSSet *identifiers = [NSSet setWithObjects:[NSString class], [NSNumber class], [NSUUID class], [NSDate class], nil];
  _node = [coder decodeObjectOfClasses:identifiers forKey:@"ODataNode"];
  _nodeKeyPath = [coder decodeObjectOfClass:[NSString class] forKey:@"ODataNodeKeyPath"];
  _maxDistance = (NSUInteger)[coder decodeIntegerForKey:@"ODataMaxDistance"];
  _includeSelf = [coder decodeBoolForKey:@"ODataIncludeSelf"];
  return _qualifier ? self : nil;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
  [coder encodeInteger:self.test forKey:@"ODataTest"];
  [coder encodeObject:self.qualifier forKey:@"ODataQualifier"];
  if (self.node) [coder encodeObject:self.node forKey:@"ODataNode"];
  if (self.nodeKeyPath) [coder encodeObject:self.nodeKeyPath forKey:@"ODataNodeKeyPath"];
  [coder encodeInteger:(NSInteger)self.maxDistance forKey:@"ODataMaxDistance"];
  [coder encodeBool:self.includeSelf forKey:@"ODataIncludeSelf"];
}

// Immutable, as predicates are.
- (id)copyWithZone:(NSZone *)zone
{
  return self;
}

- (BOOL)isEqual:(id)other
{
  if (![other isKindOfClass:[ODataHierarchyPredicate class]]) return NO;
  ODataHierarchyPredicate *p = other;
  return p.test == self.test && [p.qualifier isEqualToString:self.qualifier] && (p.node == self.node || [p.node isEqual:self.node]) &&
         (p.nodeKeyPath == self.nodeKeyPath || [p.nodeKeyPath isEqualToString:self.nodeKeyPath]) &&
         p.maxDistance == self.maxDistance && p.includeSelf == self.includeSelf;
}

- (NSUInteger)hash
{
  return (NSUInteger)self.test ^ self.qualifier.hash ^ [self.node hash];
}

- (NSString *)predicateFormat
{
  NSMutableArray *parts = [NSMutableArray arrayWithObject:self.qualifier];
  if (self.nodeKeyPath) [parts addObject:self.nodeKeyPath];
  if (self.node) [parts addObject:[NSString stringWithFormat:@"%@", self.node]];
  if (self.maxDistance) [parts addObject:[NSString stringWithFormat:@"within %lu", (unsigned long)self.maxDistance]];
  if (self.includeSelf) [parts addObject:@"or itself"];
  return [NSString stringWithFormat:@"ODATA_%@(%@)", self.functionName.uppercaseString, [parts componentsJoinedByString:@", "]];
}

- (NSString *)description
{
  return self.predicateFormat;
}

- (BOOL)evaluateWithObject:(id)object
{
  return [self evaluateWithObject:object substitutionVariables:nil];
}

// The node with an identifier, read in the context.
static NSManagedObject *OISNodeWithIdentifier(id identifier, NSEntityDescription *entity, NSString *keyPath, NSManagedObjectContext *context)
{
  if (!identifier || identifier == [NSNull null] || !context) return nil;
  NSFetchRequest *fetch = [[NSFetchRequest alloc] init];
  fetch.entity = entity;
  fetch.predicate = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:keyPath]
                                                       rightExpression:[NSExpression expressionForConstantValue:identifier]
                                                              modifier:NSDirectPredicateModifier type:NSEqualToPredicateOperatorType options:0];
  fetch.fetchLimit = 1;
  return [[context executeFetchRequest:fetch error:NULL] firstObject];
}

static NSArray<NSManagedObject *> *OISParentsOf(NSManagedObject *node, NSRelationshipDescription *parent)
{
  id related = [node valueForKey:parent.name];
  if (!related) return @[];
  return parent.isToMany ? [related allObjects] : @[ related ];
}

// Along the parents from a node, within the distance (0: any), each once.
static NSArray<NSManagedObject *> *OISAncestorsOf(NSManagedObject *node, NSRelationshipDescription *parent, NSUInteger distance)
{
  NSMutableArray *found = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet setWithObject:node];
  NSArray *level = @[ node ];
  for (NSUInteger step = 1; level.count && (!distance || step <= distance); step++) {
    NSMutableArray *next = [NSMutableArray array];
    for (NSManagedObject *at in level) {
      for (NSManagedObject *up in OISParentsOf(at, parent)) {
        if ([seen containsObject:up]) continue;
        [seen addObject:up];
        [found addObject:up];
        [next addObject:up];
      }
    }
    level = next;
  }
  return found;
}

- (BOOL)evaluateWithObject:(id)object substitutionVariables:(NSDictionary *)variables
{
  NSManagedObject *managed = [object isKindOfClass:[NSManagedObject class]] ? object : nil;
  NSManagedObjectContext *context = managed.managedObjectContext;
  NSString *nodeKeyPath = nil;
  NSRelationshipDescription *parent = nil;
  NSEntityDescription *entity = [ODataHierarchyPredicate entityOfHierarchy:self.qualifier model:managed.entity.managedObjectModel
                                                                    mapper:[[ODataPropertyMapper alloc] init]
                                                               nodeKeyPath:&nodeKeyPath parent:&parent];
  if (!entity || !context) return NO;
  id identifier = [object valueForKeyPath:self.nodeKeyPath ?: nodeKeyPath];
  NSManagedObject *node = self.nodeKeyPath ? OISNodeWithIdentifier(identifier, entity, nodeKeyPath, context)
                                           : ([managed.entity isKindOfEntity:entity] ? managed : nil);
  if (!node) return NO;
  switch (self.test) {
    case ODataHierarchyIsNode:
      return YES;
    case ODataHierarchyIsRoot:
      return OISParentsOf(node, parent).count == 0;
    case ODataHierarchyIsLeaf: {
      NSFetchRequest *children = [[NSFetchRequest alloc] init];
      children.entity = entity;
      children.predicate = [NSPredicate predicateWithFormat:parent.isToMany ? @"ANY %K == %@" : @"%K == %@", parent.name, node];
      return [context countForFetchRequest:children error:NULL] == 0;
    }
    case ODataHierarchyIsDescendant: {
      if (self.includeSelf && [identifier isEqual:self.node]) return YES;
      for (NSManagedObject *up in OISAncestorsOf(node, parent, self.maxDistance)) {
        if ([[up valueForKeyPath:nodeKeyPath] isEqual:self.node]) return YES;
      }
      return NO;
    }
    case ODataHierarchyIsAncestor: {
      if (self.includeSelf && [identifier isEqual:self.node]) return YES;
      NSManagedObject *descendant = OISNodeWithIdentifier(self.node, entity, nodeKeyPath, context);
      return descendant && [OISAncestorsOf(descendant, parent, self.maxDistance) containsObject:node];
    }
    case ODataHierarchyIsSibling: {
      NSManagedObject *other = OISNodeWithIdentifier(self.node, entity, nodeKeyPath, context);
      if (!other || other == node) return NO;
      NSArray *mine = OISParentsOf(node, parent), *theirs = OISParentsOf(other, parent);
      if (!mine.count && !theirs.count) return YES;
      for (NSManagedObject *up in mine) if ([theirs containsObject:up]) return YES;
      return NO;
    }
  }
  return NO;
}

@end
