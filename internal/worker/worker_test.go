package worker

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"testing"

	"github.com/Akash3121/score-parcelflow-azure/internal/domain"
	"github.com/Akash3121/score-parcelflow-azure/internal/queue"
	"github.com/Akash3121/score-parcelflow-azure/internal/store"
)

type fakeProcessor struct {
	calls int
	err   error
}

func (p *fakeProcessor) ProcessCommand(context.Context, domain.Command) error {
	p.calls++
	return p.err
}

func TestMalformedMessageIsPermanent(t *testing.T) {
	processor := &fakeProcessor{}
	w := Worker{Store: processor, Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	err := w.handle(context.Background(), []byte(`{"id":"bad"}`))
	if !errors.Is(err, queue.ErrPermanent) {
		t.Fatalf("error=%v, want permanent", err)
	}
	if processor.calls != 0 {
		t.Fatal("malformed message reached processor")
	}
}

func TestStaleCommandIsPermanent(t *testing.T) {
	processor := &fakeProcessor{}
	w := Worker{Store: processor, Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	command := domain.Command{
		ID: "12345678-1234-4234-8234-123456789abc", TrackingID: "PF-TEST00000001",
		FromStatus: domain.LabelCreated, ToStatus: domain.PickedUp, CorrelationID: "test-correlation",
	}
	processor.err = fmt.Errorf("%w: test", store.ErrStaleCommand)
	body, _ := json.Marshal(command)
	if err := w.handle(context.Background(), body); !errors.Is(err, queue.ErrPermanent) {
		t.Fatalf("error=%v, want permanent", err)
	}
}
