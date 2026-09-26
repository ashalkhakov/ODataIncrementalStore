// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataValue.h"
#include <math.h>

NSString * const ODataUserInfoType = @"OData.type";

#pragma mark - Calendar arithmetic

// Days since 1970-01-01 of a proleptic Gregorian date, and back (Howard
// Hinnant's algorithms). Done by hand rather than with NSDateFormatter or
// NSCalendar, so both platforms read and write dates the same way, in UTC,
// whatever the locale.
static int64_t OISDaysFromCivil(int64_t y, unsigned m, unsigned d)
{
  y -= m <= 2;
  int64_t era = (y >= 0 ? y : y - 399) / 400;
  unsigned yoe = (unsigned)(y - era * 400);
  unsigned doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
  unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + (int64_t)doe - 719468;
}

static void OISCivilFromDays(int64_t z, int64_t *year, unsigned *month, unsigned *day)
{
  z += 719468;
  int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  unsigned doe = (unsigned)(z - era * 146097);
  unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  unsigned mp = (5 * doy + 2) / 153;
  *day = doy - (153 * mp + 2) / 5 + 1;
  *month = mp < 10 ? mp + 3 : mp - 9;
  *year = (int64_t)yoe + era * 400 + (*month <= 2);
}

// Reads `count` digits (count 0: one or more) into *value.
static BOOL OISDigits(const char **p, int count, int64_t *value)
{
  int64_t v = 0;
  int n = 0;
  while (**p >= '0' && **p <= '9' && (count == 0 || n < count)) {
    v = v * 10 + (**p - '0');
    (*p)++;
    n++;
  }
  *value = v;
  return count ? n == count : n > 0;
}

static BOOL OISExpect(const char **p, char c)
{
  if (**p != c) return NO;
  (*p)++;
  return YES;
}

// A number without exponent notation or locale: 0.1 is "0.1", not
// "0.10000000000000001" or "1e-01".
static NSString *OISDoubleString(double x)
{
  NSString *s = nil;
  for (int precision = 15; precision <= 17; precision++) {
    s = [NSString stringWithFormat:@"%.*g", precision, x];
    if ([s doubleValue] == x) break;
  }
  return s;
}

// A decimal written out in full. gnustep-base writes large and small
// NSDecimalNumbers with an exponent (1E-10, 1.23E19) where Apple does not,
// and a decimal must not have one in a payload unless the payload says so
// (JSON Format section 24, 9d) - nor, in OData 4.0, in a URL literal.
static NSString *OISPlainDecimalString(NSDecimalNumber *number)
{
  NSString *s = number.stringValue;
  NSRange e = [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"eE"]];
  if (e.location == NSNotFound) return s;
  NSInteger exponent = [[s substringFromIndex:e.location + 1] integerValue];
  NSString *mantissa = [s substringToIndex:e.location];
  NSString *sign = [mantissa hasPrefix:@"-"] ? @"-" : @"";
  if (sign.length) mantissa = [mantissa substringFromIndex:1];
  NSRange dot = [mantissa rangeOfString:@"."];
  NSInteger point = dot.location == NSNotFound ? (NSInteger)mantissa.length : (NSInteger)dot.location;
  NSString *digits = [mantissa stringByReplacingOccurrencesOfString:@"." withString:@""];
  point += exponent;
  NSMutableString *out = [NSMutableString stringWithString:sign];
  if (point <= 0) {
    [out appendString:@"0."];
    for (NSInteger i = 0; i < -point; i++) [out appendString:@"0"];
    [out appendString:digits];
  } else if (point >= (NSInteger)digits.length) {
    [out appendString:digits];
    for (NSInteger i = digits.length; i < point; i++) [out appendString:@"0"];
  } else {
    [out appendFormat:@"%@.%@", [digits substringToIndex:point], [digits substringFromIndex:point]];
  }
  return out;
}

#pragma mark - Textual forms

