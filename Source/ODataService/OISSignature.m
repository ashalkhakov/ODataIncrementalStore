// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "OISSignature.h"

#if defined(__APPLE__)
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#else
#include <gnutls/gnutls.h>
#include <gnutls/abstract.h>
#include <gnutls/crypto.h>
#endif

NSSet<NSString *> *OISSignatureAlgorithms(void)
{
  return [NSSet setWithObjects:@"RS256", @"RS384", @"RS512", @"PS256", @"PS384", @"PS512", @"ES256", @"ES384", @"ES512", nil];
}

NSData *OISBase64URLDecode(NSString *text)
{
  NSCharacterSet *alphabet = [NSCharacterSet characterSetWithCharactersInString:
                              @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"];
  if ([text rangeOfCharacterFromSet:alphabet.invertedSet].location != NSNotFound || text.length % 4 == 1) return nil;
  NSMutableString *standard = [[[text stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                                 stringByReplacingOccurrencesOfString:@"_" withString:@"/"] mutableCopy];
  while (standard.length % 4) [standard appendString:@"="];
  return [[NSData alloc] initWithBase64EncodedString:standard options:0];
}

// A JWK member's bytes: an unsigned big-endian number, or a coordinate.
static NSData *OISMember(NSDictionary *jwk, NSString *name)
{
  id value = jwk[name];
  return [value isKindOfClass:[NSString class]] ? OISBase64URLDecode(value) : nil;
}

static NSData *OISWithoutLeadingZeros(NSData *number)
{
  const unsigned char *bytes = number.bytes;
  NSUInteger skip = 0;
  while (skip + 1 < number.length && bytes[skip] == 0) skip++;
  return [number subdataWithRange:NSMakeRange(skip, number.length - skip)];
}

static NSUInteger OISBits(NSData *number)
{
  NSData *n = OISWithoutLeadingZeros(number);
  if (!n.length) return 0;
  unsigned char top = ((const unsigned char *)n.bytes)[0];
  NSUInteger bits = (n.length - 1) * 8;
  while (top) {
    bits++;
    top >>= 1;
  }
  return bits;
}

typedef struct {
  const char *family;  // RS, PS, ES
  int hash;            // 256, 384, 512
  const char *curve;   // ES only
  NSUInteger size;     // an ES coordinate's bytes
} OISAlgorithm;

static BOOL OISAlgorithmNamed(NSString *alg, OISAlgorithm *out)
{
  if (![OISSignatureAlgorithms() containsObject:alg]) return NO;
  NSString *family = [alg substringToIndex:2];
  int hash = [[alg substringFromIndex:2] intValue];
  out->family = [family isEqualToString:@"RS"] ? "RS" : [family isEqualToString:@"PS"] ? "PS" : "ES";
  out->hash = hash;
  out->curve = hash == 256 ? "P-256" : hash == 384 ? "P-384" : "P-521";
  out->size = hash == 256 ? 32 : hash == 384 ? 48 : 66;
  return YES;
}

#if defined(__APPLE__)

static NSData *OISDERLength(NSUInteger length)
{
  if (length < 0x80) return [NSData dataWithBytes:(unsigned char[]){ (unsigned char)length } length:1];
  unsigned char bytes[5];
  NSUInteger count = 0;
  for (NSUInteger n = length; n; n >>= 8) count++;
  bytes[0] = (unsigned char)(0x80 | count);
  for (NSUInteger i = 0; i < count; i++) bytes[count - i] = (unsigned char)(length >> (8 * i));
  return [NSData dataWithBytes:bytes length:count + 1];
}

static NSData *OISDERInteger(NSData *number)
{
  NSMutableData *value = [NSMutableData data];
  NSData *n = OISWithoutLeadingZeros(number);
  if (n.length && (((const unsigned char *)n.bytes)[0] & 0x80)) [value appendBytes:"\0" length:1];
  [value appendData:n];
  NSMutableData *der = [NSMutableData dataWithBytes:"\x02" length:1];
  [der appendData:OISDERLength(value.length)];
  [der appendData:value];
  return der;
}

static SecKeyRef OISCreateKey(NSData *data, CFStringRef type, NSString **reason)
{
  CFErrorRef error = NULL;
  NSDictionary *attributes = @{ (__bridge id)kSecAttrKeyType: (__bridge id)type,
                                (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic };
  SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)attributes, &error);
  if (!key) {
    if (reason) *reason = [NSString stringWithFormat:@"the key does not load: %@", CFBridgingRelease(error)];
    else if (error) CFRelease(error);
  }
  return key;
}

static BOOL OISVerify(OISAlgorithm a, NSDictionary *jwk, NSData *input, NSData *signature, NSString **reason)
{
  SecKeyRef key = NULL;
  SecKeyAlgorithm algorithm;
  if (a.family[0] == 'E') {
    NSMutableData *point = [NSMutableData dataWithBytes:"\x04" length:1];
    [point appendData:OISMember(jwk, @"x")];
    [point appendData:OISMember(jwk, @"y")];
    key = OISCreateKey(point, kSecAttrKeyTypeECSECPrimeRandom, reason);
    algorithm = a.hash == 256 ? kSecKeyAlgorithmECDSASignatureMessageX962SHA256
              : a.hash == 384 ? kSecKeyAlgorithmECDSASignatureMessageX962SHA384
                              : kSecKeyAlgorithmECDSASignatureMessageX962SHA512;
    // JWS has r || s; X9.62 is SEQUENCE { r, s } (RFC 4754's raw form
    // needs macOS 14).
    NSMutableData *body = [NSMutableData dataWithData:OISDERInteger([signature subdataWithRange:NSMakeRange(0, a.size)])];
    [body appendData:OISDERInteger([signature subdataWithRange:NSMakeRange(a.size, a.size)])];
    NSMutableData *der = [NSMutableData dataWithBytes:"\x30" length:1];
    [der appendData:OISDERLength(body.length)];
    [der appendData:body];
    signature = der;
  } else {
    // PKCS #1 RSAPublicKey: SEQUENCE { modulus, publicExponent }.
    NSMutableData *body = [NSMutableData dataWithData:OISDERInteger(OISMember(jwk, @"n"))];
    [body appendData:OISDERInteger(OISMember(jwk, @"e"))];
    NSMutableData *der = [NSMutableData dataWithBytes:"\x30" length:1];
    [der appendData:OISDERLength(body.length)];
    [der appendData:body];
    key = OISCreateKey(der, kSecAttrKeyTypeRSA, reason);
    if (a.family[0] == 'R') {
      algorithm = a.hash == 256 ? kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256
                : a.hash == 384 ? kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA384
                                : kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA512;
    } else {
      algorithm = a.hash == 256 ? kSecKeyAlgorithmRSASignatureMessagePSSSHA256
                : a.hash == 384 ? kSecKeyAlgorithmRSASignatureMessagePSSSHA384
                                : kSecKeyAlgorithmRSASignatureMessagePSSSHA512;
    }
  }
  if (!key) return NO;
  CFErrorRef error = NULL;
  BOOL ok = SecKeyVerifySignature(key, algorithm, (__bridge CFDataRef)input, (__bridge CFDataRef)signature, &error);
  CFRelease(key);
  if (error) CFRelease(error);
  if (!ok && reason) *reason = @"the signature does not verify";
  return ok;
}

NSData *OISSHA256(NSData *data)
{
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  return [NSData dataWithBytes:digest length:sizeof digest];
}

#else

static gnutls_datum_t OISDatum(NSData *data)
{
  return (gnutls_datum_t){ (unsigned char *)data.bytes, (unsigned int)data.length };
}

static BOOL OISVerify(OISAlgorithm a, NSDictionary *jwk, NSData *input, NSData *signature, NSString **reason)
{
  gnutls_pubkey_t key;
  if (gnutls_pubkey_init(&key) < 0) {
    if (reason) *reason = @"no key";
    return NO;
  }
  int loaded;
  gnutls_sign_algorithm_t algorithm;
  NSData *checked = signature;
  gnutls_datum_t der = { NULL, 0 };
  if (a.family[0] == 'E') {
    gnutls_ecc_curve_t curve = a.hash == 256 ? GNUTLS_ECC_CURVE_SECP256R1 : a.hash == 384 ? GNUTLS_ECC_CURVE_SECP384R1 : GNUTLS_ECC_CURVE_SECP521R1;
    NSData *x = OISMember(jwk, @"x"), *y = OISMember(jwk, @"y");
    gnutls_datum_t xd = OISDatum(x), yd = OISDatum(y);
    loaded = gnutls_pubkey_import_ecc_raw(key, curve, &xd, &yd);
    algorithm = a.hash == 256 ? GNUTLS_SIGN_ECDSA_SHA256 : a.hash == 384 ? GNUTLS_SIGN_ECDSA_SHA384 : GNUTLS_SIGN_ECDSA_SHA512;
    // JWS has r || s; GnuTLS takes the DER of X9.62.
    NSData *r = [signature subdataWithRange:NSMakeRange(0, a.size)];
    NSData *s = [signature subdataWithRange:NSMakeRange(a.size, a.size)];
    gnutls_datum_t rd = OISDatum(r), sd = OISDatum(s);
    if (loaded >= 0 && gnutls_encode_rs_value(&der, &rd, &sd) >= 0) {
      checked = [NSData dataWithBytes:der.data length:der.size];
    } else {
      loaded = -1;
    }
  } else {
    NSData *n = OISMember(jwk, @"n"), *e = OISMember(jwk, @"e");
    gnutls_datum_t nd = OISDatum(n), ed = OISDatum(e);
    loaded = gnutls_pubkey_import_rsa_raw(key, &nd, &ed);
    if (a.family[0] == 'R') {
      algorithm = a.hash == 256 ? GNUTLS_SIGN_RSA_SHA256 : a.hash == 384 ? GNUTLS_SIGN_RSA_SHA384 : GNUTLS_SIGN_RSA_SHA512;
    } else {
      algorithm = a.hash == 256 ? GNUTLS_SIGN_RSA_PSS_RSAE_SHA256 : a.hash == 384 ? GNUTLS_SIGN_RSA_PSS_RSAE_SHA384 : GNUTLS_SIGN_RSA_PSS_RSAE_SHA512;
    }
  }
  if (der.data) gnutls_free(der.data);
  if (loaded < 0) {
    gnutls_pubkey_deinit(key);
    if (reason) *reason = @"the key does not load";
    return NO;
  }
  gnutls_datum_t data = OISDatum(input), sig = OISDatum(checked);
  int verified = gnutls_pubkey_verify_data2(key, algorithm, 0, &data, &sig);
  gnutls_pubkey_deinit(key);
  if (verified < 0 && reason) *reason = @"the signature does not verify";
  return verified >= 0;
}

NSData *OISSHA256(NSData *data)
{
  unsigned char digest[32];
  gnutls_hash_fast(GNUTLS_DIG_SHA256, data.bytes, data.length, digest);
  return [NSData dataWithBytes:digest length:sizeof digest];
}

#endif

BOOL OISVerifyJWS(NSString *alg, NSDictionary *jwk, NSData *input, NSData *signature, NSString **reason)
{
  OISAlgorithm a;
  if (!OISAlgorithmNamed(alg, &a)) {
    if (reason) *reason = [NSString stringWithFormat:@"%@ is not an algorithm this service takes", alg];
    return NO;
  }
  if (![jwk isKindOfClass:[NSDictionary class]]) {
    if (reason) *reason = @"no key";
    return NO;
  }
  // A key may name the one algorithm it is for (RFC 7517 section 4.4), and
  // what it is for (4.2).
  if (jwk[@"alg"] && ![jwk[@"alg"] isEqual:alg]) {
    if (reason) *reason = [NSString stringWithFormat:@"the key is for %@, not %@", jwk[@"alg"], alg];
    return NO;
  }
  if (jwk[@"use"] && ![jwk[@"use"] isEqual:@"sig"]) {
    if (reason) *reason = @"the key is not for signatures";
    return NO;
  }
  if (a.family[0] == 'E') {
    NSData *x = OISMember(jwk, @"x"), *y = OISMember(jwk, @"y");
    if (![jwk[@"kty"] isEqual:@"EC"] || ![jwk[@"crv"] isEqual:@(a.curve)] || x.length != a.size || y.length != a.size) {
      if (reason) *reason = [NSString stringWithFormat:@"%@ takes an EC key on %s", alg, a.curve];
      return NO;
    }
    if (signature.length != 2 * a.size) {
      if (reason) *reason = @"the signature is not r || s";
      return NO;
    }
  } else {
    NSData *n = OISMember(jwk, @"n"), *e = OISMember(jwk, @"e");
    if (![jwk[@"kty"] isEqual:@"RSA"] || !n.length || !e.length) {
      if (reason) *reason = [NSString stringWithFormat:@"%@ takes an RSA key", alg];
      return NO;
    }
    if (OISBits(n) < 2048) {
      if (reason) *reason = [NSString stringWithFormat:@"the key has %lu bits, fewer than 2048", (unsigned long)OISBits(n)];
      return NO;
    }
  }
  return OISVerify(a, jwk, input, signature, reason);
}
