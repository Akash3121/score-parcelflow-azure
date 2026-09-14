package queue

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/Akash3121/score-parcelflow-azure/internal/config"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/messaging/azservicebus"
)

type serviceBus struct {
	client   *azservicebus.Client
	sender   *azservicebus.Sender
	receiver *azservicebus.Receiver
}

func newServiceBus(ctx context.Context, cfg config.Queue, publishing bool) (*serviceBus, error) {
	var client *azservicebus.Client
	var err error
	if cfg.CredentialMode == "workload-identity" {
		credential, credErr := azidentity.NewDefaultAzureCredential(nil)
		if credErr != nil {
			return nil, fmt.Errorf("create Azure credential: %w", credErr)
		}
		namespace := strings.TrimSuffix(cfg.Endpoint, "/")
		namespace = strings.TrimPrefix(namespace, "https://")
		namespace = strings.TrimPrefix(namespace, "http://")
		namespace = strings.TrimPrefix(namespace, "sb://")
		client, err = azservicebus.NewClient(namespace, credential, nil)
	} else {
		connectionString := cfg.Endpoint
		if !strings.Contains(connectionString, "Endpoint=") {
			endpoint := cfg.Endpoint
			if !strings.HasPrefix(endpoint, "sb://") {
				endpoint = "sb://" + strings.TrimPrefix(strings.TrimPrefix(endpoint, "https://"), "http://")
			}
			connectionString = fmt.Sprintf("Endpoint=%s;SharedAccessKeyName=%s;SharedAccessKey=%s", strings.TrimSuffix(endpoint, "/")+"/", cfg.Username, cfg.Password)
		}
		client, err = azservicebus.NewClientFromConnectionString(connectionString, nil)
	}
	if err != nil {
		return nil, fmt.Errorf("create Service Bus client: %w", err)
	}
	result := &serviceBus{client: client}
	if publishing {
		result.sender, err = client.NewSender(cfg.Name, nil)
		if err != nil {
			_ = client.Close(ctx)
			return nil, fmt.Errorf("create Service Bus sender: %w", err)
		}
	} else {
		result.receiver, err = client.NewReceiverForQueue(cfg.Name, nil)
		if err != nil {
			_ = client.Close(ctx)
			return nil, fmt.Errorf("create Service Bus receiver: %w", err)
		}
	}
	return result, nil
}

func (q *serviceBus) Publish(ctx context.Context, body []byte) error {
	return q.sender.SendMessage(ctx, &azservicebus.Message{Body: body, ContentType: ptr("application/json")}, nil)
}

func (q *serviceBus) Consume(ctx context.Context, handler Handler) error {
	for ctx.Err() == nil {
		receiveCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
		messages, err := q.receiver.ReceiveMessages(receiveCtx, 10, nil)
		cancel()
		if err != nil {
			if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) && ctx.Err() == nil {
				continue
			}
			return err
		}
		for _, message := range messages {
			err := handler(ctx, message.Body)
			switch {
			case err == nil:
				err = q.receiver.CompleteMessage(ctx, message, nil)
			case errorsIsPermanent(err):
				reason, description := "ParcelFlowValidation", err.Error()
				err = q.receiver.DeadLetterMessage(ctx, message, &azservicebus.DeadLetterOptions{Reason: &reason, ErrorDescription: &description})
			default:
				err = q.receiver.AbandonMessage(ctx, message, nil)
			}
			if err != nil {
				return err
			}
		}
	}
	return ctx.Err()
}

func (q *serviceBus) Close(ctx context.Context) error {
	var errs []error
	if q.receiver != nil {
		errs = append(errs, q.receiver.Close(ctx))
	}
	if q.sender != nil {
		errs = append(errs, q.sender.Close(ctx))
	}
	if q.client != nil {
		errs = append(errs, q.client.Close(ctx))
	}
	return errors.Join(errs...)
}

func ptr[T any](v T) *T { return &v }
