package logging

import (
	"log/slog"
	"os"
)

func New(environment, component string) *slog.Logger {
	level := slog.LevelInfo
	if environment == "development" {
		level = slog.LevelDebug
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level})).With("service", component, "environment", environment)
}
