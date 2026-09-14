package worker

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"

	"github.com/Akash3121/score-parcelflow-azure/internal/domain"
	"github.com/Akash3121/score-parcelflow-azure/internal/queue"
	"github.com/Akash3121/score-parcelflow-azure/internal/store"
)

type Worker struct {
	Store  Processor
	Queue  queue.Consumer
	Logger *slog.Logger
}

type Processor interface {
	ProcessCommand(context.Context, domain.Command) error
}

func (w *Worker) Run(ctx context.Context) error {
	return w.Queue.Consume(ctx, w.handle)
}

func (w *Worker) handle(ctx context.Context, body []byte) error {
	var command domain.Command
	if err := json.Unmarshal(body, &command); err != nil {
		w.Logger.Warn("dead-lettering malformed command", "error", err)
		return queue.Permanent(fmt.Errorf("decode command: %w", err))
	}
	if domain.ValidateID(command.ID) != nil || domain.ValidateTrackingID(command.TrackingID) != nil || command.CorrelationID == "" {
		return queue.Permanent(errors.New("command is missing required identifiers"))
	}
	err := w.Store.ProcessCommand(ctx, command)
	if errors.Is(err, store.ErrNotFound) || errors.Is(err, store.ErrStaleCommand) {
		w.Logger.Warn("dead-lettering invalid command", "command_id", command.ID, "correlation_id", command.CorrelationID, "error", err)
		return queue.Permanent(err)
	}
	if err != nil {
		w.Logger.Error("command processing failed", "command_id", command.ID, "correlation_id", command.CorrelationID, "error", err)
		return err
	}
	w.Logger.Info("command processed", "command_id", command.ID, "tracking_id", command.TrackingID, "correlation_id", command.CorrelationID)
	return nil
}
