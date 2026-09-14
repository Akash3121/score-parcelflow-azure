package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/Akash3121/score-parcelflow-azure/internal/config"
	"github.com/Akash3121/score-parcelflow-azure/internal/httpapi"
	"github.com/Akash3121/score-parcelflow-azure/internal/logging"
	"github.com/Akash3121/score-parcelflow-azure/internal/objectstore"
	"github.com/Akash3121/score-parcelflow-azure/internal/outbox"
	"github.com/Akash3121/score-parcelflow-azure/internal/queue"
	"github.com/Akash3121/score-parcelflow-azure/internal/store"
)

func main() {
	if err := run(); err != nil {
		slog.Error("parcel-api stopped", "error", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	logger := logging.New(cfg.Environment, "parcel-api").With("build_sha", cfg.BuildSHA)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	database, err := store.Open(ctx, cfg.Database.URL())
	if err != nil {
		return err
	}
	defer database.Close()
	migrationCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	err = database.Migrate(migrationCtx)
	cancel()
	if err != nil {
		return fmt.Errorf("database migration failed: %w", err)
	}
	objects, err := objectstore.New(ctx, cfg.ObjectStore)
	if err != nil {
		return err
	}
	publisherQueue, err := queue.NewPublisher(ctx, cfg.Queue)
	if err != nil {
		return err
	}
	defer publisherQueue.Close(context.Background())

	publisher := &outbox.Publisher{Store: database, Queue: publisherQueue, Logger: logger}
	publisherErrors := make(chan error, 1)
	go func() { publisherErrors <- publisher.Run(ctx) }()

	api := httpapi.New(database, objects, logger, cfg.Environment, cfg.BuildSHA)
	server := &http.Server{
		Addr:              fmt.Sprintf(":%d", cfg.HTTPPort),
		Handler:           api.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    32 << 10,
	}
	serverErrors := make(chan error, 1)
	go func() {
		logger.Info("API listening", "port", cfg.HTTPPort)
		serverErrors <- server.ListenAndServe()
	}()
	select {
	case <-ctx.Done():
	case err := <-publisherErrors:
		if err != nil && !errors.Is(err, context.Canceled) {
			return fmt.Errorf("outbox publisher stopped: %w", err)
		}
	case err := <-serverErrors:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	}
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()
	return server.Shutdown(shutdownCtx)
}
