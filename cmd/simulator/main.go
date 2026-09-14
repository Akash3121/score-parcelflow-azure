package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/Akash3121/score-parcelflow-azure/internal/client"
	"github.com/Akash3121/score-parcelflow-azure/internal/domain"
)

func main() {
	baseURL := flag.String("base-url", env("PARCELFLOW_BASE_URL", "http://localhost:8080"), "ParcelFlow API base URL")
	trackingID := flag.String("tracking-id", "PF-DEMO000001", "parcel to advance")
	interval := flag.Duration("interval", 2*time.Second, "delay between transitions")
	run := flag.Bool("run", false, "explicitly enable the simulator")
	flag.Parse()
	if !*run && os.Getenv("SIMULATOR_ENABLED") != "true" {
		fmt.Fprintln(os.Stderr, "simulator is opt-in; pass -run or set SIMULATOR_ENABLED=true")
		os.Exit(2)
	}
	if err := simulate(context.Background(), client.New(*baseURL), *trackingID, *interval); err != nil {
		fmt.Fprintln(os.Stderr, "simulator:", err)
		os.Exit(1)
	}
}

func simulate(ctx context.Context, api *client.Client, trackingID string, interval time.Duration) error {
	for {
		parcel, err := api.Get(ctx, trackingID)
		if err != nil {
			return err
		}
		if parcel.Status == domain.Delivered {
			fmt.Printf("%s delivered\n", trackingID)
			return nil
		}
		next, _ := domain.Next(parcel.Status)
		key := fmt.Sprintf("simulator-%s-%s", trackingID, next)
		if _, _, err := api.Advance(ctx, trackingID, key); err != nil {
			return err
		}
		deadline := time.Now().Add(30 * time.Second)
		for {
			if time.Now().After(deadline) {
				return fmt.Errorf("timed out waiting for %s", next)
			}
			time.Sleep(500 * time.Millisecond)
			current, err := api.Get(ctx, trackingID)
			if err != nil {
				return err
			}
			if current.Status == next {
				fmt.Printf("%s -> %s\n", trackingID, next)
				break
			}
		}
		time.Sleep(interval)
	}
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
