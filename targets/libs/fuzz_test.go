// Standalone fuzz harness for the third-party libraries keyorix hands
// UNTRUSTED bytes with no keyorix-side filter in front (the library is the
// front line). Versions pinned to keyorix go.mod. Mirrors the pkcs7 rig.
//
// Detection layers: panics/crashes (native), OOM (rig MemoryMax), CPU-time /
// algorithmic-complexity DoS (withinDeadline), round-trip re-parse (etree),
// decoder differential (xasn1), and signature/verification-BYPASS rejection
// invariants (JWT id_token verify, SAML response verify) — see per-target comments.
package libsfuzz

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	stdasn1 "encoding/asn1"
	"encoding/base64"
	"math/big"
	"net/url"
	"testing"
	"time"

	"github.com/beevik/etree"
	"github.com/crewjam/saml"
	"github.com/go-webauthn/webauthn/protocol"
	xasn1 "github.com/go-webauthn/x/encoding/asn1"
	"github.com/golang-jwt/jwt/v5"
)

// perInputDeadline bounds a single input. Native go-fuzz has NO per-input timeout,
// so without this a CPU-time / algorithmic-complexity DoS just drags throughput
// instead of being flagged. Parsers on fuzz-sized inputs are sub-millisecond, so a
// large margin trips only on a genuine blow-up.
const perInputDeadline = 2 * time.Second

// withinDeadline fails the input if fn does not return within perInputDeadline.
// A panic in fn still propagates and crashes the worker (native crasher). Callers
// must keep any t.Fatal assertions OUTSIDE fn — t.Fatal only works on the test's
// own goroutine, not this child goroutine.
func withinDeadline(t *testing.T, fn func()) {
	t.Helper()
	done := make(chan struct{})
	go func() { defer close(done); fn() }()
	select {
	case <-done:
	case <-time.After(perInputDeadline):
		t.Fatalf("input exceeded %s deadline — possible algorithmic-complexity DoS", perInputDeadline)
	}
}

// ---- go-webauthn: browser attestation/assertion (unauth ceremony endpoints)
func FuzzWebAuthnCredentialResponse(f *testing.F) {
	f.Add([]byte(`{}`))
	f.Add([]byte(`{"id":"x","rawId":"eA","type":"public-key","response":{"clientDataJSON":"eyJ0IjoxfQ","attestationObject":"oA"}}`))
	f.Add([]byte(`{"id":"x","rawId":"eA","type":"public-key","response":{"clientDataJSON":"eyJ0IjoxfQ","authenticatorData":"oA","signature":"oA"}}`))
	f.Fuzz(func(t *testing.T, data []byte) {
		withinDeadline(t, func() {
			_, _ = protocol.ParseCredentialCreationResponseBytes(data)
			_, _ = protocol.ParseCredentialRequestResponseBytes(data)
		})
	})
}

// ---- golang-jwt/jwt/v5: id_token parse+verify, keyorix sso.go hardening
var jwtParser = jwt.NewParser(
	jwt.WithValidMethods([]string{"RS256", "RS384", "RS512", "ES256", "ES384", "ES512", "PS256", "PS384", "PS512"}),
	jwt.WithExpirationRequired(),
)

// FuzzJWTParseIDToken — crash + deadline + signature-BYPASS rejection invariant.
// The parser pins asymmetric algs (no "none", no HS*) and verifies against a key
// whose private half the fuzzer never holds, so no crafted token can legitimately
// verify. Any token that comes back Valid is a real bypass (alg:none accepted,
// alg-confusion, signature-strip, or the signature simply not being checked).
func FuzzJWTParseIDToken(f *testing.F) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	keyfn := func(tok *jwt.Token) (interface{}, error) { return &key.PublicKey, nil }
	f.Add("")
	f.Add("a.b.c")
	f.Add("eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.")
	f.Fuzz(func(t *testing.T, raw string) {
		var tok *jwt.Token
		var perr error
		withinDeadline(t, func() {
			var claims jwt.MapClaims
			tok, perr = jwtParser.ParseWithClaims(raw, &claims, keyfn)
		})
		if perr == nil && tok != nil && tok.Valid {
			t.Fatalf("JWT SIGNATURE BYPASS: a token we never signed verified as valid: %q", raw)
		}
	})
}

// ---- crewjam/saml: ParseXMLResponse (raw XML -> xrv -> dsig -> assertion)
func newTestSP() *saml.ServiceProvider {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "idp.example.com"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
	}
	der, _ := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	idp := saml.IDPSSODescriptor{}
	idp.KeyDescriptors = []saml.KeyDescriptor{{
		Use: "signing",
		KeyInfo: saml.KeyInfo{X509Data: saml.X509Data{
			X509Certificates: []saml.X509Certificate{{Data: base64.StdEncoding.EncodeToString(der)}},
		}},
	}}
	return &saml.ServiceProvider{
		EntityID:    "https://sp.example.com/saml/metadata",
		AcsURL:      url.URL{Scheme: "https", Host: "sp.example.com", Path: "/saml/acs"},
		MetadataURL: url.URL{Scheme: "https", Host: "sp.example.com", Path: "/saml/metadata"},
		IDPMetadata: &saml.EntityDescriptor{
			EntityID:          "https://idp.example.com/metadata",
			IDPSSODescriptors: []saml.IDPSSODescriptor{idp},
		},
	}
}