// dateValue / dateTimeOffsetValue (Part 2 ABNF): 2024-03-01, or
// 2024-03-01T12:34[:56[.1234567]] with Z or an offset such as +02:00.
NSDate *ODataDateFromString(NSString *string)
{
  const char *p = string.UTF8String;
  if (!p) return nil;
  int64_t sign = OISExpect(&p, '-') ? -1 : 1;
  int64_t year, month, day;
  const char *start = p;
  if (!OISDigits(&p, 0, &year) || p - start < 4) return nil;
  if (!OISExpect(&p, '-') || !OISDigits(&p, 2, &month) || !OISExpect(&p, '-') || !OISDigits(&p, 2, &day)) return nil;
  if (month < 1 || month > 12 || day < 1 || day > 31) return nil;
  double seconds = (double)OISDaysFromCivil(sign * year, (unsigned)month, (unsigned)day) * 86400.0;
  if (*p == 0) return [NSDate dateWithTimeIntervalSince1970:seconds];

  int64_t hour, minute, second = 0;
  if (!OISExpect(&p, 'T') && !OISExpect(&p, 't')) return nil;
  if (!OISDigits(&p, 2, &hour) || !OISExpect(&p, ':') || !OISDigits(&p, 2, &minute)) return nil;
  double fraction = 0;
  if (OISExpect(&p, ':')) {
    if (!OISDigits(&p, 2, &second)) return nil;
    if (OISExpect(&p, '.')) {
      double scale = 0.1;
      if (!(*p >= '0' && *p <= '9')) return nil;
      while (*p >= '0' && *p <= '9') {
        fraction += (*p - '0') * scale;
        scale /= 10;
        p++;
      }
    }
  }
  if (hour > 23 || minute > 59 || second > 60) return nil;
  seconds += hour * 3600.0 + minute * 60.0 + second + fraction;
  if (OISExpect(&p, 'Z') || OISExpect(&p, 'z')) {
    // UTC
  } else if (*p == '+' || *p == '-') {
    int64_t offsetSign = *p == '-' ? -1 : 1, offsetHour, offsetMinute;
    p++;
    if (!OISDigits(&p, 2, &offsetHour) || !OISExpect(&p, ':') || !OISDigits(&p, 2, &offsetMinute)) return nil;
    seconds -= offsetSign * (offsetHour * 3600.0 + offsetMinute * 60.0);
  } else {
    return nil;
  }
  return *p == 0 ? [NSDate dateWithTimeIntervalSince1970:seconds] : nil;
}

static NSString *OISYear(int64_t year)
{
  return year < 0 ? [NSString stringWithFormat:@"-%04lld", (long long)-year]
                  : [NSString stringWithFormat:@"%04lld", (long long)year];
}

NSString *ODataDateTimeOffsetString(NSDate *date)
{
  double t = date.timeIntervalSince1970;
  double whole = floor(t);
  // Microseconds: what a double holds of a present-day date, and more than
  // most services keep.
  long long micros = llround((t - whole) * 1e6);
  if (micros >= 1000000) {
    whole += 1;
    micros -= 1000000;
  }
  int64_t days = (int64_t)floor(whole / 86400.0);
  int64_t secs = (int64_t)whole - days * 86400;
  int64_t year;
  unsigned month, day;
  OISCivilFromDays(days, &year, &month, &day);
  NSMutableString *out = [NSMutableString stringWithFormat:@"%@-%02u-%02uT%02lld:%02lld:%02lld", OISYear(year), month, day,
                                                           (long long)(secs / 3600), (long long)(secs / 60 % 60), (long long)(secs % 60)];
  if (micros) {
    NSString *fraction = [NSString stringWithFormat:@"%06lld", micros];
    while ([fraction hasSuffix:@"0"]) fraction = [fraction substringToIndex:fraction.length - 1];
    [out appendFormat:@".%@", fraction];
  }
  [out appendString:@"Z"];
  return out;
}

NSString *ODataDateString(NSDate *date)
{
  int64_t days = (int64_t)floor(date.timeIntervalSince1970 / 86400.0);
  int64_t year;
  unsigned month, day;
  OISCivilFromDays(days, &year, &month, &day);
  return [NSString stringWithFormat:@"%@-%02u-%02u", OISYear(year), month, day];
}

