// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataRegex.h"
#import "ODataError.h"

@interface ODataRegexMember ()
@property (nonatomic, readwrite) BOOL isClass;
@property (nonatomic, readwrite) UTF32Char first;
@property (nonatomic, readwrite) UTF32Char last;
@property (nonatomic, readwrite) ODataRegexClassKind classKind;
@property (nonatomic, readwrite) BOOL unicode;
@property (nonatomic, readwrite) BOOL negated;
@end

@implementation ODataRegexMember

+ (instancetype)rangeFrom:(UTF32Char)first to:(UTF32Char)last
{
  ODataRegexMember *m = [[self alloc] init];
  m.first = first;
  m.last = last;
  return m;
}

+ (instancetype)classOf:(ODataRegexClassKind)kind unicode:(BOOL)unicode negated:(BOOL)negated
{
  ODataRegexMember *m = [[self alloc] init];
  m.isClass = YES;
  m.classKind = kind;
  m.unicode = unicode;
  m.negated = negated;
  return m;
}

@end

@interface ODataRegex ()
@property (nonatomic, readwrite) ODataRegexKind kind;
@property (nonatomic, readwrite, copy) NSArray<ODataRegex *> *parts;
@property (nonatomic, readwrite, nullable) ODataRegex *part;
@property (nonatomic, readwrite) UTF32Char character;
@property (nonatomic, readwrite) ODataRegexAnyKind any;
@property (nonatomic, readwrite, copy) NSArray<ODataRegexMember *> *members;
@property (nonatomic, readwrite) BOOL negated;
@property (nonatomic, readwrite) ODataRegexAnchorKind anchor;
@property (nonatomic, readwrite) BOOL unicode;
@property (nonatomic, readwrite) BOOL capturing;
@property (nonatomic, readwrite) BOOL behind;
@property (nonatomic, readwrite) NSUInteger minimum;
@property (nonatomic, readwrite) NSUInteger maximum;
@property (nonatomic, readwrite) BOOL lazy;
@end

static NSError *OISRegexSyntax(NSString *message)
{
  return OISError(ODataIncrementalStoreErrorSyntax, message);
}

static NSError *OISRegexUnsupported(NSString *message)
{
  return OISError(ODataIncrementalStoreErrorUnsupportedExpression, message);
}

static NSString *OISCharacterString(UTF32Char c)
{
  if (c > 0xFFFF) {
    unichar pair[2] = { (unichar)(0xD800 + ((c - 0x10000) >> 10)), (unichar)(0xDC00 + ((c - 0x10000) & 0x3FF)) };
    return [NSString stringWithCharacters:pair length:2];
  }
  unichar one = (unichar)c;
  return [NSString stringWithCharacters:&one length:1];
}

#pragma mark - Reading

// A pattern as code points, read left to right.
@interface OISRegexReader : NSObject {
 @public
  NSMutableData *_text;
  NSUInteger _length;
  NSUInteger _at;
  ODataRegexDialect _dialect;
  BOOL _lines;
  NSError *_error;
}
@end

@implementation OISRegexReader

- (instancetype)initWithString:(NSString *)pattern dialect:(ODataRegexDialect)dialect
{
  self = [super init];
  if (!self) return nil;
  _dialect = dialect;
  _lines = dialect == ODataRegexMatches && [ODataRegex matchesAnchorsMatchLines];
  _text = [NSMutableData data];
  NSUInteger n = pattern.length;
  for (NSUInteger i = 0; i < n; i++) {
    UTF32Char c = [pattern characterAtIndex:i];
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < n) {
      unichar low = [pattern characterAtIndex:i + 1];
      if (low >= 0xDC00 && low <= 0xDFFF) {
        c = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
        i++;
      }
    }
    [_text appendBytes:&c length:sizeof c];
  }
  _length = _text.length / sizeof(UTF32Char);
  return self;
}

- (BOOL)atEnd
{
  return _at >= _length;
}

- (UTF32Char)peek:(NSUInteger)ahead
{
  NSUInteger i = _at + ahead;
  return i < _length ? ((const UTF32Char *)_text.bytes)[i] : 0;
}

- (UTF32Char)next
{
  return ((const UTF32Char *)_text.bytes)[_at++];
}

- (BOOL)accept:(UTF32Char)c
{
  if ([self atEnd] || [self peek:0] != c) return NO;
  _at++;
  return YES;
}

- (id)fail:(NSError *)error
{
  if (!_error) _error = error;
  return nil;
}

