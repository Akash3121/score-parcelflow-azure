package outbox

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"

	"github.com/Akash3121/score-parcelflow-azure/internal/store"
)

type fakeStore struct {
	record    store.OutboxRecord
	markCalls int
}

func (s *fakeStore) PendingOutbox(context.Context, int) ([]store.OutboxRecord, error) {
	if s.record.ID == "" {
		return nil, nil
	}
	return []store.OutboxRecord{s.record}, nil
}
func (s *fakeStore) MarkOutboxPublished(context.Context, string) error {
	s.markCalls++
	if s.markCalls == 1 {
		return errors.New("simulated acknowledgement failure")
	}
	s.record = store.OutboxRecord{}
	return nil
}
func (*fakeStore) MarkOutboxFailed(context.Context, string, error) error { return nil }

type fakePublisher struct{ calls int }

func (p *fakePublisher) Publish(context.Context, []byte) error { p.calls++; return nil }
func (*fakePublisher) Close(context.Context) error             { return nil }

func TestPublishBeforeAcknowledgementIsRetried(t *testing.T) {
	database := &fakeStore{record: store.OutboxRecord{ID: "outbox", Payload: []byte(`{"id":"command"}`)}}
	bus := &fakePublisher{}
	publisher := Publisher{Store: database, Queue: bus, Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	if err := publisher.flush(context.Background()); err == nil {
		t.Fatal("expected simulated acknowledgement failure")
	}
	if err := publisher.flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if bus.calls != 2 {
		t.Fatalf("publish calls=%d, want 2", bus.calls)
	}
}
