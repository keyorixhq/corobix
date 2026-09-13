// Standalone fuzz harness for the third-party libraries keyorix hands
// UNTRUSTED bytes with no keyorix-side filter in front (the library is the
// front line). Versions pinned to keyorix go.mod. Mirrors the pkcs7 rig.
//
// Detection layers: panics/crashes (native), OOM (rig MemoryMax), CPU-time /
// algorithmic-complexity DoS (withinDeadline), and — for etree — a round-trip
// re-parse invariant (correctness, not just "doesn't crash").
package libsfuzz

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
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

func FuzzJWTParseIDToken(f *testing.F) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	keyfn := func(tok *jwt.Token) (interface{}, error) { return &key.PublicKey, nil }
	f.Add("")
	f.Add("a.b.c")
	f.Add("eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.")
	f.Fuzz(func(t *testing.T, raw string) {
		withinDeadline(t, func() {
			var claims jwt.MapClaims
			_, _ = jwtParser.ParseWithClaims(raw, &claims, keyfn)
		})
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

func FuzzSAMLParseXMLResponse(f *testing.F) {
	sp := newTestSP()
	cur := url.URL{Scheme: "https", Host: "sp.example.com", Path: "/saml/acs"}
	f.Add([]byte(`<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol"></samlp:Response>`))
	f.Add([]byte(`<Response/>`))
	f.Fuzz(func(t *testing.T, data []byte) {
		withinDeadline(t, func() {
			_, _ = sp.ParseXMLResponse(data, []string{"id-1"}, cur)
		})
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