- (id)syntax:(NSString *)message
{
  return [self fail:OISRegexSyntax([NSString stringWithFormat:@"%@, at %lu", message, (unsigned long)_at])];
}

- (id)unsupported:(NSString *)message
{
  return [self fail:OISRegexUnsupported(message)];
}

- (BOOL)matches
{
  return _dialect == ODataRegexMatches;
}

#pragma mark LIKE

- (ODataRegex *)readLike
{
  NSMutableArray *parts = [NSMutableArray array];
  while (![self atEnd]) {
    UTF32Char c = [self next];
    if (c == '*') {
      [parts addObject:[ODataRegex repeat:[ODataRegex any:ODataRegexAnyCharacter] minimum:0 maximum:NSNotFound lazy:NO]];
    } else if (c == '?') {
      [parts addObject:[ODataRegex any:ODataRegexAnyCharacter]];
    } else {
      if (c == '\\' && ![self atEnd]) c = [self next];
      [parts addObject:[ODataRegex literal:c]];
    }
  }
  return [ODataRegex sequence:parts];
}

#pragma mark Regular expressions

- (ODataRegex *)read
{
  ODataRegex *r = [self readAlternation];
  if (!r) return nil;
  if (![self atEnd]) return [self syntax:@"an unbalanced )"];
  return r;
}

- (ODataRegex *)readAlternation
{
  NSMutableArray *parts = [NSMutableArray array];
  do {
    ODataRegex *sequence = [self readSequence];
    if (!sequence) return nil;
    [parts addObject:sequence];
  } while ([self accept:'|']);
  return parts.count == 1 ? parts[0] : [ODataRegex alternation:parts];
}

- (ODataRegex *)readSequence
{
  NSMutableArray *parts = [NSMutableArray array];
  while (![self atEnd] && [self peek:0] != '|' && [self peek:0] != ')') {
    ODataRegex *piece = [self readPiece];
    if (!piece) return nil;
    // A leading (?s) is read as nothing: MATCHES has "." take everything.
    if (piece.kind == ODataRegexSequence && !piece.parts.count) continue;
    [parts addObject:piece];
  }
  return parts.count == 1 ? parts[0] : [ODataRegex sequence:parts];
}

// {n}, {n,}, {n,m}: YES with the bounds read; NO, reading nothing, when
// what follows is not one.
- (BOOL)readBoundsMinimum:(NSUInteger *)minimum maximum:(NSUInteger *)maximum
{
  if ([self peek:0] != '{') return NO;
  NSUInteger i = 1, low = 0, high = NSNotFound;
  BOOL digits = NO;
  UTF32Char c;
  while ((c = [self peek:i]) >= '0' && c <= '9') {
    low = MIN(low * 10 + (c - '0'), (NSUInteger)1000000);
    digits = YES;
    i++;
  }
  if (!digits) return NO;
  if ([self peek:i] == ',') {
    i++;
    BOOL more = NO;
    NSUInteger h = 0;
    while ((c = [self peek:i]) >= '0' && c <= '9') {
      h = MIN(h * 10 + (c - '0'), (NSUInteger)1000000);
      more = YES;
      i++;
    }
    if (more) high = h;
  } else {
    high = low;
  }
  if ([self peek:i] != '}') return NO;
  _at += i + 1;
  *minimum = low;
  *maximum = high;
  return YES;
}

- (ODataRegex *)readPiece
{
  ODataRegex *atom = [self readAtom];
  if (!atom) return nil;
  NSUInteger minimum = 0, maximum = NSNotFound;
  UTF32Char c = [self peek:0];
  if ([self atEnd]) return atom;
  if (c == '*') {
    _at++;
  } else if (c == '+') {
    _at++;
    minimum = 1;
  } else if (c == '?') {
    _at++;
    maximum = 1;
  } else if (![self readBoundsMinimum:&minimum maximum:&maximum]) {
    return atom;
  }
  if (maximum != NSNotFound && maximum < minimum) return [self syntax:@"a repeat whose maximum is below its minimum"];
  if (atom.kind == ODataRegexAnchor || (atom.kind == ODataRegexSequence && !atom.parts.count)) return [self syntax:@"nothing to repeat"];
  BOOL lazy = [self accept:'?'];
  if ([self matches] && !lazy && [self peek:0] == '+') return [self unsupported:@"possessive repeats are ICU's own"];
  UTF32Char after = [self peek:0];
  if (![self atEnd] && (after == '*' || after == '+' || after == '?')) return [self syntax:@"a repeat of a repeat"];
  return [ODataRegex repeat:atom minimum:minimum maximum:maximum lazy:lazy];
}

