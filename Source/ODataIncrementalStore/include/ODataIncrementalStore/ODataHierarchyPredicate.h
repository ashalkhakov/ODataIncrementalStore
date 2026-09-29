// ODataIncrementalStore — a recursive hierarchy in a fetch request.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A recursive hierarchy (OData Data Aggregation section 5.5.1) is declared
// on an entity type by Aggregation.RecursiveHierarchy with a qualifier: the
// NodeProperty that identifies a node, and the ParentNavigationProperty to
// its parents. A model built from $metadata keeps it in the entity's
// userInfo (OData.annotations); a model of one's own says it there too.
//
// This predicate asks where a node is in one: whether it is a node, a root,
// a leaf, an ancestor or a descendant of another node (within a distance,
// and itself too where includeSelf), or its sibling. Anywhere in a fetch's
// predicate, it is sent as the Aggregation function in $filter, at a
// service that has Data Aggregation (Aggregation.ApplySupported):
//
//   // SalesOrganizations?$filter=Org.OData.Aggregation.V1.isdescendant(
//   //   HierarchyNodes=$root/SalesOrganizations,HierarchyQualifier='SalesOrgHierarchy',
//   //   Node=ID,Ancestor='EMEA')
//   fetch.predicate = [ODataHierarchyPredicate predicateWithTest:ODataHierarchyIsDescendant
//                                                      hierarchy:@"SalesOrgHierarchy" node:@"EMEA"];
//
// The node tested is the fetched object's, or, through nodeKeyPath, one
// it reaches (a sale's organization: salesOrganization.id), as the
// identifier at that key path.
//
// Evaluated in memory, it walks the parent relationship in the object's
// context, reading the nodes it needs there, as the service walks it.
#pragma once
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataPropertyMapper.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ODataHierarchyTest) {
  ODataHierarchyIsNode,        // isnode
  ODataHierarchyIsRoot,        // isroot: no parent
  ODataHierarchyIsLeaf,        // isleaf: no child
  ODataHierarchyIsAncestor,    // isancestor: of node
  ODataHierarchyIsDescendant,  // isdescendant: of node
  ODataHierarchyIsSibling      // issibling: of node, a parent in common, or both roots
};

@interface ODataHierarchyPredicate : NSPredicate <NSSecureCoding>
// node: the other node's identifier, for an ancestor, a descendant or a
// sibling; nil for the rest.
+ (instancetype)predicateWithTest:(ODataHierarchyTest)test hierarchy:(NSString *)qualifier node:(nullable id)node;
// maxDistance 0: any.
+ (instancetype)predicateWithTest:(ODataHierarchyTest)test hierarchy:(NSString *)qualifier node:(nullable id)node
                      nodeKeyPath:(nullable NSString *)nodeKeyPath maxDistance:(NSUInteger)maxDistance includeSelf:(BOOL)includeSelf;
@property (nonatomic, readonly) ODataHierarchyTest test;
@property (nonatomic, readonly, copy) NSString *qualifier;
@property (nonatomic, readonly, strong, nullable) id node;
@property (nonatomic, readonly, copy, nullable) NSString *nodeKeyPath;
@property (nonatomic, readonly) NSUInteger maxDistance;
@property (nonatomic, readonly) BOOL includeSelf;
// The Aggregation function's name: isnode, isroot, ...
@property (nonatomic, readonly) NSString *functionName;

// The hierarchy with the qualifier in a model: the entity its annotation
// is on, the key path of its node identifier, and the parent relationship;
// nil for none.
+ (nullable NSEntityDescription *)entityOfHierarchy:(NSString *)qualifier model:(NSManagedObjectModel *)model
                                             mapper:(ODataPropertyMapper *)mapper
                                        nodeKeyPath:(NSString * _Nullable * _Nullable)nodeKeyPath
                                             parent:(NSRelationshipDescription * _Nullable * _Nullable)parent;
@end

NS_ASSUME_NONNULL_END