// durationValue: [-]P[nD][T[nH][nM][n[.n]S]]
NSNumber *ODataDurationFromString(NSString *string)
{
  const char *p = string.UTF8String;
  if (!p) return nil;
  double sign = OISExpect(&p, '-') ? -1 : 1;
  if (!OISExpect(&p, 'P')) return nil;
  double total = 0;
  BOOL time = NO, any = NO;
  while (*p) {
    if (OISExpect(&p, 'T')) {
      if (time) return nil;
      time = YES;
      continue;
    }
    const char *numberStart = p;
    while ((*p >= '0' && *p <= '9') || *p == '.') p++;
    if (p == numberStart) return nil;
    double n = [[[NSString alloc] initWithBytes:numberStart length:(NSUInteger)(p - numberStart) encoding:NSASCIIStringEncoding] doubleValue];
    char unit = *p++;
    if (unit == 'D' && !time) total += n * 86400;
    else if (unit == 'H' && time) total += n * 3600;
    else if (unit == 'M' && time) total += n * 60;
    else if (unit == 'S' && time) total += n;
    else return nil;
    any = YES;
  }
  return any ? @(sign * total) : nil;
}

NSString *ODataDurationString(double seconds)
{
  NSString *sign = seconds < 0 ? @"-" : @"";
  return [NSString stringWithFormat:@"%@PT%@S", sign, OISDoubleString(fabs(seconds))];
}

// binaryValue is base64url (RFC 4648 section 5). Some services, Northwind
// among them, send plain base64; both read.
NSData *ODataDataFromBase64(NSString *string)
{
  NSMutableString *s = [[string stringByReplacingOccurrencesOfString:@"-" withString:@"+"] mutableCopy];
  [s replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, s.length)];
  while (s.length % 4) [s appendString:@"="];
  return [[NSData alloc] initWithBase64EncodedString:s options:NSDataBase64DecodingIgnoreUnknownCharacters];
}

NSString *ODataBase64URLString(NSData *data)
{
  NSMutableString *s = [[data base64EncodedStringWithOptions:0] mutableCopy];
  [s replaceOccurrencesOfString:@"+" withString:@"-" options:0 range:NSMakeRange(0, s.length)];
  [s replaceOccurrencesOfString:@"/" withString:@"_" options:0 range:NSMakeRange(0, s.length)];
  while ([s hasSuffix:@"="]) [s deleteCharactersInRange:NSMakeRange(s.length - 1, 1)];
  return s;
}

#pragma mark - The coder

static ODataEdmType OISEdmTypeNamed(NSString *declared)
{
  if (![declared isKindOfClass:[NSString class]]) return ODataEdmUnknown;
  {
    static NSDictionary *byName;
    if (!byName) {
      byName = @{
        @"Edm.Boolean": @(ODataEdmBoolean),
        @"Edm.Byte": @(ODataEdmInteger), @"Edm.SByte": @(ODataEdmInteger),
        @"Edm.Int16": @(ODataEdmInteger), @"Edm.Int32": @(ODataEdmInteger),
        @"Edm.Int64": @(ODataEdmInt64),
        @"Edm.Decimal": @(ODataEdmDecimal),
        @"Edm.Single": @(ODataEdmDouble), @"Edm.Double": @(ODataEdmDouble),
        @"Edm.String": @(ODataEdmString),
        @"Edm.DateTimeOffset": @(ODataEdmDateTimeOffset),
        @"Edm.Date": @(ODataEdmDate),
        @"Edm.TimeOfDay": @(ODataEdmTimeOfDay),
        @"Edm.Duration": @(ODataEdmDuration),
        @"Edm.Guid": @(ODataEdmGuid),
        @"Edm.Binary": @(ODataEdmBinary),
      };
    }
    NSNumber *type = byName[declared];
    if (type) return (ODataEdmType)type.integerValue;
  }
  return ODataEdmUnknown;
}

static ODataEdmType OISEdmTypeOfCoreDataType(NSAttributeDescription *attribute)
{
  switch (attribute.attributeType) {
    case NSInteger16AttributeType:
    case NSInteger32AttributeType: return ODataEdmInteger;
    case NSInteger64AttributeType: return ODataEdmInt64;
    case NSDecimalAttributeType: return ODataEdmDecimal;
    case NSDoubleAttributeType:
    case NSFloatAttributeType: return ODataEdmDouble;
    case NSStringAttributeType: return ODataEdmString;
    case NSBooleanAttributeType: return ODataEdmBoolean;
    case NSDateAttributeType: return ODataEdmDateTimeOffset;
    case NSBinaryDataAttributeType: return ODataEdmBinary;
    default:
      return attribute.attributeType == NSUUIDAttributeType ? ODataEdmGuid : ODataEdmUnknown;
  }
}

