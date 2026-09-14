package outbox

import (
	"context"
	"log/slog"
	"time"

	"github.com/Akash3121/score-parcelflow-azure/internal/queue"
	"github.com/Akash3121/score-parcelflow-azure/internal/store"
)

type Publisher struct {
	Store  Store
	Queue  queue.Publisher
	Logger *slog.Logger
}

type Store interface {
	PendingOutbox(context.Context, int) ([]store.OutboxRecord, error)
	MarkOutboxPublished(context.Context, string) error
	MarkOutboxFailed(context.Context, string, error) error
}

func (p *Publisher) Run(ctx context.Context) error {
	ticker := time.NewTicker(750 * time.Millisecond)
	defer ticker.Stop()
	for {
		if err := p.flush(ctx); err != nil && ctx.Err() == nil {
			p.Logger.Error("outbox flush failed", "error", err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

func (p *Publisher) flush(ctx context.Context) error {
	records, err := p.Store.PendingOutbox(ctx, 25)
	if err != nil {
		return err
	}
	for _, record := range records {
		if err := p.Queue.Publish(ctx, record.Payload); err != nil {
			_ = p.Store.MarkOutboxFailed(ctx, record.ID, err)
			return err
		}
		if err := p.Store.MarkOutboxPublished(ctx, record.ID); err != nil {
			// Publishing before acknowledgement is intentionally safe: a later
			// flush republishes and the worker deduplicates by command ID.
			return err
		}
	}
	return nil
}
