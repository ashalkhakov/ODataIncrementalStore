// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataClassWriter.h"
#import "ODataValue.h"

static NSString * const OISImport = @"#import <ODataIncrementalStore/ODataIncrementalStore.h>";

static NSString *OISLowerCamel(NSString *name)
{
  NSUInteger n = 0;
  while (n < name.length && [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[name characterAtIndex:n]]) n++;
  if (n == 0) return name;
  if (n == name.length) return name.lowercaseString;
  NSUInteger lower = n == 1 ? 1 : n - 1;
  return [[[name substringToIndex:lower] lowercaseString] stringByAppendingString:[name substringFromIndex:lower]];
}

static NSString *OISUpperFirst(NSString *name)
{
  return name.length ? [[[name substringToIndex:1] uppercaseString] stringByAppendingString:[name substringFromIndex:1]] : name;
}

// A parameter's name as an Objective-C identifier.
static NSString *OISParameterName(NSString *wire)
{
  static NSSet *reserved;
  if (!reserved) {
    reserved = [NSSet setWithArray:@[ @"id", @"self", @"super", @"in", @"out", @"inout", @"bycopy", @"byref", @"oneway",
                                      @"Class", @"SEL", @"IMP", @"BOOL", @"nil", @"Nil", @"YES", @"NO", @"context", @"error",
                                      @"int", @"char", @"long", @"short", @"float", @"double", @"void", @"signed", @"unsigned",
                                      @"if", @"else", @"for", @"while", @"do", @"switch", @"case", @"default", @"break",
                                      @"continue", @"return", @"goto", @"struct", @"union", @"enum", @"typedef", @"const",
                                      @"static", @"extern", @"register", @"volatile", @"auto", @"sizeof", @"inline", @"restrict" ]];
  }
  NSString *name = OISLowerCamel(wire);
  return [reserved containsObject:name] ? [name stringByAppendingString:@"Value"] : name;
}

