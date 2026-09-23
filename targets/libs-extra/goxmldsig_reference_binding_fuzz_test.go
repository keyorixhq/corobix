// FuzzGoXMLDSigReferenceBinding — in-wall bypass-invariant harness for
// CVE-2026-33487 / GHSA-479m-364c-43vc (russellhaering/goxmldsig
// validateSignature: a Go loop-variable-capture bug makes reference
// selection always resolve to the LAST Reference in SignedInfo, regardless
// of which one's URI actually matches the element being validated).
//
// Traced against the actual v1.4.0->v1.6.0 diff (not just the advisory
// text, which describes the bug's MECHANISM correctly but doesn't mention
// that v1.5.0 already restructured validateSignature to verify the raw
// signature over SignedInfo BEFORE re-deriving References from the
// now-verified bytes — the isolated v1.5.0->v1.6.0 diff is exactly and
// only the loop fix: `for _, _ref := range ... ref = &_ref` (no break,
// shared loop variable — every iteration overwrites _ref's storage
// regardless of whether ITS OWN condition matched, so by the time the loop
// exits `ref` always reads as the LAST Reference processed) becomes
// `for i := range ... ref = &signedInfo.References[i]; break` (index +
// break — resolves to the first genuine match and stops there)).
//
// Minimal reproducer (keyorix-private/adversarial-review or the fuzz-corpus
// seeds committed alongside this file) confirmed by hand first: a
// SignedInfo carrying two References for "#target" -- the FIRST textually
// matches the id and describes content X; the LAST (irrelevant to the
// bug's URI check, but is what validateSignature actually uses) describes
// content Y -- validates successfully when the element's ACTUAL content is
// Y, even though the reference that genuinely matches "#target" says the
// authorized content is X. Confirmed reproducing at v1.4.0; the
// byte-identical cross-version check at v1.6.0 hit an unrelated namespace-
// canonicalization detail of the hand-spliced construction (a PLAIN,
// unmodified single-reference signature validates fine at both versions,
// isolating the issue to the splice technique, not a version
// incompatibility) -- the red/green proof below is what actually settles
// v1.4.0-fires / v1.6.0-clean, by building and validating fresh at
// whichever version this module is pinned to.
//
// Oracle (the bypass invariant, success-direction only -- see the package
// doc comment on withinDeadline for why: asserting "must fail" for inputs
// that are still legitimately the signed document, e.g. C14N-equivalent
// whitespace, would false-positive; only "if it succeeds, the content must
// be what was actually signed for that id" is asserted): the harness signs
// a document with its own key, tracking exactly which content it intended
// as authoritative for the validated id (the FIRST Reference, in document
// order, whose URI matches that id -- this is the RFC-correct selection,
// and exactly what v1.6.0's fix implements). If Validate() returns success
// for ANY mutated document, the returned content MUST canonically equal
// that tracked, intended content. Any divergence is a bypass.
package libsextra

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"math/big"
	"testing"
	"time"

	"github.com/beevik/etree"
	dsig "github.com/russellhaering/goxmldsig"
	"github.com/russellhaering/goxmldsig/etreeutils"
)

var (
	dsigKey     *rsa.PrivateKey
	dsigCertDER []byte
	dsigCert    *x509.Certificate
)

func init() {
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	dsigKey = k
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		NotBefore:    time.Now().Add(-24 * time.Hour),
		NotAfter:     time.Now().Add(3650 * 24 * time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &k.PublicKey, k)
	if err != nil {
		panic(err)
	}
	dsigCertDER = der
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		panic(err)
	}
	dsigCert = cert
}

type dsigMemKeyStore struct{}

func (dsigMemKeyStore) GetKeyPair() (*rsa.PrivateKey, []byte, error) {
	return dsigKey, dsigCertDER, nil
}

// dsigRefSpec is one fuzz-chosen (id, content) pair that becomes a
// Reference in the constructed SignedInfo.
type dsigRefSpec struct {
	id      string
	content string
}

// dsigByteConsumer pulls small, deterministic choices off the front of a
// fuzz []byte -- go-fuzz's own coverage-guided mutation explores the space
// this induces (which choices, in what combination) without this harness
// needing its own corpus format.
type dsigByteConsumer struct{ b []byte }

func (c *dsigByteConsumer) byte() byte {
	if len(c.b) == 0 {
		return 0
	}
	v := c.b[0]
	c.b = c.b[1:]
	return v
}

func (c *dsigByteConsumer) intn(n int) int {
	if n <= 0 {
		return 0
	}
	return int(c.byte()) % n
}

func (c *dsigByteConsumer) bool() bool { return c.byte()&1 == 1 }

