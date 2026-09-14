package config

import (
	"strings"
	"testing"
)

func TestDatabaseURLEscapesCredentials(t *testing.T) {
	database := Database{Host: "db.example", Port: "5432", Name: "parcelflow", User: "app@demo", Password: "a:/?#[]@b", SSLMode: "verify-full"}
	got := database.URL()
	for _, expected := range []string{"app%40demo", "a%3A%2F%3F%23%5B%5D%40b", "sslmode=verify-full"} {
		if !strings.Contains(got, expected) {
			t.Errorf("URL %q does not contain %q", got, expected)
		}
	}
}

func TestValidateProviderAndCredentials(t *testing.T) {
	valid := Config{
		Database:    Database{Host: "db", Port: "5432", Name: "app", User: "app", Password: "secret", SSLMode: "require"},
		Queue:       Queue{Provider: "rabbitmq", Endpoint: "rabbit", Name: "commands", CredentialMode: "password", Username: "app", Password: "secret"},
		ObjectStore: ObjectStore{Provider: "azurite", Endpoint: "http://blob", Container: "proofs", CredentialMode: "shared-key", AccountName: "dev", AccountKey: "key"},
		HTTPPort:    8080,
	}
	if err := valid.Validate(); err != nil {
		t.Fatal(err)
	}
	valid.Queue.Provider = "memory"
	if err := valid.Validate(); err == nil {
		t.Fatal("unsupported queue provider accepted")
	}
}

func TestLoadWorkerDoesNotRequireObjectStore(t *testing.T) {
	values := map[string]string{
		"DATABASE_HOST": "db", "DATABASE_NAME": "app", "DATABASE_USER": "app", "DATABASE_PASSWORD": "secret",
		"QUEUE_PROVIDER": "rabbitmq", "QUEUE_ENDPOINT": "rabbit:5672", "QUEUE_NAME": "commands",
		"QUEUE_CREDENTIAL_MODE": "password", "QUEUE_USERNAME": "app", "QUEUE_PASSWORD": "secret",
	}
	for name, value := range values {
		t.Setenv(name, value)
	}
	t.Setenv("OBJECT_STORE_PROVIDER", "")
	t.Setenv("OBJECT_STORE_ENDPOINT", "")
	t.Setenv("OBJECT_STORE_CONTAINER", "")
	t.Setenv("OBJECT_STORE_CREDENTIAL_MODE", "")
	if _, err := LoadWorker(); err != nil {
		t.Fatal(err)
	}
}