- (ODataRegex *)readAtom
{
  UTF32Char c = [self next];
  switch (c) {
    case '(': return [self readGroup];
    case '[': return [self readSet];
    case '.': return [ODataRegex any:[self matches] ? ODataRegexAnyCharacter : ODataRegexAnyButLineTerminator];
    case '^':
      return [ODataRegex anchor:_lines ? ODataRegexStartOfLine : ODataRegexStartOfText unicode:NO];
    case '$':
      if (![self matches]) return [ODataRegex anchor:ODataRegexEndOfText unicode:NO];
      return [ODataRegex anchor:_lines ? ODataRegexEndOfLine : ODataRegexEndOfTextOrLine unicode:NO];
    case '\\':
      if ([self atEnd]) return [self syntax:@"a pattern that ends in a backslash"];
      return [self readEscape];
    case '*':
    case '+':
    case '?':
      return [self syntax:@"nothing to repeat"];
    case '{': {
      _at--;
      NSUInteger low, high;
      if ([self readBoundsMinimum:&low maximum:&high]) return [self syntax:@"nothing to repeat"];
      _at++;
      // ECMAScript takes a { that starts no repeat as itself; ICU does not.
      if ([self matches]) return [self syntax:@"a { that starts no repeat"];
      return [ODataRegex literal:c];
    }
    default:
      return [ODataRegex literal:c];
  }
}

- (ODataRegex *)readGroup
{
  BOOL capturing = YES, look = NO, behind = NO, negated = NO;
  if ([self accept:'?']) {
    capturing = NO;
    UTF32Char c = [self atEnd] ? 0 : [self next];
    if (c == ':') {
    } else if (c == '=' || c == '!') {
      look = YES;
      negated = c == '!';
    } else if (c == '<' && ([self peek:0] == '=' || [self peek:0] == '!')) {
      look = YES;
      behind = YES;
      negated = [self next] == '!';
    } else if (c == '<') {
      // A named group: captured, its name aside.
      while (![self atEnd] && [self peek:0] != '>') _at++;
      if (![self accept:'>']) return [self syntax:@"a group name with no >"];
      capturing = YES;
    } else if ([self matches] && c == 's' && ([self peek:0] == ')' || [self peek:0] == ':')) {
      // (?s): "." takes line terminators, which in MATCHES it does anyway.
      if ([self accept:')']) return [ODataRegex sequence:@[]];
      _at++;
    } else if ([self matches]) {
      return [self unsupported:@"inline flags, atomic groups and comments are ICU's own"];
    } else {
      return [self syntax:@"(? that starts no group"];
    }
  }
  ODataRegex *inner = [self readAlternation];
  if (!inner) return nil;
  if (![self accept:')']) return [self syntax:@"a group with no )"];
  if (look) return [ODataRegex look:inner behind:behind negated:negated];
  return [ODataRegex group:inner capturing:capturing];
}

// A hexadecimal number of so many digits (or, with braces where ICU takes
// them, of any); NO when there are not.
- (BOOL)readHex:(NSUInteger)digits into:(UTF32Char *)value
{
  UTF32Char v = 0;
  BOOL braces = [self matches] && [self peek:0] == '{';
  if (braces) _at++;
  NSUInteger count = 0;
  while (braces ? [self peek:0] != '}' : count < digits) {
    UTF32Char c = [self atEnd] ? 0 : [self peek:0];
    int d = (c >= '0' && c <= '9') ? (int)(c - '0') : (c >= 'a' && c <= 'f') ? (int)(c - 'a' + 10) : (c >= 'A' && c <= 'F') ? (int)(c - 'A' + 10) : -1;
    if (d < 0 || count >= 8) return NO;
    v = v * 16 + (UTF32Char)d;
    _at++;
    count++;
  }
  if (braces && (!count || ![self accept:'}'])) return NO;
  if (v > 0x10FFFF) return NO;
  *value = v;
  return YES;
}

