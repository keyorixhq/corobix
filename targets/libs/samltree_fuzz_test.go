// FuzzSAMLParseXMLResponseTreeMutated — GRAMMAR-AWARE mutation for the same
// crewjam/saml ParseXMLResponse target FuzzSAMLParseXMLResponse already
// covers with raw byte-level mutation. Go's native fuzzing engine only
// mutates bytes; it cannot itself produce well-formed nested XML, so a
// byte-level mutator spends nearly all its budget on inputs that die at the
// XML syntax gate before ever reaching xrv/dsig/assertion parsing. This
// harness instead:
//
//  1. Parses a FIXED, well-formed SAML Response skeleton into an etree tree
//     (ALWAYS syntactically valid XML, by construction).
//  2. Applies a short PROGRAM of structural mutations to that tree — the
//     fuzzer controls WHICH element and WHICH opcode, never raw XML syntax
//     — using mutateTree (shared, deterministic, no randomness).
//  3. Re-serializes the mutated tree and feeds it through the EXACT SAME
//     sp.ParseXMLResponse call and the EXACT SAME "must always error"
//     invariant FuzzSAMLParseXMLResponse already asserts (the SP's IdP
//     signing cert's private key is never held by the fuzzer, so no crafted
//     response can carry a valid signature). No new oracle, no new
//     judgment — same sound invariant, deeper reach.
//
// Depth-vs-byte-level comparison: see targets/README.md addendum / the
// corobix M9 report entry for the measured corpus-growth comparison
// against FuzzSAMLParseXMLResponse over an identical time budget.
package libsfuzz

import (
	"net/url"
	"testing"

	"github.com/beevik/etree"
)

const samlTreeMutatedSeed = `<?xml version="1.0"?>
<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ID="r1" Version="2.0" IssueInstant="2026-01-01T00:00:00Z" Destination="https://sp.example.com/saml/acs">
  <saml:Issuer>https://idp.example.com/metadata</saml:Issuer>
  <samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status>
  <saml:Assertion ID="a1" Version="2.0" IssueInstant="2026-01-01T00:00:00Z">
    <saml:Issuer>https://idp.example.com/metadata</saml:Issuer>
    <saml:Subject>
      <saml:NameID Format="urn:oasis:names:tc:SAML:2.0:nameid-format:persistent">user-1</saml:NameID>
      <saml:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer">
        <saml:SubjectConfirmationData Recipient="https://sp.example.com/saml/acs" NotOnOrAfter="2099-01-01T00:00:00Z"/>
      </saml:SubjectConfirmation>
    </saml:Subject>
    <saml:Conditions NotBefore="2026-01-01T00:00:00Z" NotOnOrAfter="2099-01-01T00:00:00Z">
      <saml:AudienceRestriction><saml:Audience>https://sp.example.com/saml/metadata</saml:Audience></saml:AudienceRestriction>
    </saml:Conditions>
    <saml:AttributeStatement>
      <saml:Attribute Name="email"><saml:AttributeValue>u@example.com</saml:AttributeValue></saml:Attribute>
    </saml:AttributeStatement>
  </saml:Assertion>
</samlp:Response>`

// collectElements walks e and its descendants in document order (pre-order),
// so a fuzzer-chosen index always resolves to the SAME element for the SAME
// tree shape regardless of prior mutations in the same run.
func collectElements(e *etree.Element, out *[]*etree.Element) {
	if e == nil {
		return
	}
	*out = append(*out, e)
	for _, c := range e.ChildElements() {
		collectElements(c, out)
	}
}

// mutateTree applies len(ops) structural mutations to doc's tree, one per
// byte pair in ops (opcode, param) — never touching XML syntax directly, so
// the result is always well-formed XML for etree to re-serialize. Opcodes
// with no valid target (e.g. duplicating the document root, which has no
// parent to attach a sibling to) are silently no-ops — this keeps the
// mutation space total (every byte sequence is a valid program) without
// ever panicking on an edge case.
func mutateTree(doc *etree.Document, ops []byte) {
	for i := 0; i+1 < len(ops); i += 2 {
		opcode := ops[i] % 7
		param := ops[i+1]

		var elems []*etree.Element
		collectElements(doc.Root(), &elems)
		if len(elems) == 0 {
			return
		}
		target := elems[int(param)%len(elems)]
		parent := target.Parent()

		switch opcode {
		case 0: // duplicate target as a following sibling under the same parent
			if parent != nil {
				if next := target.NextSibling(); next != nil {
					parent.InsertChild(next, target.Copy())
				} else {
					parent.AddChild(target.Copy())
				}
			}
		case 1: // strip all attributes
			for _, a := range append([]etree.Attr(nil), target.Attr...) {
				target.RemoveAttr(a.Key)
			}
		case 2: // mutate text content
			target.SetText(target.Text() + "\x00<injected/>")
		case 3: // wrap a comment inside the target
			target.CreateComment("mutated")
		case 4: // reorder attributes (name-sorted — a real permutation when >1 attr)
			target.SortAttrs()
		case 5: // remove the target from its parent (structural deletion)
			if parent != nil {
				parent.RemoveChild(target)
			}
		case 6: // re-tag: same element, mutated namespace prefix
			if target.Space != "" {
				target.Space = target.Space + "x"
			} else {
				target.Tag = target.Tag + "x"
			}
		}
	}
}

func FuzzSAMLParseXMLResponseTreeMutated(f *testing.F) {
	sp := newTestSP()
	cur := url.URL{Scheme: "https", Host: "sp.example.com", Path: "/saml/acs"}
	f.Add([]byte{})
	f.Add([]byte{0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6})
	f.Fuzz(func(t *testing.T, ops []byte) {
		doc := etree.NewDocument()
		if err := doc.ReadFromString(samlTreeMutatedSeed); err != nil {
			t.Fatalf("fixed seed failed to parse — harness bug, not a fuzz finding: %v", err)
		}
		mutateTree(doc, ops)
		mutated, err := doc.WriteToBytes()
		if err != nil {
			return // a mutation etree itself refuses to serialize is not a finding
		}

		var perr error
		withinDeadline(t, func() { _, perr = sp.ParseXMLResponse(mutated, []string{"r1"}, cur) })
		if perr == nil {
			t.Fatalf("SAML SIGNATURE BYPASS via tree-mutated input: ParseXMLResponse accepted a response we never signed (ops=%x)\nmutated XML:\n%s", ops, mutated)
		}
	})
}
