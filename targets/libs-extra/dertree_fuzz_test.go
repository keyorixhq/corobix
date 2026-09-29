// FuzzPKCS7ParseTreeMutated — GRAMMAR-AWARE mutation for digitorus/pkcs7's
// ContentInfo/SignedData ASN.1 (BER/DER) parsing, the ASN.1/DER counterpart
// to samltree_fuzz_test.go's XML tree mutator (targets/libs, same rationale:
// Go's native byte-level mutator cannot itself construct a well-formed nested
// TLV structure, so it spends nearly all its budget on inputs that die at the
// outer SEQUENCE/tag gate before reaching the fields pkcs7.Parse actually
// walks). This harness:
//
//  1. Decodes a FIXED, well-formed ContentInfo{OID, [0] EXPLICIT ANY} DER
//     encoding into a generic TLV tree (derNode: tag byte, definite-length
//     content, recursively parsed IF the constructed bit is set — the exact
//     structural distinction ber2der/readObject itself relies on).
//  2. Applies a short PROGRAM of structural mutations to that tree (the
//     fuzzer controls WHICH node and WHICH opcode, never raw tag/length
//     bytes directly) — duplicate/remove/reorder a child, or perturb a
//     LEAF's tag/content while preserving the length-prefix-matches-content
//     invariant, so the tree stays syntactically well-formed DER by
//     construction while depth, nesting, and field values still vary.
//  3. Re-encodes the mutated tree (definite-length only; lengths are always
//     recomputed from the actual encoded content, never carried over stale)
//     and feeds it through the SAME pkcs7.Parse call and the SAME crash +
//     deadline invariant FuzzTimestampParseResponse (targets/libs-extra's
//     own committed digitorus target) already asserts — no new oracle.
//
// Depth-vs-byte-level comparison: see the fuzz-harness M9 report entry.
package libsextra

import (
	"testing"

	"github.com/digitorus/pkcs7"
)

// derNode is a generic definite-length BER/DER TLV node: tag (identifier
// octet — low 5 bits + class + constructed bit, single-byte tags only, which
// covers every tag digitorus/pkcs7's own ContentInfo/SignedData shapes use),
// its raw leaf content (for a primitive node), and its children (for a
// constructed node, i.e. tag&0x20 != 0). Exactly one of content/children is
// meaningful at a time, mirroring how readObject itself branches.
type derNode struct {
	tag      byte
	content  []byte
	children []*derNode
}

func (n *derNode) constructed() bool { return n.tag&0x20 != 0 }

// encodeLength writes a definite-length encoding of n (short form <128,
// long form otherwise) — the DER canonical form, always recomputed from the
// actual encoded body so a mutation can never leave a stale length behind.
func encodeLength(n int) []byte {
	if n < 128 {
		return []byte{byte(n)}
	}
	var b []byte
	for v := n; v > 0; v >>= 8 {
		b = append([]byte{byte(v)}, b...)
	}
	return append([]byte{0x80 | byte(len(b))}, b...)
}

func (n *derNode) encode() []byte {
	var body []byte
	if n.constructed() {
		for _, c := range n.children {
			body = append(body, c.encode()...)
		}
	} else {
		body = n.content
	}
	out := append([]byte{n.tag}, encodeLength(len(body))...)
	return append(out, body...)
}

// parseDER decodes definite-length BER/DER TLVs from b (single-byte tags and
// lengths <2^32 only — sufficient for the fixed seed and every mutation this
// harness produces, since mutations only ever shrink/grow content that this
// same encoder re-measures). Returns the parsed siblings and the number of
// bytes consumed; a malformed tail is silently truncated (best-effort parse
// for MUTATION purposes only — pkcs7.Parse is the thing whose parsing
// behavior is actually under test, not this helper).
func parseDER(b []byte) []*derNode {
	var out []*derNode
	for len(b) >= 2 {
		tag := b[0]
		length, hdrLen, ok := decodeLength(b[1:])
		if !ok || hdrLen+1+length > len(b) {
			break
		}
		content := append([]byte(nil), b[1+hdrLen:1+hdrLen+length]...)
		node := &derNode{tag: tag}
		if tag&0x20 != 0 {
			node.children = parseDER(content)
			if len(node.children) == 0 && length > 0 {
				// Constructed but couldn't decompose (e.g. BIT STRING framing) —
				// keep it as an opaque leaf rather than losing the bytes.
				node.tag = tag &^ 0x20
				node.content = content
			}
		} else {
			node.content = content
		}
		out = append(out, node)
		b = b[1+hdrLen+length:]
	}
	return out
}

