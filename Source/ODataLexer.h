// ODataIncrementalStore — the tokens of OData's URL syntax.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Private to the library: ODataExpression.m is its parser.

#pragma once
#import "OISRuntime.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OISTokenKind) {
  OISTokenEnd = 0,
  OISTokenName,        // Name, NS.Qualified.Name, $filter, $it
  OISTokenAlias,       // @p (text without the @)
  OISTokenString,      // 'text' (text unescaped)
  OISTokenNumber,      // 1, -1, 1.5, 1e10 (text as written)
  OISTokenTyped,       // type: Edm.Date, Edm.DateTimeOffset, Edm.TimeOfDay, Edm.Guid for an unquoted literal,
                       // else the prefix of a quoted one: duration, binary, NS.Color; text: the literal
  OISTokenLParen,
  OISTokenRParen,
  OISTokenLBracket,
  OISTokenRBracket,
  OISTokenComma,
  OISTokenSlash,
  OISTokenColon,
  OISTokenEquals,
  OISTokenSemicolon,
  OISTokenStar,
  OISTokenMinus
};

@interface OISToken : NSObject
@property (nonatomic) OISTokenKind kind;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy, nullable) NSString *type;  // OISTokenTyped
@property (nonatomic) NSRange range;                   // in the source, for errors
@end

@interface OISLexer : NSObject
- (instancetype)initWithString:(NSString *)string;
@property (nonatomic, readonly, copy) NSString *string;
- (OISToken *)next;
@end

NS_ASSUME_NONNULL_END
