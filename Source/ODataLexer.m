// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataLexer.h"

@implementation OISToken

- (NSString *)description
{
  return self.kind == OISTokenEnd ? @"the end" : [NSString stringWithFormat:@"'%@'", self.text];
}

@end

@implementation OISLexer {
  NSString *_s;
  NSUInteger _i;
  NSUInteger _n;
}

- (instancetype)initWithString:(NSString *)string
{
  self = [super init];
  if (!self) return nil;
  _s = [string copy] ?: @"";
  _n = _s.length;
  return self;
}

- (NSString *)string
{
  return _s;
}

- (unichar)at:(NSUInteger)i
{
  return i < _n ? [_s characterAtIndex:i] : 0;
}

static BOOL OISIsDigit(unichar c)
{
  return c >= '0' && c <= '9';
}

static BOOL OISIsHex(unichar c)
{
  return OISIsDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

static BOOL OISIsNameStart(unichar c)
{
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c >= 0x80;
}

static BOOL OISIsNameChar(unichar c)
{
  return OISIsNameStart(c) || OISIsDigit(c);
}

// How many characters from i match a pattern: 'd' a digit, 'x' a hex
// digit, anything else itself; 0 when they do not.
- (NSUInteger)match:(const char *)pattern at:(NSUInteger)i
{
  NSUInteger k = 0;
  for (; pattern[k]; k++) {
    unichar c = [self at:i + k];
    char p = pattern[k];
    BOOL ok = p == 'd' ? OISIsDigit(c) : p == 'x' ? OISIsHex(c) : c == (unichar)p;
    if (!ok) return 0;
  }
  return k;
}

- (OISToken *)token:(OISTokenKind)kind from:(NSUInteger)start text:(NSString *)text
{
  OISToken *t = [[OISToken alloc] init];
  t.kind = kind;
  t.text = text ?: [_s substringWithRange:NSMakeRange(start, _i - start)];
  t.range = NSMakeRange(start, _i - start);
  return t;
}

// hh:mm, then :ss and .fraction if there.
- (NSUInteger)timeLengthAt:(NSUInteger)i
{
  NSUInteger n = [self match:"dd:dd" at:i];
  if (!n) return 0;
  if ([self match:":dd" at:i + n]) {
    n += 3;
    if ([self at:i + n] == '.' && OISIsDigit([self at:i + n + 1])) {
      n++;
      while (OISIsDigit([self at:i + n])) n++;
    }
  }
  return n;
}

// An unquoted literal of its own shape: a GUID, a date, a date and time
// with its offset, a time of day. 0 when there is none at i.
- (NSUInteger)unquotedLiteralAt:(NSUInteger)i type:(NSString **)type
{
  NSUInteger n = [self match:"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" at:i];
  if (n && !OISIsNameChar([self at:i + n])) {
    *type = @"Edm.Guid";
    return n;
  }
  n = [self match:"dddd-dd-dd" at:i];
  if (n) {
    if ([self at:i + n] != 'T') {
      *type = @"Edm.Date";
      return n;
    }
    NSUInteger t = [self timeLengthAt:i + n + 1];
    if (!t) return 0;
    n += 1 + t;
    unichar z = [self at:i + n];
    if (z == 'Z') {
      n++;
    } else if ((z == '+' || z == '-') && [self match:"dd:dd" at:i + n + 1]) {
      n += 6;
    }
    *type = @"Edm.DateTimeOffset";
    return n;
  }
  n = [self timeLengthAt:i];
  if (n && !OISIsDigit([self at:i + n])) {
    *type = @"Edm.TimeOfDay";
    return n;
  }
  return 0;
}

- (OISToken *)next
{
  while (_i < _n && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[self at:_i]]) _i++;
  NSUInteger start = _i;
  if (_i >= _n) return [self token:OISTokenEnd from:start text:@""];
  unichar c = [self at:_i];

  if (c == '\'') {
    NSString *text = [self quotedAt:&_i];
    return [self token:OISTokenString from:start text:text];
  }
  if (c == '@' && OISIsNameStart([self at:_i + 1])) {
    _i++;
    while (_i < _n && OISIsNameChar([self at:_i])) _i++;
    return [self token:OISTokenAlias from:start text:[_s substringWithRange:NSMakeRange(start + 1, _i - start - 1)]];
  }

  NSString *type = nil;
  NSUInteger literal = [self unquotedLiteralAt:_i type:&type];
  if (literal) {
    _i += literal;
    OISToken *t = [self token:OISTokenTyped from:start text:nil];
    t.type = type;
    return t;
  }

  if (OISIsDigit(c) || (c == '-' && OISIsDigit([self at:_i + 1]))) {
    if (c == '-') _i++;
    while (OISIsDigit([self at:_i])) _i++;
    if ([self at:_i] == '.' && OISIsDigit([self at:_i + 1])) {
      _i++;
      while (OISIsDigit([self at:_i])) _i++;
    }
    unichar e = [self at:_i];
    if ((e == 'e' || e == 'E') && (OISIsDigit([self at:_i + 1]) ||
                                   (([self at:_i + 1] == '+' || [self at:_i + 1] == '-') && OISIsDigit([self at:_i + 2])))) {
      _i += 2;
      while (OISIsDigit([self at:_i])) _i++;
    }
    return [self token:OISTokenNumber from:start text:nil];
  }

  if (OISIsNameStart(c) || (c == '$' && OISIsNameStart([self at:_i + 1]))) {
    _i++;
    while (_i < _n) {
      unichar d = [self at:_i];
      // A dot joins the parts of a qualified name: Microsoft.OData.Person.
      if (OISIsNameChar(d) || (d == '.' && OISIsNameStart([self at:_i + 1]))) {
        _i++;
        continue;
      }
      break;
    }
    NSString *name = [_s substringWithRange:NSMakeRange(start, _i - start)];
    if ([self at:_i] == '\'') {
      // A prefixed literal: duration'P1D', binary'AQ', NS.Color'Red'.
      NSString *text = [self quotedAt:&_i];
      OISToken *t = [self token:OISTokenTyped from:start text:text];
      t.type = name;
      return t;
    }
    return [self token:OISTokenName from:start text:name];
  }

  _i++;
  switch (c) {
    case '(': return [self token:OISTokenLParen from:start text:@"("];
    case ')': return [self token:OISTokenRParen from:start text:@")"];
    case '[': return [self token:OISTokenLBracket from:start text:@"["];
    case ']': return [self token:OISTokenRBracket from:start text:@"]"];
    case ',': return [self token:OISTokenComma from:start text:@","];
    case '/': return [self token:OISTokenSlash from:start text:@"/"];
    case ':': return [self token:OISTokenColon from:start text:@":"];
    case '=': return [self token:OISTokenEquals from:start text:@"="];
    case ';': return [self token:OISTokenSemicolon from:start text:@";"];
    case '*': return [self token:OISTokenStar from:start text:@"*"];
    case '-': return [self token:OISTokenMinus from:start text:@"-"];
    default: break;
  }
  // Anything else is a token of its own, which the parser will refuse.
  return [self token:OISTokenName from:start text:nil];
}

// 'it''s': the text between the quotes, a doubled quote as one. An
// unclosed one runs to the end, and the parser sees what follows.
- (NSString *)quotedAt:(NSUInteger *)i
{
  NSMutableString *text = [NSMutableString string];
  NSUInteger j = *i + 1;
  while (j < _n) {
    unichar d = [self at:j];
    if (d == '\'') {
      if ([self at:j + 1] == '\'') {
        [text appendString:@"'"];
        j += 2;
        continue;
      }
      j++;
      break;
    }
    [text appendFormat:@"%C", d];
    j++;
  }
  *i = j;
  return text;
}

@end
