package domain

import "testing"

func TestLifecycle(t *testing.T) {
	state := LabelCreated
	want := []Status{PickedUp, AtSortingCenter, InTransit, OutForDelivery, Delivered}
	for _, expected := range want {
		next, ok := Next(state)
		if !ok || next != expected {
			t.Fatalf("Next(%q) = %q, %v; want %q, true", state, next, ok, expected)
		}
		state = next
	}
	if _, ok := Next(Delivered); ok {
		t.Fatal("delivered parcel must be terminal")
	}
}

func TestValidationBounds(t *testing.T) {
	if ValidateCreate(CreateParcel{RecipientName: "Ada", DeliveryAddress: "1 Parcel Way"}) != nil {
		t.Fatal("valid parcel rejected")
	}
	if ValidateCreate(CreateParcel{RecipientName: "x", DeliveryAddress: "1 Parcel Way"}) == nil {
		t.Fatal("short recipient accepted")
	}
	if ValidateIdempotencyKey("smoke-key-001") != nil {
		t.Fatal("valid idempotency key rejected")
	}
	if ValidateIdempotencyKey("short") == nil {
		t.Fatal("short idempotency key accepted")
	}
}
