#!/usr/bin/env python3
# Test vectors for the JWT authenticator: keys, a key set before and after a
# rotation, and tokens good and bad, signed with the openssl command (3.x).
# Writes Tests/OISJWTFixtures.h.
#
#   python3 Scripts/make-jwt-fixtures.py
#
# The private keys are thrown away: the tests only verify.

import base64, hashlib, hmac, json, os, subprocess, sys, tempfile

ISSUER = "https://id.example.test/realms/ois"
AUDIENCE = "ois-api"
FAR = 4102444800   # 2100-01-01
PAST = 1000000000  # 2001-09-09

def b64u(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

def openssl(*args, data=None):
    return subprocess.run(["openssl", *args], input=data, capture_output=True, check=True).stdout

work = tempfile.mkdtemp()

def path(name):
    return os.path.join(work, name)

def rsa_key(name, bits):
    openssl("genpkey", "-algorithm", "RSA", "-pkeyopt", f"rsa_keygen_bits:{bits}", "-out", path(name))
    modulus = openssl("rsa", "-in", path(name), "-noout", "-modulus").decode().strip().split("=")[1]
    return {"kty": "RSA", "n": b64u(bytes.fromhex(modulus)), "e": b64u((65537).to_bytes(3, "big"))}

def ec_key(name, curve, crv, size):
    openssl("genpkey", "-algorithm", "EC", "-pkeyopt", f"ec_paramgen_curve:{curve}", "-out", path(name))
    der = openssl("pkey", "-in", path(name), "-pubout", "-outform", "DER")
    point = der[-(1 + 2 * size):]
    assert point[0] == 4
    return {"kty": "EC", "crv": crv, "x": b64u(point[1:1 + size]), "y": b64u(point[1 + size:])}

def der_to_raw(der, size):
    # SEQUENCE { INTEGER r, INTEGER s } to r || s, each size bytes.
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7f)
    out = b""
    for _ in range(2):
        assert der[i] == 0x02
        length = der[i + 1]
        value = der[i + 2:i + 2 + length].lstrip(b"\0")
        out += value.rjust(size, b"\0")
        i += 2 + length
    return out

def sign(key, alg, signing_input):
    digest = "-sha" + alg[2:]
    if alg.startswith("RS"):
        return openssl("dgst", digest, "-sign", path(key), data=signing_input)
    if alg.startswith("PS"):
        return openssl("dgst", digest, "-sign", path(key), "-sigopt", "rsa_padding_mode:pss",
                       "-sigopt", "rsa_pss_saltlen:digest", data=signing_input)
    if alg.startswith("ES"):
        size = {"256": 32, "384": 48, "512": 66}[alg[2:]]
        return der_to_raw(openssl("dgst", digest, "-sign", path(key), data=signing_input), size)
    raise ValueError(alg)

def token(key, header, claims, tamper=False):
    signing_input = (b64u(json.dumps(header, separators=(",", ":")).encode()) + "." +
                     b64u(json.dumps(claims, separators=(",", ":")).encode())).encode()
    alg = header["alg"]
    if alg == "none":
        signature = b""
    elif alg.startswith("HS"):
        signature = hmac.new(key.encode(), signing_input, hashlib.sha256).digest()
    else:
        signature = sign(key, alg, signing_input)
    if tamper:
        signature = bytes([signature[0] ^ 1]) + signature[1:]
    return signing_input.decode() + "." + b64u(signature)

keys = {
    "rsa1": dict(rsa_key("rsa1.pem", 2048), kid="rsa1", use="sig"),
    "rsa2": dict(rsa_key("rsa2.pem", 2048), kid="rsa2", use="sig"),
    "small": dict(rsa_key("small.pem", 1024), kid="small", use="sig"),
    "ec256": dict(ec_key("ec256.pem", "P-256", "P-256", 32), kid="ec256"),
    "ec384": dict(ec_key("ec384.pem", "P-384", "P-384", 48), kid="ec384"),
}

def claims(**changes):
    base = {"iss": ISSUER, "aud": AUDIENCE, "sub": "ann", "exp": FAR, "iat": PAST,
            "email": "ann@example.com", "groups": ["buyers", "staff"], "scope": "odata.read odata.write"}
    base.update(changes)
    return {k: v for k, v in base.items() if v is not None}

