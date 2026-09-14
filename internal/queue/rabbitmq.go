package queue

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/Akash3121/score-parcelflow-azure/internal/config"
	amqp "github.com/rabbitmq/amqp091-go"
)

type rabbitMQ struct {
	conn     *amqp.Connection
	channel  *amqp.Channel
	name     string
	confirms <-chan amqp.Confirmation
	returns  <-chan amqp.Return
}

func newRabbitMQ(cfg config.Queue) (*rabbitMQ, error) {
	endpoint := cfg.Endpoint
	if !strings.Contains(endpoint, "://") {
		endpoint = "amqp://" + endpoint
	}
	u, err := url.Parse(endpoint)
	if err != nil {
		return nil, fmt.Errorf("parse RabbitMQ endpoint: %w", err)
	}
	u.User = url.UserPassword(cfg.Username, cfg.Password)
	conn, err := amqp.DialConfig(u.String(), amqp.Config{Heartbeat: 15 * time.Second, Locale: "en_US"})
	if err != nil {
		return nil, fmt.Errorf("connect RabbitMQ: %w", err)
	}
	ch, err := conn.Channel()
	if err != nil {
		conn.Close()
		return nil, err
	}
	q := &rabbitMQ{conn: conn, channel: ch, name: cfg.Name}
	if err := q.declare(); err != nil {
		_ = q.Close(context.Background())
		return nil, err
	}
	if err := ch.Confirm(false); err != nil {
		_ = q.Close(context.Background())
		return nil, fmt.Errorf("enable RabbitMQ publisher confirms: %w", err)
	}
	q.confirms = ch.NotifyPublish(make(chan amqp.Confirmation, 1))
	q.returns = ch.NotifyReturn(make(chan amqp.Return, 1))
	return q, nil
}

func (q *rabbitMQ) declare() error {
	dlq := q.name + ".dlq"
	if _, err := q.channel.QueueDeclare(dlq, true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare RabbitMQ dead-letter queue: %w", err)
	}
	args := amqp.Table{"x-dead-letter-exchange": "", "x-dead-letter-routing-key": dlq}
	if _, err := q.channel.QueueDeclare(q.name, true, false, false, false, args); err != nil {
		return fmt.Errorf("declare RabbitMQ queue: %w", err)
	}
	return q.channel.Qos(1, 0, false)
}

func (q *rabbitMQ) Publish(ctx context.Context, body []byte) error {
	if err := q.channel.PublishWithContext(ctx, "", q.name, true, false, amqp.Publishing{
		ContentType:  "application/json",
		DeliveryMode: amqp.Persistent,
		Timestamp:    time.Now().UTC(),
		Body:         body,
	}); err != nil {
		return err
	}

	select {
	case returned := <-q.returns:
		return fmt.Errorf("RabbitMQ returned message: %d %s", returned.ReplyCode, returned.ReplyText)
	case confirmation := <-q.confirms:
		if !confirmation.Ack {
			return fmt.Errorf("RabbitMQ negatively acknowledged published message")
		}
		select {
		case returned := <-q.returns:
			return fmt.Errorf("RabbitMQ returned message: %d %s", returned.ReplyCode, returned.ReplyText)
		default:
			return nil
		}
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (q *rabbitMQ) Consume(ctx context.Context, handler Handler) error {
	deliveries, err := q.channel.Consume(q.name, "", false, false, false, false, nil)
	if err != nil {
		return err
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case delivery, ok := <-deliveries:
			if !ok {
				return fmt.Errorf("RabbitMQ delivery channel closed")
			}
			err := handler(ctx, delivery.Body)
			switch {
			case err == nil:
				_ = delivery.Ack(false)
			case errorsIsPermanent(err):
				_ = delivery.Reject(false)
			default:
				_ = delivery.Nack(false, true)
			}
		}
	}
}

func (q *rabbitMQ) Close(context.Context) error {
	if q.channel != nil {
		_ = q.channel.Close()
	}
	if q.conn != nil {
		return q.conn.Close()
	}
	return nil
}

func errorsIsPermanent(err error) bool { return errors.Is(err, ErrPermanent) }