// The character an escape stands for, where it is one; 0x110000 where it
// is not (a class, an anchor), with nothing read.
- (UTF32Char)readCharacterEscape:(UTF32Char)c inSet:(BOOL)inSet
{
  switch (c) {
    case 'n': return '\n';
    case 'r': return '\r';
    case 't': return '\t';
    case 'f': return '\f';
    case 'v':
      if ([self matches]) return 0x110000;  // ICU's \v is a class of vertical space
      return 0x0B;
    case 'a': return [self matches] ? 0x07 : 0x110000;
    case 'e': return [self matches] ? 0x1B : 0x110000;
    case 'b': return inSet && ![self matches] ? 0x08 : 0x110000;
    case '0': {
      if (![self matches]) return ([self peek:0] >= '0' && [self peek:0] <= '9') ? 0x110000 : 0;
      UTF32Char v = 0;
      for (int i = 0; i < 3 && [self peek:0] >= '0' && [self peek:0] <= '7'; i++) v = v * 8 + ([self next] - '0');
      return v;
    }
    case 'x': {
      UTF32Char v;
      NSUInteger at = _at;
      if ([self readHex:2 into:&v]) return v;
      _at = at;
      return 0x110001;
    }
    case 'u': {
      UTF32Char v;
      NSUInteger at = _at;
      if (![self readHex:4 into:&v]) {
        _at = at;
        return 0x110001;
      }
      // A surrogate pair written as two escapes is one character.
      if (v >= 0xD800 && v <= 0xDBFF && [self peek:0] == '\\' && [self peek:1] == 'u') {
        NSUInteger pairAt = _at;
        _at += 2;
        UTF32Char low;
        if ([self readHex:4 into:&low] && low >= 0xDC00 && low <= 0xDFFF) return 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00);
        _at = pairAt;
      }
      return v;
    }
    case 'U': {
      UTF32Char v;
      if ([self matches] && [self readHex:8 into:&v]) return v;
      return 0x110001;
    }
    case 'c': {
      UTF32Char letter = [self peek:0];
      if ((letter >= 'a' && letter <= 'z') || (letter >= 'A' && letter <= 'Z')) {
        _at++;
        return letter % 32;
      }
      return 0x110001;
    }
    default: break;
  }
  BOOL alphanumeric = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
  return alphanumeric ? 0x110000 : c;
}

- (ODataRegexMember *)classEscape:(UTF32Char)c
{
  BOOL unicode = [self matches];
  switch (c) {
    case 'd': return [ODataRegexMember classOf:ODataRegexDigits unicode:unicode negated:NO];
    case 'D': return [ODataRegexMember classOf:ODataRegexDigits unicode:unicode negated:YES];
    case 'w': return [ODataRegexMember classOf:ODataRegexWordCharacters unicode:unicode negated:NO];
    case 'W': return [ODataRegexMember classOf:ODataRegexWordCharacters unicode:unicode negated:YES];
    case 's': return [ODataRegexMember classOf:ODataRegexSpaces unicode:unicode negated:NO];
    case 'S': return [ODataRegexMember classOf:ODataRegexSpaces unicode:unicode negated:YES];
    default: return nil;
  }
}

- (ODataRegex *)readEscape
{
  UTF32Char c = [self next];
  ODataRegexMember *member = [self classEscape:c];
  if (member) return [ODataRegex set:@[ member ] negated:NO];
  if (c == 'b' || c == 'B') {
    return [ODataRegex anchor:c == 'b' ? ODataRegexWordBoundary : ODataRegexNotWordBoundary unicode:[self matches]];
  }
  if ([self matches]) {
    if (c == 'A') return [ODataRegex anchor:ODataRegexStartOfText unicode:NO];
    if (c == 'z') return [ODataRegex anchor:ODataRegexEndOfText unicode:NO];
    if (c == 'Z') return [ODataRegex anchor:ODataRegexEndOfTextOrLine unicode:NO];
    if (c == 'Q') {
      NSMutableArray *parts = [NSMutableArray array];
      while (![self atEnd] && !([self peek:0] == '\\' && [self peek:1] == 'E')) [parts addObject:[ODataRegex literal:[self next]]];
      if (![self atEnd]) _at += 2;
      return [ODataRegex sequence:parts];
    }
  }
  if (c >= '1' && c <= '9') return [self unsupported:@"back references"];
  UTF32Char value = [self readCharacterEscape:c inSet:NO];
  if (value == 0x110001) return [self syntax:[NSString stringWithFormat:@"\\%@ with no character after it", OISCharacterString(c)]];
  if (value == 0x110000) return [self unsupported:[NSString stringWithFormat:@"\\%@", OISCharacterString(c)]];
  return [ODataRegex literal:value];
}