// A small, fixed pool of ids and content strings. Fuzzing over indices
// into these (rather than raw fuzzed strings for id/content) is what makes
// "duplicating an id" and "content that exactly matches another
// reference's digest" reachable at all -- two independently-fuzzed random
// strings essentially never collide.
var (
	dsigIDPool      = []string{"target", "other", "target", "third"} // "target" repeated on purpose: duplicate-id is cheap to reach
	dsigContentPool = []string{"Content A", "Content B", "Content C"}
)

// FuzzGoXMLDSigReferenceBinding builds a document with a fuzz-chosen set of
// References (order, ids -- including duplicates, content, and whether an
// extra reference the signature never covered gets appended), signs it
// honestly with the harness's own key, mutates the VALIDATED element's URI
// per the fuzz input (re-pointing), and asserts the bypass invariant.
func FuzzGoXMLDSigReferenceBinding(f *testing.F) {
	// Seeds, encoded via the same byte-consumer choices this Fuzz function
	// reads (numRefs, then id/content per ref, then reorder-bool, then
	// append-uncovered-bool, then targetIdx -- in that order; targetIdx is
	// read LAST, after the specs slice has taken its final shape, so a
	// seed's byte layout is stable regardless of whether reorder/append
	// fire).
	//
	// seed#0: trivial two-reference case where both refs for id="target"
	// genuinely agree on content -- the harness's honest baseline, no
	// bypass at any version.
	f.Add([]byte{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00})
	// seed#1: the 1b minimal reproducer's exact shape -- two references
	// for id="target" ("Content A" first, "Content B" last), with the
	// actual signed element (targetIdx=1, last in document order)
	// carrying "Content B". A correct implementation must use the FIRST
	// document-order reference for id="target" (digest of "Content A"),
	// which does not match the real element, and refuse. v1.4.0's
	// loop-variable-capture bug only genuinely checks the LAST reference,
	// so it validates the real element (digest matches) and reports
	// success -- the CVE-2026-33487 bypass. Confirmed red at v1.4.0,
	// green at v1.6.0 (see the Part 1 writeup).
	f.Add([]byte{0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x01})
	// seed#2: three references, reordered, plus an appended uncovered
	// reference -- exercises the reorder/append code paths with a
	// genuinely honest target (no bypass expected at either version).
	f.Add([]byte{0x01, 0x01, 0x00, 0x03, 0x01, 0x00, 0x02, 0x01, 0x02, 0x01, 0x01, 0x02})

	f.Fuzz(func(t *testing.T, data []byte) {
		withinDeadline(t, func() { fuzzGoXMLDSigReferenceBinding(t, data) })
	})
}

func fuzzGoXMLDSigReferenceBinding(t *testing.T, data []byte) {
	c := &dsigByteConsumer{b: data}

	numRefs := 2 + c.intn(3) // 2..4 references
	specs := make([]dsigRefSpec, 0, numRefs)
	for i := 0; i < numRefs; i++ {
		specs = append(specs, dsigRefSpec{
			id:      dsigIDPool[c.intn(len(dsigIDPool))],
			content: dsigContentPool[c.intn(len(dsigContentPool))],
		})
	}

	// Optionally reorder the references (Fisher-Yates driven by fuzz
	// bytes) -- "reordering references". Must happen BEFORE targetIdx is
	// picked below, not after: targetIdx is a plain slice position, and
	// picking it before a later reorder shuffles which spec sits there out
	// from under it -- the ground-truth loop further down would then be
	// scanning a DIFFERENT arrangement than the one targetIdx/wireContent
	// were captured from, corrupting the expected-content computation
	// itself. (Caught this exact bug via a burst against v1.6.0 reporting
	// a "bypass" that was actually a false positive in this harness's own
	// bookkeeping, not the library -- see the Part 1 report.)
	if c.bool() {
		for i := len(specs) - 1; i > 0; i-- {
			j := c.intn(i + 1)
			specs[i], specs[j] = specs[j], specs[i]
		}
	}

	// Optionally append one more reference the signature "never covered"
	// in the sense that it describes neither the wire element's id nor its
	// content -- pure noise the bug might still let win by virtue of being
	// last. Also before targetIdx is picked, for the same reason.
	if c.bool() {
		specs = append(specs, dsigRefSpec{id: "uncovered", content: "Uncovered Content"})
	}

	// Which spec is "the element on the wire" -- the one we'll actually
	// call Validate() on. Picked from the FINAL, settled specs slice, so
	// specs[targetIdx] is guaranteed to still be what wireContent/
	// validateID were captured from.
	targetIdx := c.intn(len(specs))
	validateID := specs[targetIdx].id
	wireContent := specs[targetIdx].content

	signingCtx := dsig.NewDefaultSigningContext(dsigMemKeyStore{})

	// Ground truth: the RFC-correct (and v1.6.0-implemented) selection is
	// the FIRST reference, in the FINAL (possibly reordered) document
	// order, whose id matches validateID. If none match, a correct
	// implementation must refuse (no assertion needed either way here --
	// only a SUCCESS with the wrong content is a bypass).
	expectedContent := ""
	haveExpected := false
	for _, s := range specs {
		if s.id == validateID {
			expectedContent = s.content
			haveExpected = true
			break
		}
	}

	elem, ok := dsigBuildMultiRefDoc(t, signingCtx, specs, targetIdx, wireContent)
	if !ok {
		return // construction failed for a structural/library reason -- not the property under test
	}

	certStore := &dsig.MemoryX509CertificateStore{Roots: []*x509.Certificate{dsigCert}}
	valCtx := dsig.NewDefaultValidationContext(certStore)

	validated, err := valCtx.Validate(elem)
	if err != nil {
		return // rejection is never a failure
	}

	got := validated.Text()
	if !haveExpected {
		t.Fatalf("BYPASS: validated %q as the content of id=%q, but no reference in the document actually covers that id at all", got, validateID)
		return
	}
	if got != expectedContent {
		t.Fatalf("BYPASS: validated content %q for id=%q, but the reference that genuinely matches this id (first match, document order) authorizes %q",
			got, validateID, expectedContent)
	}
}

