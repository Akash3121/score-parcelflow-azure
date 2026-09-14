package main

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/Akash3121/score-parcelflow-azure/internal/config"
	"github.com/Akash3121/score-parcelflow-azure/internal/logging"
	"github.com/Akash3121/score-parcelflow-azure/internal/queue"
	"github.com/Akash3121/score-parcelflow-azure/internal/store"
	deliveryworker "github.com/Akash3121/score-parcelflow-azure/internal/worker"
)

func main() {
	if err := run(); err != nil && !errors.Is(err, context.Canceled) {
		slog.Error("delivery-worker stopped", "error", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.LoadWorker()
	if err != nil {
		return err
	}
	logger := logging.New(cfg.Environment, "delivery-worker").With("build_sha", cfg.BuildSHA)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	database, err := store.Open(ctx, cfg.Database.URL())
	if err != nil {
		return err
	}
	defer database.Close()
	consumer, err := queue.NewConsumer(ctx, cfg.Queue)
	if err != nil {
		return err
	}
	defer consumer.Close(context.Background())
	logger.Info("worker consuming", "provider", cfg.Queue.Provider, "queue", cfg.Queue.Name)
	return (&deliveryworker.Worker{Store: database, Queue: consumer, Logger: logger}).Run(ctx)
}