- (ODataRegex *)readSet
{
  BOOL negated = [self accept:'^'];
  NSMutableArray *members = [NSMutableArray array];
  BOOL first = YES;
  while (YES) {
    if ([self atEnd]) return [self syntax:@"a [ with no ]"];
    UTF32Char c = [self next];
    // ECMAScript's [] is empty; ICU takes a ] first as a member.
    if (c == ']' && !(first && [self matches])) break;
    first = NO;
    if ([self matches] && c == '[') return [self unsupported:@"sets within sets are ICU's own"];
    if ([self matches] && (c == '&' || c == '-') && [self peek:0] == c) return [self unsupported:@"set operations are ICU's own"];
    ODataRegexMember *low = [self readSetMember:c];
    if (!low) return nil;
    if (!low.isClass && [self peek:0] == '-' && [self peek:1] != ']' && _at + 1 < _length) {
      _at++;
      ODataRegexMember *high = [self readSetMember:[self next]];
      if (!high) return nil;
      if (high.isClass) return [self unsupported:@"a range to a class"];
      if (high.first < low.first) return [self syntax:@"a range whose end is before its start"];
      [members addObject:[ODataRegexMember rangeFrom:low.first to:high.first]];
      continue;
    }
    [members addObject:low];
  }
  return [ODataRegex set:members negated:negated];
}

- (ODataRegexMember *)readSetMember:(UTF32Char)c
{
  if (c != '\\') return [ODataRegexMember rangeFrom:c to:c];
  if ([self atEnd]) return [self syntax:@"a set that ends in a backslash"];
  c = [self next];
  ODataRegexMember *member = [self classEscape:c];
  if (member) return member;
  if ([self matches] && (c == 'p' || c == 'P')) return [self unsupported:@"\\p and \\P"];
  UTF32Char value = [self readCharacterEscape:c inSet:YES];
  if (value == 0x110001) return [self syntax:[NSString stringWithFormat:@"\\%@ with no character after it", OISCharacterString(c)]];
  if (value == 0x110000) return [self unsupported:[NSString stringWithFormat:@"\\%@ in a set", OISCharacterString(c)]];
  return [ODataRegexMember rangeFrom:value to:value];
}

@end

#pragma mark - Writing

// ECMAScript's white space and line terminators, for \s.
static NSString * const OISECMAScriptSpaces = @"\t\n\x0B\f\r \u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF";

@interface OISRegexWriter : NSObject {
 @public
  ODataRegexDialect _dialect;
  NSMutableString *_out;
  NSError *_error;
}
@end

@implementation OISRegexWriter

- (BOOL)fail:(NSString *)message
{
  if (!_error) _error = OISRegexUnsupported(message);
  return NO;
}

- (BOOL)ecma
{
  return _dialect == ODataRegexECMAScript;
}

- (void)character:(UTF32Char)c inSet:(BOOL)inSet
{
  NSString *special = inSet ? ([self ecma] ? @"\\]^-[" : @"\\]^-[&") : ([self ecma] ? @"\\^$.|?*+()[]{}/" : @"\\^$.|?*+()[]{}");
  switch (c) {
    case '\n': [_out appendString:@"\\n"]; return;
    case '\r': [_out appendString:@"\\r"]; return;
    case '\t': [_out appendString:@"\\t"]; return;
    case '\f': [_out appendString:@"\\f"]; return;
    default: break;
  }
  if (c < 0x20 || c == 0x7F) {
    [_out appendFormat:[self ecma] ? @"\\x%02X" : @"\\x{%02X}", (unsigned)c];
    return;
  }
  if ([self ecma] && (c == 0x2028 || c == 0x2029)) {
    [_out appendFormat:@"\\u%04X", (unsigned)c];
    return;
  }
  if (c < 128 && [special rangeOfString:OISCharacterString(c)].location != NSNotFound) [_out appendString:@"\\"];
  [_out appendString:OISCharacterString(c)];
}

- (BOOL)classMember:(ODataRegexMember *)m standalone:(BOOL)standalone
{
  static const char *letters[] = { "d", "w", "s" };
  const char *letter = letters[m.classKind];
  if ([self ecma]) {
    if (m.unicode) return [self fail:@"Unicode \\d, \\w and \\s: ECMAScript's are ASCII"];
    [_out appendFormat:@"\\%c", m.negated ? (char)(letter[0] - 32) : letter[0]];
    return YES;
  }
  if (m.unicode) {
    [_out appendFormat:@"\\%c", m.negated ? (char)(letter[0] - 32) : letter[0]];
    return YES;
  }
  NSString *ascii = m.classKind == ODataRegexDigits ? @"0-9" : m.classKind == ODataRegexWordCharacters ? @"A-Za-z0-9_" : OISECMAScriptSpaces;
  if (standalone) [_out appendFormat:@"[%@%@]", m.negated ? @"^" : @"", ascii];
  else if (m.negated) [_out appendFormat:@"[^%@]", ascii];  // a set within the set
  else [_out appendString:ascii];
  return YES;
}

