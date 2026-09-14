package objectstore

import (
	"context"
	"io"
	"os"
	"testing"
	"time"

	"github.com/Akash3121/score-parcelflow-azure/internal/config"
	"github.com/Akash3121/score-parcelflow-azure/internal/domain"
)

func TestBlobRoundTripIntegration(t *testing.T) {
	endpoint := os.Getenv("PARCELFLOW_TEST_BLOB_ENDPOINT")
	if endpoint == "" {
		t.Skip("PARCELFLOW_TEST_BLOB_ENDPOINT is not set")
	}
	account := os.Getenv("PARCELFLOW_TEST_BLOB_ACCOUNT")
	key := os.Getenv("PARCELFLOW_TEST_BLOB_KEY")
	if account == "" || key == "" {
		t.Skip("PARCELFLOW_TEST_BLOB_ACCOUNT and PARCELFLOW_TEST_BLOB_KEY are not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	store, err := New(ctx, config.ObjectStore{
		Provider: "azurite", Endpoint: endpoint, Container: "parcelflow-tests",
		CredentialMode: "shared-key", AccountName: account, AccountKey: key,
	})
	if err != nil {
		t.Fatalf("connect to configured blob service: %v", err)
	}
	objectKey := "integration/" + domain.NewID()
	want := []byte("fixed integration object")
	if err := store.Put(ctx, objectKey, "application/octet-stream", want); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Delete(context.Background(), objectKey) })
	body, err := store.Get(ctx, objectKey)
	if err != nil {
		t.Fatal(err)
	}
	defer body.Close()
	got, err := io.ReadAll(body)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Fatalf("got %q, want %q", got, want)
	}
}
