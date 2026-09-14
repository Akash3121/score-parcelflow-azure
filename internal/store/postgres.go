package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"strings"
	"time"

	"github.com/Akash3121/score-parcelflow-azure/internal/domain"
	"github.com/Akash3121/score-parcelflow-azure/migrations"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrNotFound       = errors.New("not found")
	ErrConflict       = errors.New("conflict")
	ErrTerminal       = errors.New("parcel is already delivered")
	ErrAdvancePending = errors.New("parcel already has a pending advance command")
	ErrStaleCommand   = errors.New("command no longer matches parcel state")
)

type Postgres struct{ pool *pgxpool.Pool }

type OutboxRecord struct {
	ID      string
	Payload []byte
}

type ProofRecord struct {
	Proof     domain.Proof
	ObjectKey string
}

func Open(ctx context.Context, databaseURL string) (*Postgres, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse database configuration: %w", err)
	}
	cfg.MaxConns = 12
	cfg.MinConns = 1
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping database: %w", err)
	}
	return &Postgres{pool: pool}, nil
}

func (s *Postgres) Close()                         { s.pool.Close() }
func (s *Postgres) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

func (s *Postgres) Migrate(ctx context.Context) error {
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	const lockID int64 = 0x50415243454C
	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", lockID); err != nil {
		return fmt.Errorf("acquire migration lock: %w", err)
	}
	defer func() { _, _ = conn.Exec(context.Background(), "SELECT pg_advisory_unlock($1)", lockID) }()

	names, err := fs.Glob(migrations.Files, "*.sql")
	if err != nil {
		return fmt.Errorf("list migrations: %w", err)
	}
	sort.Strings(names)
	for _, name := range names {
		body, err := migrations.Files.ReadFile(name)
		if err != nil {
			return fmt.Errorf("read migration %s: %w", name, err)
		}
		tx, err := conn.Begin(ctx)
		if err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`); err == nil {
			var applied bool
			err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version=$1)`, name).Scan(&applied)
			if err == nil && !applied {
				_, err = tx.Exec(ctx, string(body))
				if err == nil {
					_, err = tx.Exec(ctx, `INSERT INTO schema_migrations(version) VALUES($1)`, name)
				}
			}
		}
		if err != nil {
			_ = tx.Rollback(ctx)
			return fmt.Errorf("apply migration %s: %w", name, err)
		}
		if err := tx.Commit(ctx); err != nil {
			return fmt.Errorf("commit migration %s: %w", name, err)
		}
	}
	return nil
}

func HashCreate(v domain.CreateParcel) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(v.RecipientName) + "\x00" + strings.TrimSpace(v.DeliveryAddress)))
	return hex.EncodeToString(sum[:])
}

func (s *Postgres) CreateParcel(ctx context.Context, in domain.CreateParcel, idempotencyKey, correlationID string) (domain.Parcel, bool, error) {
	now := time.Now().UTC().Truncate(time.Microsecond)
	hash := HashCreate(in)
	id, tracking := domain.NewID(), domain.NewTrackingID()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return domain.Parcel{}, false, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	_, err = tx.Exec(ctx, `INSERT INTO parcels
		(id,tracking_id,recipient_name,delivery_address,status,create_idempotency_key,request_hash,created_at,updated_at)
		VALUES($1,$2,$3,$4,$5,$6,$7,$8,$8)`,
		id, tracking, strings.TrimSpace(in.RecipientName), strings.TrimSpace(in.DeliveryAddress), domain.LabelCreated, idempotencyKey, hash, now)
	if err == nil {
		_, err = tx.Exec(ctx, `INSERT INTO parcel_events(id,parcel_id,to_status,correlation_id,occurred_at) VALUES($1,$2,$3,$4,$5)`,
			domain.NewID(), id, domain.LabelCreated, correlationID, now)
		if err != nil {
			return domain.Parcel{}, false, fmt.Errorf("record creation event: %w", err)
		}
		if err := tx.Commit(ctx); err != nil {
			return domain.Parcel{}, false, err
		}
		p, err := s.GetParcel(ctx, tracking)
		return p, false, err
	}
	if !isUniqueViolation(err) {
		return domain.Parcel{}, false, fmt.Errorf("create parcel: %w", err)
	}
	_ = tx.Rollback(ctx)
	var existingTracking, existingHash string
	if err := s.pool.QueryRow(ctx, `SELECT tracking_id,request_hash FROM parcels WHERE create_idempotency_key=$1`, idempotencyKey).Scan(&existingTracking, &existingHash); err != nil {
		return domain.Parcel{}, false, fmt.Errorf("resolve create idempotency: %w", err)
	}
	if existingHash != hash {
		return domain.Parcel{}, false, ErrConflict
	}
	p, err := s.GetParcel(ctx, existingTracking)
	return p, true, err
}

