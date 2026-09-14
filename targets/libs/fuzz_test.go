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
	"encoding/hex"
	"encoding/json"
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

// WebAuthn L3 §16 end-to-end spec test vectors (https://www.w3.org/TR/webauthn-3/#sctn-test-vectors) —
// the same known-good seeds go-webauthn fuzzes its own parser with. Byte mutation never synthesizes a
// valid CBOR attestationObject / authenticatorData from scratch, so without these the parser stalls at
// the CBOR-shape gate (~4% lib coverage on 800+ corpus inputs); a real seed lets it reach the deep parse.
func waHexToB64(hx string) string {
	b, _ := hex.DecodeString(hx)
	return base64.RawURLEncoding.EncodeToString(b)
}

func waRegistrationSeed(credID, attObj, clientData string) []byte {
	id := waHexToB64(credID)
	b, _ := json.Marshal(map[string]any{"id": id, "rawId": id, "type": "public-key",
		"response": map[string]any{"attestationObject": waHexToB64(attObj), "clientDataJSON": waHexToB64(clientData)}})
	return b
}

func waAssertionSeed(credID, authData, clientData, sig string) []byte {
	id := waHexToB64(credID)
	b, _ := json.Marshal(map[string]any{"id": id, "rawId": id, "type": "public-key",
		"response": map[string]any{"authenticatorData": waHexToB64(authData), "clientDataJSON": waHexToB64(clientData), "signature": waHexToB64(sig)}})
	return b
}

