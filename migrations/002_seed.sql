INSERT INTO parcels (id, tracking_id, recipient_name, delivery_address, status, create_idempotency_key, request_hash, created_at, updated_at) VALUES
('10000000-0000-4000-8000-000000000001','PF-DEMO000001','Avery Stone','14 Cedar Lane, Northport','label_created','seed-parcel-01','seed','2026-01-15T09:00:00Z','2026-01-15T09:00:00Z'),
('10000000-0000-4000-8000-000000000002','PF-DEMO000002','Morgan Lee','22 Lantern Street, Fairview','picked_up','seed-parcel-02','seed','2026-01-15T08:00:00Z','2026-01-15T09:15:00Z'),
('10000000-0000-4000-8000-000000000003','PF-DEMO000003','Riley Chen','9 Orchard Crescent, Lakeside','at_sorting_center','seed-parcel-03','seed','2026-01-15T07:00:00Z','2026-01-15T10:00:00Z'),
('10000000-0000-4000-8000-000000000004','PF-DEMO000004','Jordan Bell','61 Harbor Avenue, Westhaven','in_transit','seed-parcel-04','seed','2026-01-14T17:00:00Z','2026-01-15T11:30:00Z'),
('10000000-0000-4000-8000-000000000005','PF-DEMO000005','Casey Fields','103 Maple Road, Brookfield','out_for_delivery','seed-parcel-05','seed','2026-01-14T15:00:00Z','2026-01-15T12:10:00Z'),
('10000000-0000-4000-8000-000000000006','PF-DEMO000006','Taylor Brooks','7 Sunrise Court, Pinecrest','delivered','seed-parcel-06','seed','2026-01-14T12:00:00Z','2026-01-15T13:00:00Z')
ON CONFLICT DO NOTHING;

INSERT INTO parcel_events (id, parcel_id, from_status, to_status, command_id, correlation_id, occurred_at)
SELECT ('20000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, p.id, NULL, p.status, NULL, 'deterministic-seed', p.updated_at
FROM parcels p
JOIN generate_series(1, 6) n ON p.tracking_id = 'PF-DEMO' || lpad(n::text, 6, '0')
ON CONFLICT DO NOTHING;