func (s *Postgres) ListParcels(ctx context.Context) ([]domain.Parcel, error) {
	rows, err := s.pool.Query(ctx, `SELECT tracking_id,recipient_name,delivery_address,status,created_at,updated_at FROM parcels ORDER BY created_at,tracking_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]domain.Parcel, 0)
	for rows.Next() {
		var p domain.Parcel
		if err := rows.Scan(&p.TrackingID, &p.RecipientName, &p.DeliveryAddress, &p.Status, &p.CreatedAt, &p.UpdatedAt); err != nil {
			return nil, err
		}
		p.CreatedAt, p.UpdatedAt = p.CreatedAt.UTC(), p.UpdatedAt.UTC()
		p.Events = []domain.Event{}
		items = append(items, p)
	}
	return items, rows.Err()
}

func (s *Postgres) GetParcel(ctx context.Context, trackingID string) (domain.Parcel, error) {
	var p domain.Parcel
	var parcelID string
	err := s.pool.QueryRow(ctx, `SELECT id,tracking_id,recipient_name,delivery_address,status,created_at,updated_at FROM parcels WHERE tracking_id=$1`, trackingID).
		Scan(&parcelID, &p.TrackingID, &p.RecipientName, &p.DeliveryAddress, &p.Status, &p.CreatedAt, &p.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return domain.Parcel{}, ErrNotFound
	}
	if err != nil {
		return domain.Parcel{}, err
	}
	p.CreatedAt, p.UpdatedAt = p.CreatedAt.UTC(), p.UpdatedAt.UTC()
	rows, err := s.pool.Query(ctx, `SELECT id,from_status,to_status,command_id,correlation_id,occurred_at FROM parcel_events WHERE parcel_id=$1 ORDER BY occurred_at,id`, parcelID)
	if err != nil {
		return domain.Parcel{}, err
	}
	defer rows.Close()
	p.Events = make([]domain.Event, 0)
	for rows.Next() {
		var event domain.Event
		var from *string
		if err := rows.Scan(&event.ID, &from, &event.ToStatus, &event.CommandID, &event.CorrelationID, &event.OccurredAt); err != nil {
			return domain.Parcel{}, err
		}
		if from != nil {
			v := domain.Status(*from)
			event.FromStatus = &v
		}
		event.OccurredAt = event.OccurredAt.UTC()
		p.Events = append(p.Events, event)
	}
	var proof domain.Proof
	err = s.pool.QueryRow(ctx, `SELECT content_type,filename,sha256,size_bytes,uploaded_at FROM proofs WHERE parcel_id=$1`, parcelID).
		Scan(&proof.ContentType, &proof.Filename, &proof.SHA256, &proof.Size, &proof.UploadedAt)
	if err == nil {
		proof.UploadedAt = proof.UploadedAt.UTC()
		p.ProofOfDelivery = &proof
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return domain.Parcel{}, err
	}
	return p, rows.Err()
}

func (s *Postgres) Advance(ctx context.Context, trackingID, idempotencyKey, correlationID string) (domain.Command, bool, error) {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return domain.Command{}, false, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var parcelID string
	var current domain.Status
	if err := tx.QueryRow(ctx, `SELECT id,status FROM parcels WHERE tracking_id=$1 FOR UPDATE`, trackingID).Scan(&parcelID, &current); errors.Is(err, pgx.ErrNoRows) {
		return domain.Command{}, false, ErrNotFound
	} else if err != nil {
		return domain.Command{}, false, err
	}
	var existing domain.Command
	err = tx.QueryRow(ctx, `SELECT id,$1,from_status,to_status,idempotency_key,correlation_id,created_at FROM commands WHERE parcel_id=$2 AND idempotency_key=$3`,
		trackingID, parcelID, idempotencyKey).Scan(&existing.ID, &existing.TrackingID, &existing.FromStatus, &existing.ToStatus, &existing.IdempotencyKey, &existing.CorrelationID, &existing.CreatedAt)
	if err == nil {
		existing.CreatedAt = existing.CreatedAt.UTC()
		return existing, true, tx.Commit(ctx)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return domain.Command{}, false, err
	}
	var pending bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM commands WHERE parcel_id=$1 AND processed_at IS NULL)`, parcelID).Scan(&pending); err != nil {
		return domain.Command{}, false, err
	}
	if pending {
		return domain.Command{}, false, ErrAdvancePending
	}
	next, ok := domain.Next(current)
	if !ok {
		return domain.Command{}, false, ErrTerminal
	}
	command := domain.Command{
		ID: domain.NewID(), TrackingID: trackingID, FromStatus: current, ToStatus: next,
		IdempotencyKey: idempotencyKey, CorrelationID: correlationID, CreatedAt: time.Now().UTC().Truncate(time.Microsecond),
	}
	payload, err := json.Marshal(command)
	if err != nil {
		return domain.Command{}, false, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO commands(id,parcel_id,idempotency_key,from_status,to_status,correlation_id,created_at) VALUES($1,$2,$3,$4,$5,$6,$7)`,
		command.ID, parcelID, command.IdempotencyKey, command.FromStatus, command.ToStatus, command.CorrelationID, command.CreatedAt); err != nil {
		return domain.Command{}, false, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO outbox(id,command_id,payload,created_at,available_at) VALUES($1,$2,$3,$4,$4)`,
		domain.NewID(), command.ID, payload, command.CreatedAt); err != nil {
		return domain.Command{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return domain.Command{}, false, err
	}
	return command, false, nil
}

func (s *Postgres) PendingOutbox(ctx context.Context, limit int) ([]OutboxRecord, error) {
	rows, err := s.pool.Query(ctx, `SELECT id,payload FROM outbox WHERE published_at IS NULL AND available_at <= now() ORDER BY created_at LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var records []OutboxRecord
	for rows.Next() {
		var r OutboxRecord
		if err := rows.Scan(&r.ID, &r.Payload); err != nil {
			return nil, err
		}
		records = append(records, r)
	}
	return records, rows.Err()
}

func (s *Postgres) MarkOutboxPublished(ctx context.Context, id string) error {
	_, err := s.pool.Exec(ctx, `UPDATE outbox SET published_at=now(),attempts=attempts+1,last_error=NULL WHERE id=$1`, id)
	return err
}

func (s *Postgres) MarkOutboxFailed(ctx context.Context, id string, publishErr error) error {
	_, err := s.pool.Exec(ctx, `UPDATE outbox SET attempts=attempts+1,last_error=$2,available_at=now() + make_interval(secs => LEAST(60, power(2, LEAST(attempts,5))::int)) WHERE id=$1`,
		id, truncate(publishErr.Error(), 500))
	return err
}

func (s *Postgres) ProcessCommand(ctx context.Context, command domain.Command) error {
	if !domain.ValidStatus(command.FromStatus) || !domain.ValidStatus(command.ToStatus) {
		return fmt.Errorf("%w: invalid status", ErrStaleCommand)
	}
	expected, ok := domain.Next(command.FromStatus)
	if !ok || expected != command.ToStatus {
		return fmt.Errorf("%w: invalid transition", ErrStaleCommand)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var persistedTracking, persistedCorrelation string
	var persistedFrom, persistedTo domain.Status
	err = tx.QueryRow(ctx, `SELECT p.tracking_id,c.from_status,c.to_status,c.correlation_id
		FROM commands c JOIN parcels p ON p.id=c.parcel_id WHERE c.id=$1`,
		command.ID).Scan(&persistedTracking, &persistedFrom, &persistedTo, &persistedCorrelation)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if persistedTracking != command.TrackingID || persistedFrom != command.FromStatus ||
		persistedTo != command.ToStatus || persistedCorrelation != command.CorrelationID {
		return fmt.Errorf("%w: message does not match persisted command", ErrStaleCommand)
	}
	var parcelID string
	var current domain.Status
	err = tx.QueryRow(ctx, `SELECT id,status FROM parcels WHERE tracking_id=$1 FOR UPDATE`, command.TrackingID).Scan(&parcelID, &current)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	var processed bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM processed_commands WHERE command_id=$1)`, command.ID).Scan(&processed); err != nil {
		return err
	}
	if processed {
		return tx.Commit(ctx)
	}
	if current != command.FromStatus {
		return fmt.Errorf("%w: current=%s expected=%s", ErrStaleCommand, current, command.FromStatus)
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	if _, err := tx.Exec(ctx, `UPDATE parcels SET status=$2,updated_at=$3 WHERE id=$1`, parcelID, command.ToStatus, now); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO parcel_events(id,parcel_id,from_status,to_status,command_id,correlation_id,occurred_at) VALUES($1,$2,$3,$4,$5,$6,$7)`,
		domain.NewID(), parcelID, command.FromStatus, command.ToStatus, command.ID, command.CorrelationID, now); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO processed_commands(command_id,processed_at) VALUES($1,$2)`, command.ID, now); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE commands SET processed_at=$2 WHERE id=$1`, command.ID, now); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *Postgres) SaveProof(ctx context.Context, trackingID, objectKey string, proof domain.Proof) (ProofRecord, bool, error) {
	var parcelID string
	var status domain.Status
	err := s.pool.QueryRow(ctx, `SELECT id,status FROM parcels WHERE tracking_id=$1`, trackingID).Scan(&parcelID, &status)
	if errors.Is(err, pgx.ErrNoRows) {
		return ProofRecord{}, false, ErrNotFound
	}
	if err != nil {
		return ProofRecord{}, false, err
	}
	if status != domain.Delivered {
		return ProofRecord{}, false, fmt.Errorf("%w: proof requires delivered status", ErrConflict)
	}
	_, err = s.pool.Exec(ctx, `INSERT INTO proofs(parcel_id,object_key,content_type,filename,sha256,size_bytes,uploaded_at) VALUES($1,$2,$3,$4,$5,$6,$7)`,
		parcelID, objectKey, proof.ContentType, proof.Filename, proof.SHA256, proof.Size, proof.UploadedAt)
	if err == nil {
		return ProofRecord{Proof: proof, ObjectKey: objectKey}, false, nil
	}
	if !isUniqueViolation(err) {
		return ProofRecord{}, false, err
	}
	existing, getErr := s.GetProof(ctx, trackingID)
	if getErr != nil {
		return ProofRecord{}, false, getErr
	}
	if existing.Proof.SHA256 != proof.SHA256 || existing.Proof.ContentType != proof.ContentType {
		return existing, false, ErrConflict
	}
	return existing, true, nil
}

func (s *Postgres) GetProof(ctx context.Context, trackingID string) (ProofRecord, error) {
	var r ProofRecord
	err := s.pool.QueryRow(ctx, `SELECT pr.object_key,pr.content_type,pr.filename,pr.sha256,pr.size_bytes,pr.uploaded_at
		FROM proofs pr JOIN parcels p ON p.id=pr.parcel_id WHERE p.tracking_id=$1`, trackingID).
		Scan(&r.ObjectKey, &r.Proof.ContentType, &r.Proof.Filename, &r.Proof.SHA256, &r.Proof.Size, &r.Proof.UploadedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return ProofRecord{}, ErrNotFound
	}
	r.Proof.UploadedAt = r.Proof.UploadedAt.UTC()
	return r, err
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

func truncate(v string, max int) string {
	if len(v) > max {
		return v[:max]
	}
	return v
}
