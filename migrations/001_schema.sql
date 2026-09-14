CREATE TABLE IF NOT EXISTS schema_migrations (
    version text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS parcels (
    id uuid PRIMARY KEY,
    tracking_id text NOT NULL UNIQUE,
    recipient_name text NOT NULL,
    delivery_address text NOT NULL,
    status text NOT NULL CHECK (status IN ('label_created','picked_up','at_sorting_center','in_transit','out_for_delivery','delivered')),
    create_idempotency_key text NOT NULL UNIQUE,
    request_hash text NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS parcel_events (
    id uuid PRIMARY KEY,
    parcel_id uuid NOT NULL REFERENCES parcels(id) ON DELETE CASCADE,
    from_status text,
    to_status text NOT NULL,
    command_id uuid,
    correlation_id text NOT NULL,
    occurred_at timestamptz NOT NULL,
    UNIQUE (command_id)
);
CREATE INDEX IF NOT EXISTS parcel_events_parcel_time_idx ON parcel_events(parcel_id, occurred_at, id);

CREATE TABLE IF NOT EXISTS commands (
    id uuid PRIMARY KEY,
    parcel_id uuid NOT NULL REFERENCES parcels(id) ON DELETE CASCADE,
    idempotency_key text NOT NULL,
    from_status text NOT NULL,
    to_status text NOT NULL,
    correlation_id text NOT NULL,
    created_at timestamptz NOT NULL,
    processed_at timestamptz,
    UNIQUE (parcel_id, idempotency_key)
);

CREATE TABLE IF NOT EXISTS outbox (
    id uuid PRIMARY KEY,
    command_id uuid NOT NULL UNIQUE REFERENCES commands(id) ON DELETE CASCADE,
    payload jsonb NOT NULL,
    attempts integer NOT NULL DEFAULT 0,
    available_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS outbox_pending_idx ON outbox(available_at, created_at) WHERE published_at IS NULL;

CREATE TABLE IF NOT EXISTS processed_commands (
    command_id uuid PRIMARY KEY REFERENCES commands(id) ON DELETE CASCADE,
    processed_at timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS proofs (
    parcel_id uuid PRIMARY KEY REFERENCES parcels(id) ON DELETE CASCADE,
    object_key text NOT NULL UNIQUE,
    content_type text NOT NULL,
    filename text NOT NULL,
    sha256 text NOT NULL,
    size_bytes bigint NOT NULL CHECK (size_bytes BETWEEN 1 AND 1048576),
    uploaded_at timestamptz NOT NULL
);