tokens = {
    "rs256": token("rsa1.pem", {"alg": "RS256", "kid": "rsa1", "typ": "at+jwt"}, claims()),
    "ps256": token("rsa1.pem", {"alg": "PS256", "kid": "rsa1"}, claims()),
    "rs512": token("rsa1.pem", {"alg": "RS512", "kid": "rsa1"}, claims()),
    "es256": token("ec256.pem", {"alg": "ES256", "kid": "ec256", "typ": "JWT"}, claims()),
    "es384": token("ec384.pem", {"alg": "ES384", "kid": "ec384"}, claims()),
    "noKid": token("ec256.pem", {"alg": "ES256"}, claims()),
    "audienceList": token("rsa1.pem", {"alg": "RS256", "kid": "rsa1"}, claims(aud=["other", AUDIENCE])),
    "readOnly": token("rsa1.pem", {"alg": "RS256", "kid": "rsa1"}, claims(scope="odata.read")),
    "rotated": token("rsa2.pem", {"alg": "RS256", "kid": "rsa2"}, claims(sub="bob")),
    "expired": token("rsa1.pem", {"alg": "RS256", "kid": "rsa1"}, claims(exp=PAST)),
    "notYet": token("rsa1.pem", {"alg": "RS256", "kid": "rsa1"}, claims(nbf=FAR - 10)),
    "noExpiry": token("rsa1.pem", {"alg": "RS256", "kid": "rsa1"}, claims(exp=None)),
    "noSubject": token("rsa1.pem", {"alg": "RS256", "kid": "rsa1"}, claims(sub=None)),
    "wrongAudience": token("rsa1.pem", {"alg": "RS256", "kid": "rsa1"}, claims(aud="someone-else")),
    "wrongIssuer": token("rsa1.pem", {"alg": "RS256", "kid": "rsa1"}, claims(iss="https://evil.example.test/")),
    "badSignature": token("rsa1.pem", {"alg": "RS256", "kid": "rsa1"}, claims(), tamper=True),
    "otherKeysSignature": token("rsa2.pem", {"alg": "RS256", "kid": "rsa1"}, claims()),
    "none": token(None, {"alg": "none", "kid": "rsa1"}, claims()),
    "hmacWithPublicKey": token(keys["rsa1"]["n"], {"alg": "HS256", "kid": "rsa1"}, claims()),
    # ES384 names a P-384 key, but the kid is the P-256 one.
    "curveMismatch": token("ec384.pem", {"alg": "ES384", "kid": "ec256"}, claims()),
    "rsaKeyForEC": token("rsa1.pem", {"alg": "RS256", "kid": "ec256"}, claims()),
    "weakKey": token("small.pem", {"alg": "RS256", "kid": "small"}, claims()),
    "critical": token("rsa1.pem", {"alg": "RS256", "kid": "rsa1", "crit": ["exp"]}, claims()),
    "idToken": token("rsa1.pem", {"alg": "RS256", "kid": "rsa1", "typ": "id+jwt"}, claims()),
}

before = {"keys": [keys[k] for k in ("rsa1", "small", "ec256", "ec384")]}
after = {"keys": [keys[k] for k in ("rsa1", "rsa2", "small", "ec256", "ec384")]}
fixtures = {"issuer": ISSUER, "audience": AUDIENCE, "keys": before, "rotatedKeys": after, "tokens": tokens}

text = json.dumps(fixtures, indent=1, sort_keys=True)
escaped = text.replace("\\", "\\\\").replace('"', '\\"')
lines = "\n".join('  @"%s\\n"' % line for line in escaped.split("\n"))
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Tests", "OISJWTFixtures.h")
with open(out, "w") as f:
    f.write("// Generated by Scripts/make-jwt-fixtures.py: keys, key sets and tokens\n")
    f.write("// for the JWT authenticator's tests. The private keys are gone.\n\n")
    f.write("#pragma once\n#import <Foundation/Foundation.h>\n\n")
    f.write("static NSString * const OISJWTFixturesJSON =\n%s;\n" % lines)
print("wrote", os.path.normpath(out), "with", len(tokens), "tokens")
