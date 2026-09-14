package domain

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
)

type Status string

const (
	LabelCreated    Status = "label_created"
	PickedUp        Status = "picked_up"
	AtSortingCenter Status = "at_sorting_center"
	InTransit       Status = "in_transit"
	OutForDelivery  Status = "out_for_delivery"
	Delivered       Status = "delivered"
)

var (
	lifecycle     = []Status{LabelCreated, PickedUp, AtSortingCenter, InTransit, OutForDelivery, Delivered}
	trackingIDRE  = regexp.MustCompile(`^PF-[A-Z0-9]{10,24}$`)
	idempotencyRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$`)
	uuidRE        = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
)

type Parcel struct {
	TrackingID      string    `json:"trackingId"`
	RecipientName   string    `json:"recipientName"`
	DeliveryAddress string    `json:"deliveryAddress"`
	Status          Status    `json:"status"`
	CreatedAt       time.Time `json:"createdAt"`
	UpdatedAt       time.Time `json:"updatedAt"`
	Events          []Event   `json:"events"`
	ProofOfDelivery *Proof    `json:"proofOfDelivery,omitempty"`
}

type Event struct {
	ID            string    `json:"id"`
	FromStatus    *Status   `json:"fromStatus,omitempty"`
	ToStatus      Status    `json:"toStatus"`
	CommandID     *string   `json:"commandId,omitempty"`
	CorrelationID string    `json:"correlationId"`
	OccurredAt    time.Time `json:"occurredAt"`
}

type Proof struct {
	ContentType string    `json:"contentType"`
	Filename    string    `json:"filename"`
	SHA256      string    `json:"sha256"`
	Size        int64     `json:"size"`
	UploadedAt  time.Time `json:"uploadedAt"`
}

type CreateParcel struct {
	RecipientName   string `json:"recipientName"`
	DeliveryAddress string `json:"deliveryAddress"`
}

type Command struct {
	ID             string    `json:"id"`
	TrackingID     string    `json:"trackingId"`
	FromStatus     Status    `json:"fromStatus"`
	ToStatus       Status    `json:"toStatus"`
	IdempotencyKey string    `json:"idempotencyKey"`
	CorrelationID  string    `json:"correlationId"`
	CreatedAt      time.Time `json:"createdAt"`
}

func Next(s Status) (Status, bool) {
	for i := range lifecycle {
		if lifecycle[i] == s && i+1 < len(lifecycle) {
			return lifecycle[i+1], true
		}
	}
	return "", false
}

func ValidStatus(s Status) bool {
	for _, candidate := range lifecycle {
		if candidate == s {
			return true
		}
	}
	return false
}

func ValidateCreate(v CreateParcel) error {
	v.RecipientName = strings.TrimSpace(v.RecipientName)
	v.DeliveryAddress = strings.TrimSpace(v.DeliveryAddress)
	if n := len(v.RecipientName); n < 2 || n > 100 {
		return errors.New("recipientName must contain 2 to 100 characters")
	}
	if n := len(v.DeliveryAddress); n < 8 || n > 240 {
		return errors.New("deliveryAddress must contain 8 to 240 characters")
	}
	return nil
}

func ValidateTrackingID(v string) error {
	if !trackingIDRE.MatchString(v) {
		return errors.New("tracking ID has an invalid format")
	}
	return nil
}

func ValidateIdempotencyKey(v string) error {
	if !idempotencyRE.MatchString(v) {
		return errors.New("Idempotency-Key must contain 8 to 128 safe characters")
	}
	return nil
}

func ValidateID(v string) error {
	if !uuidRE.MatchString(v) {
		return errors.New("identifier must be a canonical UUID")
	}
	return nil
}

func NewID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(fmt.Sprintf("secure random source unavailable: %v", err))
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%s-%s-%s-%s-%s", hex.EncodeToString(b[0:4]), hex.EncodeToString(b[4:6]), hex.EncodeToString(b[6:8]), hex.EncodeToString(b[8:10]), hex.EncodeToString(b[10:16]))
}

func NewTrackingID() string {
	var b [7]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(fmt.Sprintf("secure random source unavailable: %v", err))
	}
	return "PF-" + strings.ToUpper(hex.EncodeToString(b[:]))
}
