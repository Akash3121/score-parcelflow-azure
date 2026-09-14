package queue

import (
	"context"
	"errors"
	"fmt"

	"github.com/Akash3121/score-parcelflow-azure/internal/config"
)

var ErrPermanent = errors.New("permanent message failure")

type Handler func(context.Context, []byte) error

type Publisher interface {
	Publish(context.Context, []byte) error
	Close(context.Context) error
}

type Consumer interface {
	Consume(context.Context, Handler) error
	Close(context.Context) error
}

func NewPublisher(ctx context.Context, cfg config.Queue) (Publisher, error) {
	switch cfg.Provider {
	case "rabbitmq":
		return newRabbitMQ(cfg)
	case "azure-servicebus":
		return newServiceBus(ctx, cfg, true)
	default:
		return nil, fmt.Errorf("unsupported queue provider %q", cfg.Provider)
	}
}

func NewConsumer(ctx context.Context, cfg config.Queue) (Consumer, error) {
	switch cfg.Provider {
	case "rabbitmq":
		return newRabbitMQ(cfg)
	case "azure-servicebus":
		return newServiceBus(ctx, cfg, false)
	default:
		return nil, fmt.Errorf("unsupported queue provider %q", cfg.Provider)
	}
}

func Permanent(err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("%w: %v", ErrPermanent, err)
}