static NSString *OISQuoted(NSString *s)
{
  NSString *escaped = [[s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
  return [NSString stringWithFormat:@"@\"%@\"", escaped];
}

@implementation ODataClassWriter {
  NSManagedObjectModel *_model;
  ODataSchema *_schema;
  ODataValueCoder *_values;
  NSMutableDictionary *_classForType;  // qualified entity type -> class name
}

#pragma mark - Types

// The Objective-C type for a value of this OData type, with its trailing
// space or star: "NSString *", "Airline *", "NSArray<Trip *> *".
- (NSString *)objcTypeFor:(NSString *)type
{
  if (!type) return @"id ";
  if ([type hasPrefix:@"Collection("] && [type hasSuffix:@")"]) {
    NSString *element = [type substringWithRange:NSMakeRange(11, type.length - 12)];
    NSString *cls = _classForType[element];
    return cls ? [NSString stringWithFormat:@"NSArray<%@ *> *", cls] : @"NSArray *";
  }
  if (_classForType[type]) return [NSString stringWithFormat:@"%@ *", _classForType[type]];
  switch ([_values edmTypeNamed:type]) {
    case ODataEdmBoolean:
    case ODataEdmInteger:
    case ODataEdmInt64:
    case ODataEdmDouble:
    case ODataEdmDuration: return @"NSNumber *";
    case ODataEdmDecimal: return @"NSDecimalNumber *";
    case ODataEdmString:
    case ODataEdmTimeOfDay:
    case ODataEdmGuid:
    case ODataEdmEnum: return @"NSString *";
    case ODataEdmDateTimeOffset:
    case ODataEdmDate: return @"NSDate *";
    case ODataEdmBinary: return @"NSData *";
    case ODataEdmComplex: return @"NSDictionary *";
    case ODataEdmCollection: return @"NSArray *";
    case ODataEdmUnknown: return @"id ";
  }
  return @"id ";
}

- (NSString *)objcTypeForAttribute:(NSAttributeDescription *)attribute
{
  switch (attribute.attributeType) {
    case NSInteger16AttributeType:
    case NSInteger32AttributeType:
    case NSInteger64AttributeType:
    case NSDoubleAttributeType:
    case NSFloatAttributeType:
    case NSBooleanAttributeType: return @"NSNumber *";
    case NSDecimalAttributeType: return @"NSDecimalNumber *";
    case NSStringAttributeType: return @"NSString *";
    case NSDateAttributeType: return @"NSDate *";
    case NSBinaryDataAttributeType: return @"NSData *";
    default:
      if (attribute.attributeType == NSUUIDAttributeType) return @"NSUUID *";
      if (attribute.attributeValueClassName.length) return [attribute.attributeValueClassName stringByAppendingString:@" *"];
      return @"id ";
  }
}

#pragma mark - Methods

// The declaration of an operation as a method, without its terminator,
// and its body.
- (NSString *)declarationOf:(ODataSchemaOperation *)operation
                       name:(NSString *)method
                     static:(BOOL)isStatic
                       body:(NSString **)body
                   callWith:(NSString *)call
{
  NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
  NSString *returnType = operation.returnType ? [NSString stringWithFormat:@"nullable %@", [self objcTypeFor:operation.returnType]] : @"BOOL";
  returnType = [returnType stringByTrimmingCharactersInSet:space];
  NSMutableString *selector = [NSMutableString stringWithString:method];
  NSArray *parameters = operation.callerParameters;
  NSMutableString *fill = [NSMutableString string];
  BOOL first = YES;
  if (isStatic) {
    [selector appendString:@"InContext:(NSManagedObjectContext *)context"];
    first = NO;
  }
  for (ODataSchemaParameter *parameter in parameters) {
    NSString *name = OISParameterName(parameter.name);
    NSString *label = first ? [@"With" stringByAppendingString:OISUpperFirst(name)] : name;
    [selector appendFormat:@"%@%@:(nullable %@)%@", first ? @"" : @" ", label,
                           [[self objcTypeFor:parameter.type] stringByTrimmingCharactersInSet:space], name];
    [fill appendFormat:@"  if (%@) parameters[%@] = %@;\n", name, OISQuoted(parameter.name), name];
    first = NO;
  }
  [selector appendString:first ? @":(NSError **)error" : @" error:(NSError **)error"];
  NSString *declaration = [NSString stringWithFormat:@"%@ (%@)%@", isStatic ? @"+" : @"-", returnType, selector];

  NSString *result = operation.returnType ? @"  return result == [NSNull null] ? nil : result;\n" : @"  return result != nil;\n";
  *body = [NSString stringWithFormat:@"%@\n{\n  NSMutableDictionary *parameters = [NSMutableDictionary dictionary];\n%@%@%@}\n",
                                     declaration, fill, call, result];
  return declaration;
}

// A method name for an operation that no property or method of the class
// already has.
- (NSString *)methodNameFor:(NSString *)operationName taken:(NSMutableSet *)taken
{
  NSString *name = OISLowerCamel(operationName);
  NSString *unique = name;
  if ([taken containsObject:unique]) unique = [name stringByAppendingString:@"Operation"];
  for (NSUInteger i = 2; [taken containsObject:unique]; i++) unique = [NSString stringWithFormat:@"%@Operation%lu", name, (unsigned long)i];
  [taken addObject:unique];
  return unique;
}

#pragma mark - Files

+ (NSArray *)writeClassesForModel:(NSManagedObjectModel *)model
                           schema:(ODataSchema *)schema
                      serviceName:(NSString *)serviceName
                      toDirectory:(NSString *)directory
                            error:(NSError **)error
{
  ODataClassWriter *writer = [[self alloc] init];
  writer->_model = model;
  writer->_schema = schema;
  writer->_values = [[ODataValueCoder alloc] init];
  writer->_values.schema = schema;
  writer->_classForType = [NSMutableDictionary dictionary];
  for (NSEntityDescription *entity in model.entities) {
    NSString *type = entity.userInfo[ODataUserInfoType];
    if ([type isKindOfClass:[NSString class]]) writer->_classForType[type] = entity.name;
  }
  if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
  NSMutableArray *written = [NSMutableArray array];
  NSArray *entities = [model.entities sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
    return [[a name] compare:[b name]];
  }];
  for (NSEntityDescription *entity in entities) {
    if (![writer writeEntity:entity toDirectory:directory written:written error:error]) return nil;
  }
  if (![writer writeService:serviceName toDirectory:directory written:written error:error]) return nil;
  for (NSEntityDescription *entity in model.entities) entity.managedObjectClassName = entity.name;
  return written;
}

- (BOOL)write:(NSString *)text to:(NSString *)path always:(BOOL)always written:(NSMutableArray *)written error:(NSError **)error
{
  if (!always && [[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
  if (![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;
  [written addObject:path];
  return YES;
}

// The client's own class: written once.
- (BOOL)writeHumanClass:(NSString *)name toDirectory:(NSString *)directory written:(NSMutableArray *)written error:(NSError **)error
{
  NSString *header = [NSString stringWithFormat:@"#import \"_%@.h\"\n\nNS_ASSUME_NONNULL_BEGIN\n\n@interface %@ : _%@\n// Your own logic goes here; ois-model does not write this file again.\n@end\n\nNS_ASSUME_NONNULL_END\n",
                                                name, name, name];
  NSString *source = [NSString stringWithFormat:@"#import \"%@.h\"\n\n@implementation %@\n@end\n", name, name];
  return [self write:header to:[directory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"h"]] always:NO written:written error:error] &&
         [self write:source to:[directory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"m"]] always:NO written:written error:error];
}

- (BOOL)writeEntity:(NSEntityDescription *)entity toDirectory:(NSString *)directory written:(NSMutableArray *)written error:(NSError **)error
{
  NSString *name = entity.name;
  NSString *type = entity.userInfo[ODataUserInfoType];
  NSString *superclass = entity.superentity ? entity.superentity.name : @"NSManagedObject";
  NSMutableSet *taken = [NSMutableSet setWithArray:entity.propertiesByName.allKeys];
  NSMutableSet *related = [NSMutableSet set];

  NSMutableString *properties = [NSMutableString string];
  NSMutableString *dynamics = [NSMutableString string];
  NSDictionary *inherited = entity.superentity.propertiesByName ?: @{};
  for (NSString *property in [entity.propertiesByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if (inherited[property]) continue;
    NSPropertyDescription *description = entity.propertiesByName[property];
    NSString *objcType;
    if ([description isKindOfClass:[NSRelationshipDescription class]]) {
      NSRelationshipDescription *rel = (NSRelationshipDescription *)description;
      NSString *destination = rel.destinationEntity.name ?: @"NSManagedObject";
      [related addObject:destination];
      objcType = rel.isToMany ? [NSString stringWithFormat:@"NSSet<%@ *> *", destination] : [destination stringByAppendingString:@" *"];
    } else if ([description isKindOfClass:[NSAttributeDescription class]]) {
      objcType = [self objcTypeForAttribute:(NSAttributeDescription *)description];
    } else {
      continue;
    }
    [properties appendFormat:@"@property (nonatomic, strong, nullable) %@%@;\n", objcType, property];
    [dynamics appendFormat:@"@dynamic %@;\n", property];
  }

  // Operations bound to this entity type itself: those bound to a base
  // type come with the superclass.
  NSMutableString *declarations = [NSMutableString string];
  NSMutableString *bodies = [NSMutableString string];
  NSString *collectionType = type ? [NSString stringWithFormat:@"Collection(%@)", type] : nil;
  for (NSString *qualified in [_schema.operations.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    for (ODataSchemaOperation *operation in _schema.operations[qualified]) {
      NSString *binding = operation.bindingParameter.type;
      BOOL instance = type && [binding isEqualToString:type];
      BOOL collection = collectionType && [binding isEqualToString:collectionType];
      if (!instance && !collection) continue;
      NSString *body = nil;
      NSString *call = instance
          ? [NSString stringWithFormat:@"  id result = [self invokeODataOperation:%@ parameters:parameters error:error];\n", OISQuoted(qualified)]
          : [NSString stringWithFormat:@"  ODataOperationCall *call = [ODataOperationCall callOfOperation:%@ onEntity:%@ inContext:context];\n"
                                       @"  call.parameters = parameters;\n  id result = [call invoke:error];\n",
                                       OISQuoted(qualified), OISQuoted(name)];
      NSString *declaration = [self declarationOf:operation name:[self methodNameFor:operation.name taken:taken] static:collection body:&body callWith:call];
      [declarations appendFormat:@"// %@ %@\n%@;\n", operation.isAction ? @"Action" : @"Function", qualified, declaration];
      [bodies appendFormat:@"\n%@", body];
    }
  }
  for (NSString *cls in _classForType.allValues) {
    if ([declarations rangeOfString:[cls stringByAppendingString:@" *"]].location != NSNotFound) [related addObject:cls];
  }
  // Its own class too: Person's friends are Persons, and Person is not _Person.

  NSMutableString *header = [NSMutableString stringWithFormat:@"// Written by ois-model from the service's $metadata: do not edit.\n// Put your own code in %@.h and %@.m.\n\n%@\n", name, name, OISImport];
  if (entity.superentity) [header appendFormat:@"#import \"%@.h\"\n", superclass];
  [header appendString:@"\n"];
  NSArray *forward = [related.allObjects sortedArrayUsingSelector:@selector(compare:)];
  if (forward.count) [header appendFormat:@"@class %@;\n\n", [forward componentsJoinedByString:@", "]];
  [header appendFormat:@"NS_ASSUME_NONNULL_BEGIN\n\n@interface _%@ : %@\n\n%@", name, superclass, properties];
  if (declarations.length) [header appendFormat:@"\n%@", declarations];
  [header appendString:@"\n@end\n\nNS_ASSUME_NONNULL_END\n"];

  NSMutableString *source = [NSMutableString stringWithFormat:@"// Written by ois-model from the service's $metadata: do not edit.\n\n#import \"_%@.h\"\n", name];
  for (NSString *cls in forward) {
    if (![cls isEqualToString:name]) [source appendFormat:@"#import \"%@.h\"\n", cls];
  }
  [source appendFormat:@"\n@implementation _%@\n\n%@%@\n@end\n", name, dynamics, bodies];

  return [self write:header to:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"_%@.h", name]] always:YES written:written error:error] &&
         [self write:source to:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"_%@.m", name]] always:YES written:written error:error] &&
         [self writeHumanClass:name toDirectory:directory written:written error:error];
}

- (BOOL)writeService:(NSString *)service toDirectory:(NSString *)directory written:(NSMutableArray *)written error:(NSError **)error
{
  NSMutableString *declarations = [NSMutableString string];
  NSMutableString *bodies = [NSMutableString string];
  NSMutableSet *taken = [NSMutableSet set];
  NSMutableSet *related = [NSMutableSet set];
  for (NSString *importName in [_schema.operationImports.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    ODataSchemaOperationImport *import = _schema.operationImports[importName];
    ODataSchemaOperation *operation = [_schema operationNamed:importName boundToEntityType:nil collection:NO parameterNames:nil];
    if (!operation) continue;
    NSString *call = [NSString stringWithFormat:@"  ODataOperationCall *call = [ODataOperationCall callOfOperation:%@ inContext:context];\n"
                                                @"  call.parameters = parameters;\n  id result = [call invoke:error];\n", OISQuoted(importName)];
    NSString *body = nil;
    NSString *declaration = [self declarationOf:operation name:[self methodNameFor:importName taken:taken] static:YES body:&body callWith:call];
    [declarations appendFormat:@"// %@ %@ (%@)\n%@;\n", import.isAction ? @"Action" : @"Function", importName, operation.qualifiedName, declaration];
    [bodies appendFormat:@"\n%@", body];
  }
  for (NSString *cls in _classForType.allValues) {
    if ([declarations rangeOfString:[cls stringByAppendingString:@" *"]].location != NSNotFound) [related addObject:cls];
  }
  NSArray *forward = [related.allObjects sortedArrayUsingSelector:@selector(compare:)];
  NSMutableString *header = [NSMutableString stringWithFormat:@"// Written by ois-model from the service's $metadata: do not edit.\n// Put your own code in %@.h and %@.m.\n\n%@\n\n", service, service, OISImport];
  if (forward.count) [header appendFormat:@"@class %@;\n\n", [forward componentsJoinedByString:@", "]];
  [header appendFormat:@"NS_ASSUME_NONNULL_BEGIN\n\n// The service's own operations, which no entity is bound to.\n@interface _%@ : NSObject\n\n%@\n@end\n\nNS_ASSUME_NONNULL_END\n",
                       service, declarations];
  NSMutableString *source = [NSMutableString stringWithFormat:@"// Written by ois-model from the service's $metadata: do not edit.\n\n#import \"_%@.h\"\n", service];
  for (NSString *cls in forward) [source appendFormat:@"#import \"%@.h\"\n", cls];
  [source appendFormat:@"\n@implementation _%@\n%@\n@end\n", service, bodies];
  NSString *human = [NSString stringWithFormat:@"#import \"_%@.h\"\n\nNS_ASSUME_NONNULL_BEGIN\n\n@interface %@ : _%@\n// Your own logic goes here; ois-model does not write this file again.\n@end\n\nNS_ASSUME_NONNULL_END\n",
                                               service, service, service];
  return [self write:header to:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"_%@.h", service]] always:YES written:written error:error] &&
         [self write:source to:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"_%@.m", service]] always:YES written:written error:error] &&
         [self write:human to:[directory stringByAppendingPathComponent:[service stringByAppendingPathExtension:@"h"]] always:NO written:written error:error] &&
         [self write:[NSString stringWithFormat:@"#import \"%@.h\"\n\n@implementation %@\n@end\n", service, service]
                  to:[directory stringByAppendingPathComponent:[service stringByAppendingPathExtension:@"m"]] always:NO written:written error:error];
}

@end
