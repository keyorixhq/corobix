// Rejection-invariant harness — the verification-bypass class that crash/round-trip
// fuzzing cannot reach. The fuzzer never holds jwtKey, so the ONLY input that may
// verify is our genuine token; any OTHER token that verifies is a signature bypass
// (alg:none accepted, alg-confusion, signature-strip, signature not actually checked).
// This is the template to port into keyorix's real OIDC/SSO verifiers via PR.
package libsextra

import (
	"crypto/rand"
	"crypto/rsa"
	"strings"
	"testing"

	"github.com/golang-jwt/jwt/v5"
)

var (
	jwtKey   *rsa.PrivateKey
	jwtValid string // one genuinely RS256-signed token
	jwtNone  string // an alg:none token (must be rejected)
)

func init() {
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	jwtKey = k
	// No exp claim: keeps the genuine token valid for the whole run, so the positive
	// assertion can't flap once an expiry lapsed.
	jwtValid, err = jwt.NewWithClaims(jwt.SigningMethodRS256,
		jwt.MapClaims{"sub": "alice", "iss": "keyorix-fuzz"}).SignedString(jwtKey)
	if err != nil {
		panic(err)
	}
	jwtNone, err = jwt.NewWithClaims(jwt.SigningMethodNone,
		jwt.MapClaims{"sub": "alice", "iss": "keyorix-fuzz"}).SignedString(jwt.UnsafeAllowNoneSignatureType)
	if err != nil {
		panic(err)
	}
}

// jwtVerify mirrors keyorix's verifier config (internal/core/oidc.go, sso.go):
// asymmetric algs pinned via WithValidMethods (no "none", no HS*), our public key.
func jwtVerify(raw string) bool {
	parser := jwt.NewParser(jwt.WithValidMethods([]string{
		"RS256", "RS384", "RS512", "ES256", "ES384", "ES512", "PS256", "PS384", "PS512",
	}))
	tok, err := parser.Parse(raw, func(*jwt.Token) (interface{}, error) {
		return &jwtKey.PublicKey, nil
	})
	return err == nil && tok != nil && tok.Valid
}

func FuzzJWTVerifyReject(f *testing.F) {
	f.Add([]byte(jwtValid))
	f.Add([]byte(jwtNone))
	if i := strings.LastIndexByte(jwtValid, '.'); i >= 0 {
		f.Add([]byte(jwtValid[:i+1])) // signature stripped
	}
	f.Add([]byte("a.b.c"))
	f.Add([]byte(""))
	f.Fuzz(func(t *testing.T, data []byte) {
		raw := string(data)
		var valid bool
		withinDeadline(t, func() { valid = jwtVerify(raw) })
		if raw == jwtValid {
			if !valid {
				t.Fatalf("verifier REJECTED the genuine token (false negative / availability bug)")
			}
			return
		}
		if valid {
			t.Fatalf("SIGNATURE BYPASS: a token we never signed verified as valid: %q", raw)
		}
	})
}
