# syntax=docker/dockerfile:1.7
FROM golang:1.24.6-alpine3.22 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
COPY migrations ./migrations
COPY web ./web
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/delivery-worker ./cmd/worker

FROM alpine:3.22.1
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN addgroup -S -g 10001 parcelflow \
    && adduser -S -D -H -u 10001 -G parcelflow parcelflow
WORKDIR /app
COPY --from=build /out/delivery-worker /app/delivery-worker
USER 10001:10001
ENTRYPOINT ["/app/delivery-worker"]