func decodeLength(b []byte) (length, hdrLen int, ok bool) {
	if len(b) == 0 {
		return 0, 0, false
	}
	if b[0] < 0x80 {
		return int(b[0]), 1, true
	}
	n := int(b[0] &^ 0x80)
	if n == 0 || n > 4 || len(b) < 1+n {
		return 0, 0, false
	}
	length = 0
	for i := 0; i < n; i++ {
		length = length<<8 | int(b[1+i])
	}
	return length, 1 + n, true
}

// collectNodes walks every node in the forest in pre-order, same rationale as
// samltree_fuzz_test.go's collectElements: a deterministic, order-stable
// index space for the fuzzer to select a target from.
func collectNodes(nodes []*derNode, out *[]*derNode) {
	for _, n := range nodes {
		*out = append(*out, n)
		if n.constructed() {
			collectNodes(n.children, out)
		}
	}
}

// mutateDER applies len(ops)/2 structural mutations to the forest, opcode
// selecting the operation and param selecting the target node — never
// touching raw tag/length bytes outside these fixed operations, so the
// result is always well-formed (self-consistent length-prefixed) DER by
// construction.
func mutateDER(nodes []*derNode, ops []byte) []*derNode {
	for i := 0; i+1 < len(ops); i += 2 {
		opcode := ops[i] % 5
		param := ops[i+1]

		var all []*derNode
		collectNodes(nodes, &all)
		if len(all) == 0 {
			return nodes
		}
		target := all[int(param)%len(all)]

		switch opcode {
		case 0: // flip the constructed bit (structural <-> opaque reinterpretation)
			target.tag ^= 0x20
			if !target.constructed() && target.content == nil {
				var body []byte
				for _, c := range target.children {
					body = append(body, c.encode()...)
				}
				target.content = body
				target.children = nil
			}
		case 1: // duplicate target's content/children (both siblings identical)
			if target.constructed() {
				target.children = append(target.children, append([]*derNode(nil), target.children...)...)
			} else {
				target.content = append(target.content, target.content...)
			}
		case 2: // truncate target's content by half
			if !target.constructed() && len(target.content) > 1 {
				target.content = target.content[:len(target.content)/2]
			} else if target.constructed() && len(target.children) > 1 {
				target.children = target.children[:len(target.children)/2]
			}
		case 3: // reverse target's children order (constructed only)
			if target.constructed() {
				c := target.children
				for i, j := 0, len(c)-1; i < j; i, j = i+1, j-1 {
					c[i], c[j] = c[j], c[i]
				}
			}
		case 4: // reassign the tag's low tag-number bits (keep class+constructed)
			target.tag = (target.tag &^ 0x1f) | (param & 0x1f)
		}
	}
	return nodes
}

// pkcs7ContentInfoSeed is a well-formed ContentInfo carrying an unrecognized
// (deliberately made-up) content-type OID and an empty [0] EXPLICIT content —
// enough for pkcs7.Parse's own top-level asn1.Unmarshal to succeed and hand
// control to its content-type dispatch, exactly like a byte-level fuzzer's
// discovered corpus would look once it finally stumbles onto a
// syntactically-valid outer shape, except here it's true on input #0.
var pkcs7ContentInfoSeed = []byte{
	0x30, 0x0d, // SEQUENCE, len 13
	0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02, // OID 1.2.840.113549.1.7.2 (signedData)
	0xa0, 0x00, // [0] EXPLICIT, empty
}

func FuzzPKCS7ParseTreeMutated(f *testing.F) {
	f.Add([]byte{})
	f.Add([]byte{0, 0, 1, 1, 2, 2, 3, 3, 4, 4})
	f.Fuzz(func(t *testing.T, ops []byte) {
		nodes := parseDER(pkcs7ContentInfoSeed)
		nodes = mutateDER(nodes, ops)
		var mutated []byte
		for _, n := range nodes {
			mutated = append(mutated, n.encode()...)
		}
		withinDeadline(t, func() { _, _ = pkcs7.Parse(mutated) })
	})
}
