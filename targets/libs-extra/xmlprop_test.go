package libsextra

import (
	"bytes"
	"encoding/xml"
	"io"
	"testing"

	xmlvalidator "github.com/mattermost/xml-roundtrip-validator"
)

func xmlTokens(data []byte) ([]xml.Token, error) {
	dec := xml.NewDecoder(bytes.NewReader(data))
	dec.Strict = false
	var toks []xml.Token
	for {
		tok, err := dec.RawToken()
		if err == io.EOF {
			return toks, nil
		}
		if err != nil {
			return toks, err
		}
		toks = append(toks, xml.CopyToken(tok))
	}
}

// FuzzXMLRoundtripProperty attempts the validator's SECURITY PROPERTY: if Validate
// passes (claims the XML round-trips unambiguously), re-encoding its token stream and
// re-tokenizing must be stable. A pass on a non-stable doc would be a wrapping false
// negative. NOTE: this is the "let evidence decide" experiment — encoding/xml re-encode
// may normalize benignly, which would make this unsound.
func FuzzXMLRoundtripProperty(f *testing.F) {
	f.Add([]byte(`<a x="1"><b>text</b></a>`))
	f.Fuzz(func(t *testing.T, data []byte) {
		// Work runs under the per-input deadline; the t.Fatal assertions stay OUTSIDE
		// the guarded closure — t.Fatal only fires on the test's own goroutine, not
		// the child goroutine withinDeadline runs fn in.
		var (
			checked    bool
			n1, n2     int
			reparseErr error
		)
		withinDeadline(t, func() {
			if xmlvalidator.Validate(bytes.NewReader(data)) != nil {
				return
			}
			t1, e1 := xmlTokens(data)
			if e1 != nil {
				return
			}
			var buf bytes.Buffer
			enc := xml.NewEncoder(&buf)
			for _, tok := range t1 {
				if err := enc.EncodeToken(tok); err != nil {
					return
				}
			}
			if err := enc.Flush(); err != nil {
				return
			}
			t2, e2 := xmlTokens(buf.Bytes())
			checked, n1, n2, reparseErr = true, len(t1), len(t2), e2
		})
		if !checked {
			return
		}
		if reparseErr != nil {
			t.Fatalf("validator passed but re-encoded form fails to re-parse: %v (data=%q)", reparseErr, data)
		}
		if n1 != n2 {
			t.Fatalf("validator passed non-round-trip-stable XML: %d vs %d tokens (data=%q)", n1, n2, data)
		}
	})
}