- (BOOL)set:(ODataRegex *)r
{
  if (!r.members.count) {
    // [] matches nothing; [^] any one character.
    if (r.negated) return [self any:ODataRegexAnyCodePoint];
    [_out appendString:@"(?!)"];
    return YES;
  }
  if (r.members.count == 1 && r.members[0].isClass && !r.negated) return [self classMember:r.members[0] standalone:YES];
  [_out appendString:r.negated ? @"[^" : @"["];
  for (ODataRegexMember *m in r.members) {
    if (m.isClass) {
      if (![self classMember:m standalone:NO]) return NO;
      continue;
    }
    if ([self ecma] && m.last > 0xFFFF) return [self fail:@"a character beyond U+FFFF in a set: ECMAScript's sets are of UTF-16 code units"];
    [self character:m.first inSet:YES];
    if (m.last != m.first) {
      [_out appendString:@"-"];
      [self character:m.last inSet:YES];
    }
  }
  [_out appendString:@"]"];
  return YES;
}

- (BOOL)any:(ODataRegexAnyKind)kind
{
  switch (kind) {
    case ODataRegexAnyCharacter:
      [_out appendString:[self ecma] ? @"(?:\\r\\n|\\r(?!\\n)|[^\\r])" : @"."];
      return YES;
    case ODataRegexAnyButLineTerminator:
      [_out appendString:[self ecma] ? @"." : @"[^\\n\\r\u2028\u2029]"];
      return YES;
    case ODataRegexAnyCodePoint:
      [_out appendString:[self ecma] ? @"[\\s\\S]" : @"(?:[^\\r]|\\r)"];
      return YES;
  }
  return NO;
}

- (BOOL)anchor:(ODataRegex *)r
{
  static NSString *const asciiWord = @"[A-Za-z0-9_]";
  switch (r.anchor) {
    case ODataRegexStartOfText: [_out appendString:[self ecma] ? @"^" : @"\\A"]; return YES;
    case ODataRegexEndOfText: [_out appendString:[self ecma] ? @"$" : @"\\z"]; return YES;
    case ODataRegexEndOfTextOrLine:
      [_out appendString:[self ecma] ? @"(?=(?:\\r\\n|[\\n\\x0B\\f\\r\\x85\\u2028\\u2029])?$)" : @"\\Z"];
      return YES;
    case ODataRegexStartOfLine:
    case ODataRegexEndOfLine:
      if ([self ecma]) return [self fail:@"^ and $ at each line: OData's ECMAScript patterns have them at the ends only"];
      [_out appendString:r.anchor == ODataRegexStartOfLine ? @"(?m:^)" : @"(?m:$)"];
      return YES;
    case ODataRegexWordBoundary:
    case ODataRegexNotWordBoundary: {
      BOOL boundary = r.anchor == ODataRegexWordBoundary;
      if (r.unicode == ![self ecma]) {
        [_out appendString:boundary ? @"\\b" : @"\\B"];
        return YES;
      }
      if ([self ecma]) return [self fail:@"a Unicode word boundary: ECMAScript's \\b is of ASCII word characters"];
      NSString *shape = boundary ? @"(?:(?<=W)(?!W)|(?<!W)(?=W))" : @"(?:(?<=W)(?=W)|(?<!W)(?!W))";
      [_out appendString:[shape stringByReplacingOccurrencesOfString:@"W" withString:asciiWord]];
      return YES;
    }
  }
  return NO;
}

// A part of a sequence or a repeat, grouped where it would otherwise not
// hold together.
- (BOOL)write:(ODataRegex *)r groupedFor:(ODataRegexKind)outer
{
  BOOL group = NO;
  switch (r.kind) {
    case ODataRegexAlternation: group = YES; break;
    case ODataRegexSequence: group = outer == ODataRegexRepeat ? r.parts.count != 1 : NO; break;
    case ODataRegexRepeat:
    case ODataRegexAnchor:
      group = outer == ODataRegexRepeat;
      break;
    default: break;
  }
  if (group) [_out appendString:@"(?:"];
  if (![self write:r]) return NO;
  if (group) [_out appendString:@")"];
  return YES;
}