@implementation ODataValueCoder

+ (ODataEdmType)edmTypeForAttribute:(NSAttributeDescription *)attribute
{
  if (!attribute) return ODataEdmUnknown;
  ODataEdmType declared = OISEdmTypeNamed(attribute.userInfo[ODataUserInfoType]);
  return declared != ODataEdmUnknown ? declared : OISEdmTypeOfCoreDataType(attribute);
}

- (ODataEdmType)edmTypeOfAttribute:(NSAttributeDescription *)attribute
{
  if (!attribute) return ODataEdmUnknown;
  NSString *explicit = attribute.userInfo[ODataUserInfoType];
  if ([explicit isKindOfClass:[NSString class]]) {
    if ([self.schema enumTypeNamed:explicit]) return ODataEdmEnum;
    ODataEdmType type = OISEdmTypeNamed(explicit);
    if (type != ODataEdmUnknown) return type;
  }
  NSString *declared = self.declaredTypeForAttribute ? self.declaredTypeForAttribute(attribute) : nil;
  if (declared) {
    if ([self.schema enumTypeNamed:declared]) return ODataEdmEnum;
    ODataEdmType type = OISEdmTypeNamed(declared);
    if (type != ODataEdmUnknown) return type;
  }
  return OISEdmTypeOfCoreDataType(attribute);
}

- (ODataSchemaEnumType *)enumTypeOfAttribute:(NSAttributeDescription *)attribute
{
  NSString *explicit = attribute.userInfo[ODataUserInfoType];
  NSString *name = [explicit isKindOfClass:[NSString class]] ? explicit
                 : (self.declaredTypeForAttribute ? self.declaredTypeForAttribute(attribute) : nil);
  return name ? [self.schema enumTypeNamed:name] : nil;
}

static BOOL OISIsIntegerAttribute(NSAttributeDescription *attribute)
{
  NSAttributeType t = attribute.attributeType;
  return t == NSInteger16AttributeType || t == NSInteger32AttributeType || t == NSInteger64AttributeType;
}

// enumValue: member names, or member values, joined by commas for flags
// ("Red,Blue"). As a number, the members' values or'ed together.
static NSNumber *OISEnumNumber(ODataSchemaEnumType *type, NSString *text)
{
  long long total = 0;
  for (NSString *part in [text componentsSeparatedByString:@","]) {
    NSString *member = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSNumber *value = type.values[member];
    if (!value) {
      NSScanner *scanner = [NSScanner scannerWithString:member];
      long long n;
      if (![scanner scanLongLong:&n] || !scanner.isAtEnd) return nil;
      value = @(n);
    }
    total |= value.longLongValue;
  }
  return @(total);
}

// A number as member names: the member with that value, or for flags, the
// members whose bits make it up. A value no member names stays a number.
static NSString *OISEnumText(ODataSchemaEnumType *type, NSNumber *number)
{
  long long n = number.longLongValue;
  for (NSString *member in type.memberNames) {
    if (type.values[member].longLongValue == n) return member;
  }
  if (type.isFlags && n > 0) {
    NSMutableArray *members = [NSMutableArray array];
    long long covered = 0;
    for (NSString *member in type.memberNames) {
      long long bits = type.values[member].longLongValue;
      if (bits && (n & bits) == bits) {
        [members addObject:member];
        covered |= bits;
      }
    }
    if (covered == n) return [members componentsJoinedByString:@","];
  }
  return number.stringValue;
}

static ODataEdmType OISEdmTypeOfValue(id value)
{
  if ([value isKindOfClass:[@YES class]]) return ODataEdmBoolean;
  if ([value isKindOfClass:[NSDecimalNumber class]]) return ODataEdmDecimal;
  if ([value isKindOfClass:[NSNumber class]]) {
    const char *t = [value objCType];
    return (t && (t[0] == 'd' || t[0] == 'f')) ? ODataEdmDouble : ODataEdmInt64;
  }
  if ([value isKindOfClass:[NSDate class]]) return ODataEdmDateTimeOffset;
  if ([value isKindOfClass:[NSUUID class]]) return ODataEdmGuid;
  if ([value isKindOfClass:[NSData class]]) return ODataEdmBinary;
  return ODataEdmString;
}

