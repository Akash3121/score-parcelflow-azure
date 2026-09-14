package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/Akash3121/score-parcelflow-azure/internal/client"
	"github.com/Akash3121/score-parcelflow-azure/internal/domain"
)

func main() {
	baseURL := flag.String("base-url", env("PARCELFLOW_BASE_URL", "http://localhost:8080"), "ParcelFlow API base URL")
	fixture := flag.String("fixture", env("PARCELFLOW_PROOF_FIXTURE", "testdata/proof.pdf"), "fixed proof fixture")
	timeout := flag.Duration("timeout", 2*time.Minute, "overall smoke timeout")
	flag.Parse()
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	if err := smoke(ctx, client.New(*baseURL), *fixture); err != nil {
		fmt.Fprintln(os.Stderr, "SMOKE FAILED:", err)
		os.Exit(1)
	}
	fmt.Println("SMOKE PASSED: health, seed, create, asynchronous lifecycle, idempotency, and proof verified")
}

func smoke(ctx context.Context, api *client.Client, fixturePath string) error {
	step := func(name string) { fmt.Println("check:", name) }
	step("liveness")
	if err := api.Health(ctx, "live"); err != nil {
		return err
	}
	step("readiness")
	if err := api.Health(ctx, "ready"); err != nil {
		return err
	}
	step("deterministic seed")
	seed, err := api.Get(ctx, "PF-DEMO000001")
	if err != nil {
		return err
	}
	if seed.RecipientName != "Avery Stone" || seed.Status != domain.LabelCreated {
		return fmt.Errorf("seed mismatch: got recipient=%q status=%q", seed.RecipientName, seed.Status)
	}

	runID := domain.NewID()
	createKey := "smoke-create-" + runID
	input := domain.CreateParcel{RecipientName: "Smoke Test Recipient", DeliveryAddress: "404 Deterministic Drive, Testville"}
	step("unique parcel creation")
	parcel, replay, err := api.Create(ctx, input, createKey)
	if err != nil {
		return err
	}
	if replay || parcel.Status != domain.LabelCreated {
		return fmt.Errorf("unexpected create response: replay=%v status=%s", replay, parcel.Status)
	}
	duplicate, replay, err := api.Create(ctx, input, createKey)
	if err != nil || !replay || duplicate.TrackingID != parcel.TrackingID {
		return fmt.Errorf("create idempotency failed: replay=%v tracking=%s err=%v", replay, duplicate.TrackingID, err)
	}

	for i, expected := range []domain.Status{domain.PickedUp, domain.AtSortingCenter, domain.InTransit, domain.OutForDelivery, domain.Delivered} {
		step("asynchronous advance to " + string(expected))
		key := fmt.Sprintf("smoke-advance-%s-%d", runID, i)
		command, replay, err := api.Advance(ctx, parcel.TrackingID, key)
		if err != nil || replay {
			return fmt.Errorf("accept advance: replay=%v err=%v", replay, err)
		}
		repeated, replay, err := api.Advance(ctx, parcel.TrackingID, key)
		if err != nil || !replay || repeated.ID != command.ID {
			return fmt.Errorf("advance idempotency failed: first=%s repeated=%s replay=%v err=%v", command.ID, repeated.ID, replay, err)
		}
		parcel, err = waitForStatus(ctx, api, parcel.TrackingID, expected)
		if err != nil {
			return err
		}
		if got, want := len(parcel.Events), i+2; got != want {
			return fmt.Errorf("duplicate transition detected at %s: got %d events, want %d", expected, got, want)
		}
	}

	step("proof upload")
	fixture, err := os.ReadFile(fixturePath)
	if err != nil {
		return fmt.Errorf("read proof fixture %s: %w", fixturePath, err)
	}
	sum := sha256.Sum256(fixture)
	checksum := hex.EncodeToString(sum[:])
	proofKey := "smoke-proof-" + runID
	proof, replay, err := api.UploadProof(ctx, parcel.TrackingID, proofKey, "application/pdf", fixture)
	if err != nil || replay || proof.SHA256 != checksum || proof.ContentType != "application/pdf" {
		return fmt.Errorf("proof upload mismatch: replay=%v checksum=%s contentType=%s err=%v", replay, proof.SHA256, proof.ContentType, err)
	}
	step("proof download checksum and media type")
	download, err := api.DownloadProof(ctx, parcel.TrackingID)
	if err != nil {
		return err
	}
	downloadSum := sha256.Sum256(download.Body)
	if hex.EncodeToString(downloadSum[:]) != checksum || download.Header.Get("Content-Type") != "application/pdf" {
		return fmt.Errorf("download mismatch: checksum=%s contentType=%s", hex.EncodeToString(downloadSum[:]), download.Header.Get("Content-Type"))
	}
	step("proof idempotent reupload")
	repeatedProof, replay, err := api.UploadProof(ctx, parcel.TrackingID, proofKey, "application/pdf", fixture)
	if err != nil || !replay || repeatedProof.SHA256 != checksum {
		return fmt.Errorf("proof reupload failed: replay=%v checksum=%s err=%v", replay, repeatedProof.SHA256, err)
	}
	return nil
}

func waitForStatus(ctx context.Context, api *client.Client, trackingID string, expected domain.Status) (domain.Parcel, error) {
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	timeout := time.NewTimer(20 * time.Second)
	defer timeout.Stop()
	for {
		parcel, err := api.Get(ctx, trackingID)
		if err != nil {
			return domain.Parcel{}, err
		}
		if parcel.Status == expected {
			return parcel, nil
		}
		select {
		case <-ctx.Done():
			return domain.Parcel{}, ctx.Err()
		case <-timeout.C:
			return domain.Parcel{}, fmt.Errorf("timed out waiting for %s; current status is %s", expected, parcel.Status)
		case <-ticker.C:
		}
	}
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
