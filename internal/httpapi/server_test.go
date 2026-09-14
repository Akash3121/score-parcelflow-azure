package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"
)

func TestContentValidation(t *testing.T) {
	tests := []struct {
		contentType string
		data        []byte
		want        bool
	}{
		{"application/pdf", []byte("%PDF-1.4\n"), true},
		{"application/pdf", []byte("not pdf"), false},
		{"image/png", append([]byte{0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a}, make([]byte, 504)...), true},
	}
	for _, test := range tests {
		if got := contentMatches(test.contentType, test.data); got != test.want {
			t.Errorf("contentMatches(%q)=%v, want %v", test.contentType, got, test.want)
		}
	}
}

func TestDecodeJSONRejectsUnknownAndMultipleValues(t *testing.T) {
	for _, body := range []string{`{"recipientName":"A","unknown":1}`, `{"recipientName":"A"} {}`} {
		request := httptest.NewRequest("POST", "/", bytes.NewBufferString(body))
		request.Header.Set("Content-Type", "application/json")
		recorder := httptest.NewRecorder()
		var value struct {
			RecipientName string `json:"recipientName"`
		}
		if err := decodeJSON(recorder, request, &value, 1024); err == nil {
			t.Fatalf("accepted invalid body %s", body)
		}
	}
}

func TestAllowedProofTypes(t *testing.T) {
	for _, value := range []string{"application/pdf", "image/jpeg", "image/png"} {
		if !allowedContentType(value) {
			t.Errorf("%s should be allowed", value)
		}
	}
	if allowedContentType("text/html") {
		t.Fatal("HTML must not be accepted")
	}
}

func TestProblemUsesRFC7807MediaType(t *testing.T) {
	server := &Server{}
	request := httptest.NewRequest("GET", "/missing", nil)
	request = request.WithContext(context.WithValue(request.Context(), requestIDKey, "request-1234"))
	recorder := httptest.NewRecorder()
	server.writeProblem(recorder, request, 404, "Not Found", "Missing.")
	if got := recorder.Header().Get("Content-Type"); got != "application/problem+json" {
		t.Fatalf("Content-Type=%q", got)
	}
	var value problem
	if err := json.Unmarshal(recorder.Body.Bytes(), &value); err != nil {
		t.Fatal(err)
	}
	if value.Status != 404 || value.RequestID != "request-1234" {
		t.Fatalf("unexpected problem: %+v", value)
	}
}
