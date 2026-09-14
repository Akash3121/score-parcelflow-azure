package migrations

import "embed"

// Files contains immutable, ordered database migrations.
//
//go:embed *.sql
var Files embed.FS