- (BOOL)write:(ODataRegex *)r
{
  switch (r.kind) {
    case ODataRegexSequence:
      for (ODataRegex *part in r.parts) {
        if (![self write:part groupedFor:ODataRegexSequence]) return NO;
      }
      return YES;
    case ODataRegexAlternation:
      if (!r.parts.count) {
        [_out appendString:@"(?!)"];
        return YES;
      }
      for (NSUInteger i = 0; i < r.parts.count; i++) {
        if (i) [_out appendString:@"|"];
        if (![self write:r.parts[i]]) return NO;
      }
      return YES;
    case ODataRegexLiteral:
      [self character:r.character inSet:NO];
      return YES;
    case ODataRegexAny: return [self any:r.any];
    case ODataRegexSet: return [self set:r];
    case ODataRegexAnchor: return [self anchor:r];
    case ODataRegexGroup:
      [_out appendString:r.capturing ? @"(" : @"(?:"];
      if (![self write:r.part]) return NO;
      [_out appendString:@")"];
      return YES;
    case ODataRegexLook:
      [_out appendString:r.behind ? (r.negated ? @"(?<!" : @"(?<=") : (r.negated ? @"(?!" : @"(?=")];
      if (![self write:r.part]) return NO;
      [_out appendString:@")"];
      return YES;
    case ODataRegexRepeat: {
      if (![self write:r.part groupedFor:ODataRegexRepeat]) return NO;
      NSUInteger lo = r.minimum, hi = r.maximum;
      if (lo == 0 && hi == NSNotFound) [_out appendString:@"*"];
      else if (lo == 1 && hi == NSNotFound) [_out appendString:@"+"];
      else if (lo == 0 && hi == 1) [_out appendString:@"?"];
      else if (hi == NSNotFound) [_out appendFormat:@"{%lu,}", (unsigned long)lo];
      else if (lo == hi) [_out appendFormat:@"{%lu}", (unsigned long)lo];
      else [_out appendFormat:@"{%lu,%lu}", (unsigned long)lo, (unsigned long)hi];
      if (r.lazy) [_out appendString:@"?"];
      return YES;
    }
  }
  return NO;
}

// LIKE: literals, and any character, alone (?) or any run of them (*).
- (BOOL)writeLike:(ODataRegex *)r
{
  if (r.kind == ODataRegexSequence) {
    for (ODataRegex *part in r.parts) {
      if (![self writeLike:part]) return NO;
    }
    return YES;
  }
  if (r.kind == ODataRegexLiteral) {
    if (r.character == '*' || r.character == '?' || r.character == '\\') [_out appendString:@"\\"];
    [_out appendString:OISCharacterString(r.character)];
    return YES;
  }
  if (r.kind == ODataRegexAny && r.any == ODataRegexAnyCharacter) {
    [_out appendString:@"?"];
    return YES;
  }
  if (r.kind == ODataRegexRepeat && r.minimum == 0 && r.maximum == NSNotFound && !r.lazy && r.part.kind == ODataRegexAny &&
      r.part.any == ODataRegexAnyCharacter) {
    [_out appendString:@"*"];
    return YES;
  }
  return [self fail:@"LIKE has only * and ?"];
}

@end

#pragma mark - The tree

@implementation ODataRegex

+ (instancetype)node:(ODataRegexKind)kind
{
  ODataRegex *r = [[self alloc] init];
  r.kind = kind;
  r.parts = @[];
  r.members = @[];
  return r;
}

+ (instancetype)regexWithString:(NSString *)pattern dialect:(ODataRegexDialect)dialect error:(NSError **)error
{
  OISRegexReader *reader = [[OISRegexReader alloc] initWithString:pattern ?: @"" dialect:dialect];
  ODataRegex *r = dialect == ODataRegexLike ? [reader readLike] : [reader read];
  if (!r && error) *error = reader->_error ?: OISRegexSyntax(@"not a pattern");
  return r;
}

- (NSString *)stringInDialect:(ODataRegexDialect)dialect error:(NSError **)error
{
  OISRegexWriter *writer = [[OISRegexWriter alloc] init];
  writer->_dialect = dialect;
  writer->_out = [NSMutableString string];
  BOOL written = dialect == ODataRegexLike ? [writer writeLike:self] : [writer write:self];
  if (!written) {
    if (error) *error = writer->_error;
    return nil;
  }
  return writer->_out;
}

+ (NSString *)matchesPatternFindingECMAScript:(NSString *)pattern error:(NSError **)error
{
  ODataRegex *r = [self regexWithString:pattern dialect:ODataRegexECMAScript error:error];
  return [[r anywhere] stringInDialect:ODataRegexMatches error:error];
}

+ (BOOL)matchesAnchorsMatchLines
{
  static BOOL lines;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lines = [[NSPredicate predicateWithFormat:@"SELF MATCHES %@", @".*^b"] evaluateWithObject:@"a\nb"];
  });
  return lines;
}

