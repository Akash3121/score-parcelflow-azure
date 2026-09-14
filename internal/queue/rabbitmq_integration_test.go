package queue

import (
	"context"
	"errors"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/Akash3121/score-parcelflow-azure/internal/config"
	"github.com/Akash3121/score-parcelflow-azure/internal/domain"
)

func TestRabbitMQPoisonMessageDeadLettersIntegration(t *testing.T) {
	rawURL := os.Getenv("PARCELFLOW_TEST_RABBITMQ_URL")
	if rawURL == "" {
		t.Skip("PARCELFLOW_TEST_RABBITMQ_URL is not set")
	}
	u, err := url.Parse(rawURL)
	if err != nil {
		t.Fatal(err)
	}
	password, _ := u.User.Password()
	username := u.User.Username()
	u.User = nil
	cfg := config.Queue{
		Provider: "rabbitmq", Endpoint: u.String(), Name: "parcelflow-test-" + domain.NewID(),
		CredentialMode: "password", Username: username, Password: password,
	}
	consumer, err := newRabbitMQ(cfg)
	if err != nil {
		t.Fatalf("connect to configured RabbitMQ: %v", err)
	}
	defer consumer.Close(context.Background())
	inspector, err := newRabbitMQ(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer inspector.Close(context.Background())

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- consumer.Consume(ctx, func(context.Context, []byte) error {
			return Permanent(errors.New("poison"))
		})
	}()
	if err := inspector.Publish(ctx, []byte(`not-json`)); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		message, ok, err := inspector.channel.Get(cfg.Name+".dlq", true)
		if err != nil {
			t.Fatal(err)
		}
		if ok {
			if string(message.Body) != "not-json" {
				t.Fatalf("unexpected dead-letter body %q", message.Body)
			}
			cancel()
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("poison message was not routed to the dead-letter queue")
}