static NSNumber *OISInteger(id json)
{
  if ([json isKindOfClass:[NSNumber class]]) return @([json longLongValue]);
  if (![json isKindOfClass:[NSString class]]) return nil;
  NSScanner *scanner = [NSScanner scannerWithString:json];
  long long value;
  return ([scanner scanLongLong:&value] && scanner.isAtEnd) ? @(value) : nil;
}

static NSDecimalNumber *OISDecimal(id json)
{
  if ([json isKindOfClass:[NSDecimalNumber class]]) return json;
  if ([json isKindOfClass:[NSNumber class]]) return [NSDecimalNumber decimalNumberWithDecimal:[json decimalValue]];
  if (![json isKindOfClass:[NSString class]]) return nil;
  NSDecimalNumber *d = [NSDecimalNumber decimalNumberWithString:json locale:@{ NSLocaleDecimalSeparator: @"." }];
  return [d isEqual:[NSDecimalNumber notANumber]] ? nil : d;
}

- (id)coreDataValueForJSON:(id)json attribute:(NSAttributeDescription *)attribute
{
  if (!json || json == [NSNull null]) return [NSNull null];
  switch ([self edmTypeOfAttribute:attribute]) {
    case ODataEdmBoolean:
      return [json isKindOfClass:[NSNumber class]] ? [NSNumber numberWithBool:[json boolValue]] : nil;
    case ODataEdmInteger:
    case ODataEdmInt64:
      return OISInteger(json);
    case ODataEdmDecimal:
      return OISDecimal(json);
    case ODataEdmDouble:
      if ([json isKindOfClass:[NSNumber class]]) return @([json doubleValue]);
      if ([json isEqual:@"INF"]) return @(INFINITY);
      if ([json isEqual:@"-INF"]) return @(-INFINITY);
      if ([json isEqual:@"NaN"]) return @(NAN);
      return [json isKindOfClass:[NSString class]] ? @([json doubleValue]) : nil;
    case ODataEdmString:
    case ODataEdmTimeOfDay:
      return [json isKindOfClass:[NSString class]] ? json : [json description];
    case ODataEdmDateTimeOffset:
    case ODataEdmDate:
      return [json isKindOfClass:[NSString class]] ? ODataDateFromString(json) : nil;
    case ODataEdmDuration:
      return [json isKindOfClass:[NSString class]] ? ODataDurationFromString(json) : nil;
    case ODataEdmGuid:
      if (![json isKindOfClass:[NSString class]]) return nil;
      return attribute.attributeType == NSUUIDAttributeType ? [[NSUUID alloc] initWithUUIDString:json] : json;
    case ODataEdmBinary:
      return [json isKindOfClass:[NSString class]] ? ODataDataFromBase64(json) : nil;
    case ODataEdmEnum: {
      ODataSchemaEnumType *type = [self enumTypeOfAttribute:attribute];
      if (OISIsIntegerAttribute(attribute)) {
        return [json isKindOfClass:[NSNumber class]] ? json
             : ([json isKindOfClass:[NSString class]] && type ? OISEnumNumber(type, json) : nil);
      }
      if ([json isKindOfClass:[NSNumber class]] && type) return OISEnumText(type, json);
      return [json isKindOfClass:[NSString class]] ? json : [json description];
    }
    case ODataEdmUnknown:
      return json;
  }
  return json;
}