// FuzzSAMLParseXMLResponse — crash + deadline + signature-BYPASS rejection invariant.
// The SP is configured with an IdP signing cert whose private key the fuzzer does
// NOT hold, and crewjam/saml verifies the response/assertion signature against that
// cert. So no crafted response can carry a signature valid under it — ParseXMLResponse
// must ALWAYS return an error here. Any success is a signature-verification bypass:
// a forged assertion accepted, KeyInfo/embedded-cert spoofing, an XML
// canonicalization / comment-injection bypass, or the signature not actually checked.
func FuzzSAMLParseXMLResponse(f *testing.F) {
	sp := newTestSP()
	cur := url.URL{Scheme: "https", Host: "sp.example.com", Path: "/saml/acs"}
	f.Add([]byte(`<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol"></samlp:Response>`))
	f.Add([]byte(`<Response/>`))
	f.Fuzz(func(t *testing.T, data []byte) {
		var perr error
		withinDeadline(t, func() { _, perr = sp.ParseXMLResponse(data, []string{"id-1"}, cur) })
		if perr == nil {
			t.Fatalf("SAML SIGNATURE BYPASS: ParseXMLResponse accepted a response we never signed: %q", data)
		}
	})
}

// ---- beevik/etree: raw XML parser under SAML/goxmldsig. Unfuzzed upstream
// (Scorecard 0) yet it takes attacker XML directly. keyorix uses it in ~54 files.
// Beyond crash/deadline, assert a round-trip invariant: etree must be able to
// re-parse its OWN serialization. A strict byte-idempotence check is intentionally
// NOT used — XML spec-defined normalization (e.g. the CR reference "&#xd;", §2.11)
// legitimately changes on round-trip and is not a bug; only etree emitting output
// it can no longer parse is a genuine parse/serialize asymmetry.
func FuzzEtreeParse(f *testing.F) {
	f.Add([]byte(`<a><b>c</b></a>`))
	f.Add([]byte(`<?xml version="1.0"?><r x="1"><c/></r>`))
	f.Fuzz(func(t *testing.T, data []byte) {
		var reparseErr error
		var reparseAttempted bool
		withinDeadline(t, func() {
			doc := etree.NewDocument()
			if doc.ReadFromBytes(data) != nil {
				return
			}
			b1, err := doc.WriteToBytes()
			if err != nil {
				return
			}
			reparseAttempted = true
			reparseErr = etree.NewDocument().ReadFromBytes(b1)
		})
		if reparseAttempted && reparseErr != nil {
			t.Fatalf("etree round-trip: etree cannot re-parse its own serialization: %v", reparseErr)
		}
	})
}

// ---- go-webauthn/x/encoding/asn1: custom ASN.1 decoder (module go-webauthn/x
// is unfuzzed, Scorecard 0). A ber2der-analogue: parses attacker attestation /
// ECDSA-signature bytes. Fuzz the SEQUENCE{INTEGER,INTEGER} (r,s) shape it uses.
type ecdsaSig struct{ R, S *big.Int }

func FuzzWebAuthnXASN1(f *testing.F) {
	f.Add([]byte{0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01})
	f.Add([]byte{0x30, 0x00})
	f.Fuzz(func(t *testing.T, data []byte) {
		withinDeadline(t, func() {
			var s ecdsaSig
			_, _ = xasn1.Unmarshal(data, &s)
		})
	})
}

// FuzzXASN1Differential — DIFFERENTIAL oracle for the ASN.1 signature decoder.
// Parses the same SEQUENCE{INTEGER,INTEGER} with go-webauthn/x's decoder AND Go's
// crypto/asn1. When BOTH accept the input, they must decode the SAME (R,S) values;
// a value disagreement means the two decoders read identical bytes as different
// signature integers — a real, security-relevant parsing discrepancy (signature
// confusion). Accept/reject disagreement is NOT flagged: xasn1 is BER-lenient and
// crypto/asn1 is DER-strict, so one accepting what the other rejects is expected,
// not a bug — comparing only on mutual success is what keeps this false-positive-free.
func FuzzXASN1Differential(f *testing.F) {
	f.Add([]byte{0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01})
	f.Add([]byte{0x30, 0x08, 0x02, 0x02, 0x00, 0x80, 0x02, 0x02, 0x7f, 0xff})
	f.Fuzz(func(t *testing.T, data []byte) {
		var xs, gs ecdsaSig
		var xerr, gerr error
		withinDeadline(t, func() {
			_, xerr = xasn1.Unmarshal(data, &xs)
			_, gerr = stdasn1.Unmarshal(data, &gs)
		})
		if xerr != nil || gerr != nil {
			return // BER-vs-DER leniency: accept/reject differences are expected.
		}
		if xs.R == nil || xs.S == nil || gs.R == nil || gs.S == nil {
			return
		}
		if xs.R.Cmp(gs.R) != 0 || xs.S.Cmp(gs.S) != 0 {
			t.Fatalf("ASN.1 decoder disagreement on (R,S): xasn1=(%s,%s) crypto/asn1=(%s,%s) data=%x",
				xs.R, xs.S, gs.R, gs.S, data)
		}
	})
}