// dsigBuildMultiRefDoc signs a document containing one element (id =
// specs[targetIdx].id, content = wireContent) whose SignedInfo carries a
// Reference for every entry in specs, in order. Only specs[targetIdx]'s
// reference is guaranteed to describe wireContent (the element's actual
// current bytes) -- every OTHER reference describes ITS OWN spec's
// content, matched against a throwaway element built solely to get a
// correctly-shaped, correctly-computed Reference out of ConstructSignature
// (mirroring the 1b reproducer's approach; hand-building bare <Reference>
// elements hit a namespace-resolution error at validation time -- see the
// package doc comment). Returns ok=false if any step fails for a
// structural/library reason unrelated to the property under test.
func dsigBuildMultiRefDoc(t *testing.T, signingCtx *dsig.SigningContext, specs []dsigRefSpec, targetIdx int, wireContent string) (*etree.Element, bool) {
	t.Helper()

	elem := etree.NewElement("Data")
	elem.CreateAttr("ID", specs[targetIdx].id)
	elem.SetText(wireContent)

	sig, err := signingCtx.ConstructSignature(elem, true)
	if err != nil {
		return nil, false
	}
	signedInfo := sig.FindElement("./SignedInfo")
	targetRef := signedInfo.FindElement("./Reference")

	refs := make([]*etree.Element, len(specs))
	for i, s := range specs {
		if i == targetIdx {
			refs[i] = targetRef
			continue
		}
		decoy := etree.NewElement("Data")
		decoy.CreateAttr("ID", s.id)
		decoy.SetText(s.content)
		decoySig, err := signingCtx.ConstructSignature(decoy, false)
		if err != nil {
			return nil, false
		}
		refs[i] = decoySig.FindElement("./SignedInfo/Reference").Copy()
	}

	for _, child := range signedInfo.ChildElements() {
		if child.Tag == "Reference" {
			signedInfo.RemoveChild(child)
		}
	}
	for _, r := range refs {
		signedInfo.AddChild(r)
	}

	elem.AddChild(sig)

	rootNSCtx, err := etreeutils.NSBuildParentContext(elem)
	if err != nil {
		return nil, false
	}
	elNSCtx, err := rootNSCtx.SubContext(elem)
	if err != nil {
		return nil, false
	}
	sigNSCtx, err := elNSCtx.SubContext(sig)
	if err != nil {
		return nil, false
	}
	detatched, err := etreeutils.NSDetatch(sigNSCtx, signedInfo)
	if err != nil {
		return nil, false
	}
	canonical, err := signingCtx.Canonicalizer.Canonicalize(detatched)
	if err != nil {
		return nil, false
	}
	h := signingCtx.Hash.New()
	h.Write(canonical)
	rawSig, err := rsa.SignPKCS1v15(rand.Reader, dsigKey, signingCtx.Hash, h.Sum(nil))
	if err != nil {
		return nil, false
	}
	sig.FindElement("./SignatureValue").SetText(base64.StdEncoding.EncodeToString(rawSig))

	return elem, true
}

// Content equality in the oracle above is exact-string, not XML-canonical-
// equivalence, because every reference in this harness's construction is a
// single text node with no attributes or nested markup -- there is no
// whitespace/C14N-normalization case that could make two DIFFERENT content
// strings canonically equal, so exact comparison cannot false-positive the
// way it could for richer XML shapes.