- (id)JSONForCoreDataValue:(id)value attribute:(NSAttributeDescription *)attribute
{
  if (!value || value == [NSNull null]) return [NSNull null];
  ODataEdmType type = [self edmTypeOfAttribute:attribute];
  if (type == ODataEdmUnknown) type = OISEdmTypeOfValue(value);
  switch (type) {
    case ODataEdmBoolean:
      // A real JSON boolean: @0 set on a Boolean attribute would be written 0.
      return [NSNumber numberWithBool:[value boolValue]];
    case ODataEdmInteger:
      return @([value longLongValue]);
    case ODataEdmInt64: {
      NSNumber *n = @([value longLongValue]);
      return self.IEEE754Compatible ? n.stringValue : n;
    }
    case ODataEdmDecimal: {
      NSDecimalNumber *d = OISDecimal(value) ?: [NSDecimalNumber zero];
      return self.IEEE754Compatible ? OISPlainDecimalString(d) : d;
    }
    case ODataEdmDouble: {
      // JSON has no NaN or infinity; OData writes them as strings.
      double x = [value doubleValue];
      if (isnan(x)) return @"NaN";
      if (isinf(x)) return x > 0 ? @"INF" : @"-INF";
      return @(x);
    }
    case ODataEdmString:
    case ODataEdmTimeOfDay:
      return [value isKindOfClass:[NSString class]] ? value : [value description];
    case ODataEdmDateTimeOffset:
      return [value isKindOfClass:[NSDate class]] ? ODataDateTimeOffsetString(value) : value;
    case ODataEdmDate:
      return [value isKindOfClass:[NSDate class]] ? ODataDateString(value) : value;
    case ODataEdmDuration:
      return ODataDurationString([value doubleValue]);
    case ODataEdmGuid:
      return [value isKindOfClass:[NSUUID class]] ? [value UUIDString] : value;
    case ODataEdmBinary:
      return [value isKindOfClass:[NSData class]] ? ODataBase64URLString(value) : value;
    case ODataEdmEnum: {
      ODataSchemaEnumType *type = [self enumTypeOfAttribute:attribute];
      if ([value isKindOfClass:[NSNumber class]]) return type ? OISEnumText(type, value) : [value stringValue];
      return [value description];
    }
    case ODataEdmUnknown:
      return value;
  }
  return value;
}

- (NSString *)literalForValue:(id)value attribute:(NSAttributeDescription *)attribute
{
  if (!value || value == [NSNull null]) return @"null";
  ODataEdmType type = [self edmTypeOfAttribute:attribute];
  if (type == ODataEdmUnknown) type = OISEdmTypeOfValue(value);
  // A string compared with a non-string property is still a string.
  if ([value isKindOfClass:[NSString class]] && type != ODataEdmTimeOfDay && type != ODataEdmGuid &&
      type != ODataEdmDateTimeOffset && type != ODataEdmDate && type != ODataEdmEnum) {
    type = ODataEdmString;
  }
  switch (type) {
    case ODataEdmBoolean:
      return [value boolValue] ? @"true" : @"false";
    case ODataEdmInteger:
    case ODataEdmInt64:
      return [NSString stringWithFormat:@"%lld", [value longLongValue]];
    case ODataEdmDecimal:
      return OISPlainDecimalString(OISDecimal(value) ?: [NSDecimalNumber zero]);
    case ODataEdmDouble: {
      double x = [value doubleValue];
      if (isnan(x)) return @"NaN";
      if (isinf(x)) return x > 0 ? @"INF" : @"-INF";
      return OISDoubleString(x);
    }
    case ODataEdmDateTimeOffset:
      return [value isKindOfClass:[NSDate class]] ? ODataDateTimeOffsetString(value) : value;
    case ODataEdmDate:
      return [value isKindOfClass:[NSDate class]] ? ODataDateString(value) : value;
    case ODataEdmTimeOfDay:
      return [value description];
    case ODataEdmDuration:
      return [NSString stringWithFormat:@"duration'%@'", ODataDurationString([value doubleValue])];
    case ODataEdmGuid:
      return [value isKindOfClass:[NSUUID class]] ? [value UUIDString] : [value description];
    case ODataEdmBinary:
      return [value isKindOfClass:[NSData class]]
          ? [NSString stringWithFormat:@"binary'%@'", ODataBase64URLString(value)] : [value description];
    case ODataEdmEnum: {
      // OData 4.0 wants the qualified form: NS.Color'Red,Blue'.
      ODataSchemaEnumType *type = [self enumTypeOfAttribute:attribute];
      NSString *members = [value isKindOfClass:[NSNumber class]] && type ? OISEnumText(type, value) : [value description];
      NSString *escaped = [members stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
      return type ? [NSString stringWithFormat:@"%@'%@'", type.qualifiedName, escaped] : [NSString stringWithFormat:@"'%@'", escaped];
    }
    case ODataEdmString:
    case ODataEdmUnknown:
      break;
  }
  NSString *s = [value isKindOfClass:[NSString class]] ? value : [value description];
  return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
}

@end
