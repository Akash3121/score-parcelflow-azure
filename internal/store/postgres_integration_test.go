package store

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/Akash3121/score-parcelflow-azure/internal/domain"
)

func TestPostgresLifecycleIntegration(t *testing.T) {
	dsn := os.Getenv("PARCELFLOW_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("PARCELFLOW_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	db, err := Open(ctx, dsn)
	if err != nil {
		t.Fatalf("connect to configured PostgreSQL: %v", err)
	}
	defer db.Close()
	if err := db.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	key := "integration-create-" + domain.NewID()
	p, replay, err := db.CreateParcel(ctx, domain.CreateParcel{RecipientName: "Integration User", DeliveryAddress: "100 Test Avenue"}, key, "integration")
	if err != nil || replay {
		t.Fatalf("create: replay=%v err=%v", replay, err)
	}
	p2, replay, err := db.CreateParcel(ctx, domain.CreateParcel{RecipientName: "Integration User", DeliveryAddress: "100 Test Avenue"}, key, "integration")
	if err != nil || !replay || p2.TrackingID != p.TrackingID {
		t.Fatalf("idempotent create failed: replay=%v err=%v", replay, err)
	}
	command, replay, err := db.Advance(ctx, p.TrackingID, "integration-advance-"+domain.NewID(), "integration")
	if err != nil || replay {
		t.Fatalf("advance: replay=%v err=%v", replay, err)
	}
	if err := db.ProcessCommand(ctx, command); err != nil {
		t.Fatal(err)
	}
	if err := db.ProcessCommand(ctx, command); err != nil {
		t.Fatalf("duplicate command was not idempotent: %v", err)
	}
	got, err := db.GetParcel(ctx, p.TrackingID)
	if err != nil || got.Status != domain.PickedUp || len(got.Events) != 2 {
		t.Fatalf("unexpected parcel: status=%s events=%d err=%v", got.Status, len(got.Events), err)
	}
}
