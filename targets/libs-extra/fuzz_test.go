// libs-extra fuzz harness — third-party candidate parsers that take untrusted
// input and are NOT fuzzed upstream. Detection layers, beyond what native go-fuzz
// gives on its own:
//   - panics/crashes         (native)
//   - OOM / memory blow-up   (rig cgroup MemoryMax)
//   - CPU-time / algorithmic-complexity DoS  (per-input deadline, below)
//   - correctness / wrong-but-not-crashing   (invariants, below)
//
// Versions pinned to what keyorix ships.
package libsextra

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"testing"
	"time"

	"github.com/beevik/etree"
	"github.com/crewjam/saml/xmlenc"
	"github.com/digitorus/timestamp"
	xmlvalidator "github.com/mattermost/xml-roundtrip-validator"
)

// perInputDeadline bounds a single input. Parsers on fuzz-sized inputs are
// sub-millisecond, so a large margin trips only on a genuine complexity blow-up.
// Native go-fuzz has NO per-input timeout, so without this a CPU-DoS input merely
// drags throughput instead of being flagged as a crasher.
const perInputDeadline = 2 * time.Second

// withinDeadline fails the input if fn does not return within perInputDeadline.
// A panic in fn still propagates and crashes the worker (native crasher detection);
// the helper only adds hang/CPU-DoS detection. On a genuine hang the goroutine leaks
// until the worker exits on the resulting t.Fatal, so nothing lingers.
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

var xmlencKey *rsa.PrivateKey

func init() {
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	xmlencKey = k
}

// FuzzXMLEncDecrypt — crash + deadline. No cheap sound correctness invariant
// (successful decryption needs a matching key); value is the etree/xmlenc parse
// paths neither crashing nor hanging on hostile XML.
func FuzzXMLEncDecrypt(f *testing.F) {
	f.Add([]byte(`<EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#"><CipherData><CipherValue>AA==</CipherValue></CipherData></EncryptedData>`))
	f.Fuzz(func(t *testing.T, data []byte) {
		withinDeadline(t, func() {
			doc := etree.NewDocument()
			if err := doc.ReadFromBytes(data); err != nil {
				return
			}
			if doc.Root() == nil {
				return
			}
			_, _ = xmlenc.Decrypt(xmlencKey, doc.Root())
		})
	})
}

// FuzzXMLRoundtripValidate — crash + deadline only. A correctness invariant here
// would need an XML oracle independent of encoding/xml (the validator IS built on
// encoding/xml, and Validate/ValidateAll share code, so any check against them is
// tautological). Left as a future differential.
func FuzzXMLRoundtripValidate(f *testing.F) {
	f.Add([]byte(`<a x="1"><b>text</b></a>`))
	f.Fuzz(func(t *testing.T, data []byte) {
		withinDeadline(t, func() { _ = xmlvalidator.Validate(bytes.NewReader(data)) })
	})
}

// FuzzTimestampParseResponse — crash + deadline. Was EXCLUDEd on the (now-
// decommissioned) rig's box-local fuzz.conf pending an upstream digitorus/pkcs7
// ber.go OOB-panic fix. Verified 2026-09-22: the panic reproduces on the old
// pin but not on the pin this module now carries (matches what keyorix
// ships) -- re-enabled, no EXCLUDE in examples/libs-extra.conf.
func FuzzTimestampParseResponse(f *testing.F) {
	f.Add([]byte{0x30, 0x03, 0x02, 0x01, 0x00})
	f.Fuzz(func(t *testing.T, data []byte) {
		withinDeadline(t, func() { _, _ = timestamp.ParseResponse(data) })
	})
}

// FuzzTimestampParseRequest — crash + deadline + round-trip INVARIANT.
// Invariant: a request that parses must survive Marshal → ParseRequest with its core
// fields intact. Marshal and ParseRequest are independent code paths, so a divergence
// (or a re-parse failure of the library's own output) is a real parse/marshal
// asymmetry — a class crash-only fuzzing cannot see.
func FuzzTimestampParseRequest(f *testing.F) {
	f.Add([]byte{0x30, 0x03, 0x02, 0x01, 0x01})
	// A genuinely well-formed RFC3161 request — pushes the parser past the header
	// into field decoding, which the minimal DER seed never reaches.
	if b, err := (&timestamp.Request{HashAlgorithm: crypto.SHA256, HashedMessage: make([]byte, 32)}).Marshal(); err == nil {
		f.Add(b)
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		var req *timestamp.Request
		var err error
		withinDeadline(t, func() { req, err = timestamp.ParseRequest(data) })
		if err != nil || req == nil {
			return
		}
		out, merr := req.Marshal()
		if merr != nil {
			return // Marshal legitimately declining an edge case is not a bug.
		}
		req2, err2 := timestamp.ParseRequest(out)
		if err2 != nil || req2 == nil {
			t.Fatalf("round-trip: library re-parse of its own Marshal output failed: %v", err2)
		}
		if req.HashAlgorithm != req2.HashAlgorithm || !bytes.Equal(req.HashedMessage, req2.HashedMessage) {
			t.Fatalf("round-trip: core request fields diverged after Marshal→ParseRequest")
		}
	})
}