+ (instancetype)sequence:(NSArray<ODataRegex *> *)parts
{
  ODataRegex *r = [self node:ODataRegexSequence];
  r.parts = parts;
  return r;
}

+ (instancetype)alternation:(NSArray<ODataRegex *> *)parts
{
  ODataRegex *r = [self node:ODataRegexAlternation];
  r.parts = parts;
  return r;
}

+ (instancetype)literal:(UTF32Char)character
{
  ODataRegex *r = [self node:ODataRegexLiteral];
  r.character = character;
  return r;
}

+ (instancetype)literalString:(NSString *)text
{
  OISRegexReader *reader = [[OISRegexReader alloc] initWithString:text dialect:ODataRegexLike];
  NSMutableArray *parts = [NSMutableArray array];
  while (![reader atEnd]) [parts addObject:[self literal:[reader next]]];
  return parts.count == 1 ? parts[0] : [self sequence:parts];
}

+ (instancetype)any:(ODataRegexAnyKind)kind
{
  ODataRegex *r = [self node:ODataRegexAny];
  r.any = kind;
  return r;
}

+ (instancetype)set:(NSArray<ODataRegexMember *> *)members negated:(BOOL)negated
{
  ODataRegex *r = [self node:ODataRegexSet];
  r.members = members;
  r.negated = negated;
  return r;
}

+ (instancetype)anchor:(ODataRegexAnchorKind)kind unicode:(BOOL)unicode
{
  ODataRegex *r = [self node:ODataRegexAnchor];
  r.anchor = kind;
  r.unicode = unicode;
  return r;
}

+ (instancetype)group:(ODataRegex *)part capturing:(BOOL)capturing
{
  ODataRegex *r = [self node:ODataRegexGroup];
  r.part = part;
  r.capturing = capturing;
  return r;
}

+ (instancetype)look:(ODataRegex *)part behind:(BOOL)behind negated:(BOOL)negated
{
  ODataRegex *r = [self node:ODataRegexLook];
  r.part = part;
  r.behind = behind;
  r.negated = negated;
  return r;
}

+ (instancetype)repeat:(ODataRegex *)part minimum:(NSUInteger)minimum maximum:(NSUInteger)maximum lazy:(BOOL)lazy
{
  ODataRegex *r = [self node:ODataRegexRepeat];
  r.part = part;
  r.minimum = minimum;
  r.maximum = maximum;
  r.lazy = lazy;
  return r;
}

- (ODataRegex *)whole
{
  // Anchored once: where the pattern starts or ends so already, not again.
  NSMutableArray *parts = [NSMutableArray arrayWithArray:self.kind == ODataRegexSequence ? self.parts : @[ self ]];
  ODataRegex *first = parts.firstObject, *last = parts.lastObject;
  if (!(first.kind == ODataRegexAnchor && first.anchor == ODataRegexStartOfText)) {
    [parts insertObject:[ODataRegex anchor:ODataRegexStartOfText unicode:NO] atIndex:0];
  }
  if (!(last.kind == ODataRegexAnchor && last.anchor == ODataRegexEndOfText)) {
    [parts addObject:[ODataRegex anchor:ODataRegexEndOfText unicode:NO]];
  }
  return [ODataRegex sequence:parts];
}

- (ODataRegex *)anywhere
{
  ODataRegex *anything = [ODataRegex repeat:[ODataRegex any:ODataRegexAnyCodePoint] minimum:0 maximum:NSNotFound lazy:NO];
  return [ODataRegex sequence:@[ anything, [ODataRegex group:self capturing:NO], anything ]];
}

- (ODataRegex *)regexReplacing:(ODataRegex *(^)(ODataRegex *))block
{
  ODataRegex *copy = [ODataRegex node:self.kind];
  copy.character = self.character;
  copy.any = self.any;
  copy.members = self.members;
  copy.negated = self.negated;
  copy.anchor = self.anchor;
  copy.unicode = self.unicode;
  copy.capturing = self.capturing;
  copy.behind = self.behind;
  copy.minimum = self.minimum;
  copy.maximum = self.maximum;
  copy.lazy = self.lazy;
  NSMutableArray *parts = [NSMutableArray array];
  for (ODataRegex *part in self.parts) [parts addObject:[part regexReplacing:block]];
  copy.parts = parts;
  copy.part = [self.part regexReplacing:block];
  return block(copy) ?: copy;
}

- (NSString *)description
{
  NSError *error = nil;
  return [self stringInDialect:ODataRegexMatches error:&error] ?: [NSString stringWithFormat:@"<%@>", error.localizedDescription];
}

@end
