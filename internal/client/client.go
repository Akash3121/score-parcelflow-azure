package client

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/Akash3121/score-parcelflow-azure/internal/domain"
)

type Client struct {
	BaseURL string
	HTTP    *http.Client
}

type ListResponse struct {
	Items []domain.Parcel `json:"items"`
	Count int             `json:"count"`
}

type Response struct {
	Status int
	Header http.Header
	Body   []byte
}

func New(baseURL string) *Client {
	return &Client{
		BaseURL: strings.TrimSuffix(baseURL, "/"),
		HTTP:    &http.Client{Timeout: 15 * time.Second},
	}
}

func (c *Client) Health(ctx context.Context, endpoint string) error {
	response, err := c.do(ctx, http.MethodGet, "/health/"+endpoint, "", "", nil)
	if err != nil {
		return err
	}
	if response.Status != http.StatusOK {
		return response.problem()
	}
	return nil
}

func (c *Client) List(ctx context.Context) (ListResponse, error) {
	response, err := c.do(ctx, http.MethodGet, "/api/v1/parcels", "", "", nil)
	if err != nil {
		return ListResponse{}, err
	}
	var result ListResponse
	return result, response.decode(http.StatusOK, &result)
}

func (c *Client) Get(ctx context.Context, trackingID string) (domain.Parcel, error) {
	response, err := c.do(ctx, http.MethodGet, "/api/v1/parcels/"+trackingID, "", "", nil)
	if err != nil {
		return domain.Parcel{}, err
	}
	var parcel domain.Parcel
	return parcel, response.decode(http.StatusOK, &parcel)
}

func (c *Client) Create(ctx context.Context, input domain.CreateParcel, key string) (domain.Parcel, bool, error) {
	body, _ := json.Marshal(input)
	response, err := c.do(ctx, http.MethodPost, "/api/v1/parcels", "application/json", key, body)
	if err != nil {
		return domain.Parcel{}, false, err
	}
	if response.Status != http.StatusCreated && response.Status != http.StatusOK {
		return domain.Parcel{}, false, response.problem()
	}
	var parcel domain.Parcel
	err = json.Unmarshal(response.Body, &parcel)
	return parcel, response.Header.Get("Idempotency-Replayed") == "true", err
}

func (c *Client) Advance(ctx context.Context, trackingID, key string) (domain.Command, bool, error) {
	response, err := c.do(ctx, http.MethodPost, "/api/v1/parcels/"+trackingID+"/commands/advance", "", key, nil)
	if err != nil {
		return domain.Command{}, false, err
	}
	if response.Status != http.StatusAccepted {
		return domain.Command{}, false, response.problem()
	}
	var command domain.Command
	err = json.Unmarshal(response.Body, &command)
	return command, response.Header.Get("Idempotency-Replayed") == "true", err
}

func (c *Client) UploadProof(ctx context.Context, trackingID, key, contentType string, body []byte) (domain.Proof, bool, error) {
	response, err := c.do(ctx, http.MethodPost, "/api/v1/parcels/"+trackingID+"/proof-of-delivery", contentType, key, body)
	if err != nil {
		return domain.Proof{}, false, err
	}
	if response.Status != http.StatusCreated && response.Status != http.StatusOK {
		return domain.Proof{}, false, response.problem()
	}
	var proof domain.Proof
	err = json.Unmarshal(response.Body, &proof)
	return proof, response.Header.Get("Idempotency-Replayed") == "true", err
}

func (c *Client) DownloadProof(ctx context.Context, trackingID string) (Response, error) {
	response, err := c.do(ctx, http.MethodGet, "/api/v1/parcels/"+trackingID+"/proof-of-delivery", "", "", nil)
	if err != nil {
		return Response{}, err
	}
	if response.Status != http.StatusOK {
		return response, response.problem()
	}
	return response, nil
}

func (c *Client) do(ctx context.Context, method, path, contentType, key string, body []byte) (Response, error) {
	request, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, bytes.NewReader(body))
	if err != nil {
		return Response{}, err
	}
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	if key != "" {
		request.Header.Set("Idempotency-Key", key)
	}
	request.Header.Set("Accept", "application/json")
	response, err := c.HTTP.Do(request)
	if err != nil {
		return Response{}, fmt.Errorf("%s %s: %w", method, path, err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 2<<20))
	if err != nil {
		return Response{}, err
	}
	return Response{Status: response.StatusCode, Header: response.Header.Clone(), Body: data}, nil
}

func (r Response) decode(status int, target any) error {
	if r.Status != status {
		return r.problem()
	}
	if err := json.Unmarshal(r.Body, target); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}
	return nil
}

func (r Response) problem() error {
	var p struct {
		Title     string `json:"title"`
		Detail    string `json:"detail"`
		RequestID string `json:"requestId"`
	}
	if json.Unmarshal(r.Body, &p) == nil && p.Detail != "" {
		return fmt.Errorf("HTTP %d %s: %s (request %s)", r.Status, p.Title, p.Detail, p.RequestID)
	}
	return fmt.Errorf("HTTP %d: %s", r.Status, strings.TrimSpace(string(r.Body)))
}