// ---- go-webauthn: browser attestation/assertion (unauth ceremony endpoints)
func FuzzWebAuthnCredentialResponse(f *testing.F) {
	f.Add([]byte(`{}`))
	f.Add([]byte(`{"id":"x","rawId":"eA","type":"public-key","response":{"clientDataJSON":"eyJ0IjoxfQ","attestationObject":"oA"}}`))
	f.Add([]byte(`{"id":"x","rawId":"eA","type":"public-key","response":{"clientDataJSON":"eyJ0IjoxfQ","authenticatorData":"oA","signature":"oA"}}`))
	f.Add(waRegistrationSeed("f91f391db4c9b2fde0ea70189cba3fb63f579ba6122b33ad94ff3ec330084be4", "a363666d74646e6f6e656761747453746d74a068617574684461746158a4bfabc37432958b063360d3ad6461c9c4735ae7f8edd46592a5e0f01452b2e4b559000000008446ccb9ab1db374750b2367ff6f3a1f0020f91f391db4c9b2fde0ea70189cba3fb63f579ba6122b33ad94ff3ec330084be4a5010203262001215820afefa16f97ca9b2d23eb86ccb64098d20db90856062eb249c33a9b672f26df61225820930a56b87a2fca66334b03458abf879717c12cc68ed73290af2e2664796b9220", "7b2274797065223a22776562617574686e2e637265617465222c226368616c6c656e6765223a22414d4d507434557878475453746e63647134313759447742466938767049612d7077386f4f755657345441222c226f726967696e223a2268747470733a2f2f6578616d706c652e6f7267222c2263726f73734f726967696e223a66616c73652c22657874726144617461223a22636c69656e74446174614a534f4e206d617920626520657874656e6465642077697468206164646974696f6e616c206669656c647320696e20746865206675747572652c207375636820617320746869733a20426b5165446a646354427258426941774a544c453551227d"))                                                                                                                                                                       // §16.2 None ES256
	f.Add(waRegistrationSeed("455ef34e2043a87db3d4afeb39bbcb6cc32df9347c789a865ecdca129cbef58c", "a363666d74667061636b65646761747453746d74a263616c672663736967584630440220067a20754ab925005dbf378097c92120031581c73228d1fb4f5b881bcd7da98302207fc7b147558c7c0eba3af18bd9d121fa3d3a26d17fe3f220272178f473b6006d68617574684461746158a4bfabc37432958b063360d3ad6461c9c4735ae7f8edd46592a5e0f01452b2e4b55d00000000df850e09db6afbdfab51697791506cfc0020455ef34e2043a87db3d4afeb39bbcb6cc32df9347c789a865ecdca129cbef58ca5010203262001215820eb151c8176b225cc651559fecf07af450fd85802046656b34c18f6cf193843c5225820927b8aa427a2be1b8834d233a2d34f61f13bfd44119c325d5896e183fee484f2", "7b2274797065223a22776562617574686e2e637265617465222c226368616c6c656e6765223a2265476e4374334c55745936366b336a506a796e6962506b31716e666644616966715a774c33417032392d55222c226f726967696e223a2268747470733a2f2f6578616d706c652e6f7267222c2263726f73734f726967696e223a66616c73652c22657874726144617461223a22636c69656e74446174614a534f4e206d617920626520657874656e6465642077697468206164646974696f6e616c206669656c647320696e20746865206675747572652c207375636820617320746869733a205539685458764b453255526b4d6e625f307859485667227d")) // §16.3 Packed self ES256
	f.Add(waRegistrationSeed("b8ad59b996047ab18e2ceb57206c362da57458793481f4a8ebf101c7ca7cc0f1", "a363666d74646e6f6e656761747453746d74a068617574684461746158a4bfabc37432958b063360d3ad6461c9c4735ae7f8edd46592a5e0f01452b2e4b5410000000097586fd09799a76401c200455099ef2a0020b8ad59b996047ab18e2ceb57206c362da57458793481f4a8ebf101c7ca7cc0f1a5010203262001215820a1c47c1d82da4ebe82cd72207102b380670701993bc35398ae2e5726427fe01d22582086c1080d82987028c7f54ecb1b01185de243b359294a0ed210cd47480f0adc88", "7b2274797065223a22776562617574686e2e637265617465222c226368616c6c656e6765223a225468394d595a68706e6a504254786b68555f53646667364f4e58665672454673587a72636b7151664a2d55222c226f726967696e223a2268747470733a2f2f6578616d706c652e6f7267222c2263726f73734f726967696e223a747275652c22746f704f726967696e223a2268747470733a2f2f6578616d706c652e636f6d227d"))                                                                                                                                                                                                                                                                                                                                                     // §16.5 None ES256 top-origin
	f.Add(waAssertionSeed("f91f391db4c9b2fde0ea70189cba3fb63f579ba6122b33ad94ff3ec330084be4", "bfabc37432958b063360d3ad6461c9c4735ae7f8edd46592a5e0f01452b2e4b51900000000", "7b2274797065223a22776562617574686e2e676574222c226368616c6c656e6765223a224f63446e55685158756c5455506f334a5558543049393770767a7a59425039745a63685879617630314167222c226f726967696e223a2268747470733a2f2f6578616d706c652e6f7267222c2263726f73734f726967696e223a66616c73657d", "3046022100f50a4e2e4409249c4a853ba361282f09841df4dd4547a13a87780218deffcd380221008480ac0f0b93538174f575bf11a1dd5d78c6e486013f937295ea13653e331e87"))                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      // §16.2 assertion (None ES256)
	f.Add(waAssertionSeed("455ef34e2043a87db3d4afeb39bbcb6cc32df9347c789a865ecdca129cbef58c", "bfabc37432958b063360d3ad6461c9c4735ae7f8edd46592a5e0f01452b2e4b50900000000", "7b2274797065223a22776562617574686e2e676574222c226368616c6c656e6765223a225248696843784e534e493352594d45314f7731476d3132786e726b634a5f6666707637546e2d4a71386773222c226f726967696e223a2268747470733a2f2f6578616d706c652e6f7267222c2263726f73734f726967696e223a66616c73652c22657874726144617461223a22636c69656e74446174614a534f4e206d617920626520657874656e6465642077697468206164646974696f6e616c206669656c647320696e20746865206675747572652c207375636820617320746869733a206754623533727a36456853576f6d58477a696d433151227d", "304402203310b9431903c401f1be2bdc8d23a4007682dbbddcf846994947b7f465daf84002204e94dd00047b316061b3b99772b7efd95994a83ef584b3b6b825ea3550251b66"))                                                                                                                                                                                                                                                                                                                                                          // §16.3 assertion (Packed self ES256)
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
	f.Add([]byte(`<?xml version="1.0" encoding="UTF-8"?><!-- c --><r xmlns:a="urn:x" a:k="v"><c><![CDATA[<x>&]]></c><?pi d?><e/></r>`))
	f.Add([]byte("<r>&lt;&amp;&#xd;&#10;&#x9;</r>"))
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
