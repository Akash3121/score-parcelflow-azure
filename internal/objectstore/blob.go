package objectstore

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/Akash3121/score-parcelflow-azure/internal/config"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/blob"
)

type blobStore struct {
	client    *azblob.Client
	container string
}

func newBlob(ctx context.Context, cfg config.ObjectStore) (*blobStore, error) {
	endpoint := strings.TrimSuffix(cfg.Endpoint, "/")
	var client *azblob.Client
	var err error
	if cfg.CredentialMode == "workload-identity" {
		credential, credErr := azidentity.NewDefaultAzureCredential(nil)
		if credErr != nil {
			return nil, fmt.Errorf("create Azure credential: %w", credErr)
		}
		client, err = azblob.NewClient(endpoint, credential, nil)
	} else {
		credential, credErr := azblob.NewSharedKeyCredential(cfg.AccountName, cfg.AccountKey)
		if credErr != nil {
			return nil, fmt.Errorf("create storage credential: %w", credErr)
		}
		client, err = azblob.NewClientWithSharedKeyCredential(endpoint, credential, nil)
	}
	if err != nil {
		return nil, fmt.Errorf("create blob client: %w", err)
	}
	s := &blobStore{client: client, container: cfg.Container}
	if cfg.Provider == "azurite" {
		_, err = client.CreateContainer(ctx, cfg.Container, nil)
		if err != nil && !isAlreadyExists(err) {
			return nil, fmt.Errorf("ensure blob container: %w", err)
		}
	}
	return s, nil
}

func (s *blobStore) Put(ctx context.Context, key, contentType string, data []byte) error {
	_, err := s.client.UploadBuffer(ctx, s.container, key, data, &azblob.UploadBufferOptions{
		HTTPHeaders: &blob.HTTPHeaders{BlobContentType: &contentType},
	})
	return err
}

func (s *blobStore) Get(ctx context.Context, key string) (io.ReadCloser, error) {
	response, err := s.client.DownloadStream(ctx, s.container, key, nil)
	if err != nil {
		return nil, err
	}
	return response.Body, nil
}

func (s *blobStore) Delete(ctx context.Context, key string) error {
	_, err := s.client.DeleteBlob(ctx, s.container, key, nil)
	return err
}

func isAlreadyExists(err error) bool {
	return strings.Contains(strings.ToLower(err.Error()), "containeralreadyexists") ||
		strings.Contains(strings.ToLower(err.Error()), "statuscode=409")
}
