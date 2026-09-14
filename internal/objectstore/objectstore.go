package objectstore

import (
	"context"
	"fmt"
	"io"

	"github.com/Akash3121/score-parcelflow-azure/internal/config"
)

type Store interface {
	Put(context.Context, string, string, []byte) error
	Get(context.Context, string) (io.ReadCloser, error)
	Delete(context.Context, string) error
}

func New(ctx context.Context, cfg config.ObjectStore) (Store, error) {
	switch cfg.Provider {
	case "azurite", "azure-blob":
		return newBlob(ctx, cfg)
	default:
		return nil, fmt.Errorf("unsupported object store provider %q", cfg.Provider)
	}
}
