package config

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Database    Database
	Queue       Queue
	ObjectStore ObjectStore
	HTTPPort    int
	Environment string
	BuildSHA    string
}

type Database struct {
	Host, Port, Name, User, Password, SSLMode string
}

type Queue struct {
	Provider, Endpoint, Name, CredentialMode, Username, Password string
}

type ObjectStore struct {
	Provider, Endpoint, Container, CredentialMode, AccountName, AccountKey string
}

func Load() (Config, error) {
	return load(true)
}

func LoadWorker() (Config, error) {
	return load(false)
}

func load(requireObjectStore bool) (Config, error) {
	port, err := strconv.Atoi(value("HTTP_PORT", "8080"))
	if err != nil || port < 1 || port > 65535 {
		return Config{}, errors.New("HTTP_PORT must be between 1 and 65535")
	}
	c := Config{
		Database: Database{
			Host:     required("DATABASE_HOST"),
			Port:     value("DATABASE_PORT", "5432"),
			Name:     required("DATABASE_NAME"),
			User:     required("DATABASE_USER"),
			Password: required("DATABASE_PASSWORD"),
			SSLMode:  value("DATABASE_SSLMODE", "require"),
		},
		Queue: Queue{
			Provider:       required("QUEUE_PROVIDER"),
			Endpoint:       required("QUEUE_ENDPOINT"),
			Name:           required("QUEUE_NAME"),
			CredentialMode: required("QUEUE_CREDENTIAL_MODE"),
			Username:       os.Getenv("QUEUE_USERNAME"),
			Password:       os.Getenv("QUEUE_PASSWORD"),
		},
		ObjectStore: ObjectStore{
			Provider:       required("OBJECT_STORE_PROVIDER"),
			Endpoint:       required("OBJECT_STORE_ENDPOINT"),
			Container:      required("OBJECT_STORE_CONTAINER"),
			CredentialMode: required("OBJECT_STORE_CREDENTIAL_MODE"),
			AccountName:    os.Getenv("OBJECT_STORE_ACCOUNT_NAME"),
			AccountKey:     os.Getenv("OBJECT_STORE_ACCOUNT_KEY"),
		},
		HTTPPort:    port,
		Environment: value("ENVIRONMENT", "development"),
		BuildSHA:    value("BUILD_SHA", "dev"),
	}
	if err := c.validate(requireObjectStore); err != nil {
		return Config{}, err
	}
	return c, nil
}

func (c Config) Validate() error {
	return c.validate(true)
}

func (c Config) validate(requireObjectStore bool) error {
	var missing []string
	requiredValues := map[string]string{
		"DATABASE_HOST": c.Database.Host, "DATABASE_NAME": c.Database.Name,
		"DATABASE_USER": c.Database.User, "DATABASE_PASSWORD": c.Database.Password,
		"QUEUE_PROVIDER": c.Queue.Provider, "QUEUE_ENDPOINT": c.Queue.Endpoint,
		"QUEUE_NAME": c.Queue.Name, "QUEUE_CREDENTIAL_MODE": c.Queue.CredentialMode,
	}
	if requireObjectStore {
		requiredValues["OBJECT_STORE_PROVIDER"] = c.ObjectStore.Provider
		requiredValues["OBJECT_STORE_ENDPOINT"] = c.ObjectStore.Endpoint
		requiredValues["OBJECT_STORE_CONTAINER"] = c.ObjectStore.Container
		requiredValues["OBJECT_STORE_CREDENTIAL_MODE"] = c.ObjectStore.CredentialMode
	}
	for name, v := range requiredValues {
		if strings.TrimSpace(v) == "" {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return fmt.Errorf("missing required environment configuration: %s", strings.Join(missing, ", "))
	}
	databasePort, err := strconv.Atoi(c.Database.Port)
	if err != nil || databasePort < 1 || databasePort > 65535 {
		return errors.New("DATABASE_PORT must be between 1 and 65535")
	}
	switch c.Database.SSLMode {
	case "disable", "allow", "prefer", "require", "verify-ca", "verify-full":
	default:
		return fmt.Errorf("unsupported DATABASE_SSLMODE %q", c.Database.SSLMode)
	}
	if c.Queue.Provider != "rabbitmq" && c.Queue.Provider != "azure-servicebus" {
		return fmt.Errorf("unsupported QUEUE_PROVIDER %q", c.Queue.Provider)
	}
	if requireObjectStore && c.ObjectStore.Provider != "azurite" && c.ObjectStore.Provider != "azure-blob" {
		return fmt.Errorf("unsupported OBJECT_STORE_PROVIDER %q", c.ObjectStore.Provider)
	}
	if c.Queue.CredentialMode != "password" && c.Queue.CredentialMode != "workload-identity" {
		return fmt.Errorf("unsupported QUEUE_CREDENTIAL_MODE %q", c.Queue.CredentialMode)
	}
	if c.Queue.Provider == "rabbitmq" && c.Queue.CredentialMode != "password" {
		return errors.New("RabbitMQ requires QUEUE_CREDENTIAL_MODE=password")
	}
	if requireObjectStore && c.ObjectStore.CredentialMode != "shared-key" && c.ObjectStore.CredentialMode != "workload-identity" {
		return fmt.Errorf("unsupported OBJECT_STORE_CREDENTIAL_MODE %q", c.ObjectStore.CredentialMode)
	}
	if requireObjectStore && c.ObjectStore.Provider == "azurite" && c.ObjectStore.CredentialMode != "shared-key" {
		return errors.New("Azurite requires OBJECT_STORE_CREDENTIAL_MODE=shared-key")
	}
	if c.Queue.CredentialMode == "password" && (c.Queue.Username == "" || c.Queue.Password == "") {
		return errors.New("QUEUE_USERNAME and QUEUE_PASSWORD are required in password mode")
	}
	if requireObjectStore && c.ObjectStore.CredentialMode == "shared-key" && (c.ObjectStore.AccountName == "" || c.ObjectStore.AccountKey == "") {
		return errors.New("OBJECT_STORE_ACCOUNT_NAME and OBJECT_STORE_ACCOUNT_KEY are required in shared-key mode")
	}
	return nil
}

func (d Database) URL() string {
	u := &url.URL{Scheme: "postgres", User: url.UserPassword(d.User, d.Password), Host: net.JoinHostPort(d.Host, d.Port), Path: d.Name}
	q := u.Query()
	q.Set("sslmode", d.SSLMode)
	q.Set("connect_timeout", strconv.Itoa(int((10 * time.Second).Seconds())))
	u.RawQuery = q.Encode()
	return u.String()
}

func required(name string) string { return strings.TrimSpace(os.Getenv(name)) }
func value(name, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(name)); v != "" {
		return v
	}
	return fallback
}
