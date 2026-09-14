package httpapi

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"mime"
	"net/http"
	"path"
	"regexp"
	"runtime/debug"
	"strings"
	"time"

	"github.com/Akash3121/score-parcelflow-azure/internal/domain"
	"github.com/Akash3121/score-parcelflow-azure/internal/objectstore"
	"github.com/Akash3121/score-parcelflow-azure/internal/store"
	"github.com/Akash3121/score-parcelflow-azure/web"
)

const maxProofSize = 1 << 20

var requestIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$`)

type Server struct {
	store       *store.Postgres
	objects     objectstore.Store
	logger      *slog.Logger
	environment string
	buildSHA    string
	handler     http.Handler
}

type problem struct {
	Type      string `json:"type"`
	Title     string `json:"title"`
	Status    int    `json:"status"`
	Detail    string `json:"detail"`
	Instance  string `json:"instance"`
	RequestID string `json:"requestId"`
}

type contextKey string

const requestIDKey contextKey = "request-id"

func New(database *store.Postgres, objects objectstore.Store, logger *slog.Logger, environment, buildSHA string) *Server {
	s := &Server{store: database, objects: objects, logger: logger, environment: environment, buildSHA: buildSHA}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health/live", s.live)
	mux.HandleFunc("GET /health/ready", s.ready)
	mux.HandleFunc("GET /api/v1/build", s.build)
	mux.HandleFunc("GET /api/v1/parcels", s.listParcels)
	mux.HandleFunc("POST /api/v1/parcels", s.createParcel)
	mux.HandleFunc("GET /api/v1/parcels/{trackingID}", s.getParcel)
	mux.HandleFunc("POST /api/v1/parcels/{trackingID}/commands/advance", s.advance)
	mux.HandleFunc("POST /api/v1/parcels/{trackingID}/proof-of-delivery", s.uploadProof)
	mux.HandleFunc("GET /api/v1/parcels/{trackingID}/proof-of-delivery", s.downloadProof)
	assets, _ := fs.Sub(web.Assets, ".")
	mux.Handle("GET /assets/", http.StripPrefix("/assets/", http.FileServer(http.FS(assets))))
	mux.HandleFunc("/", s.fallback)
	s.handler = s.middleware(mux)
	return s
}

func (s *Server) Handler() http.Handler { return s.handler }

func (s *Server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		requestID := strings.TrimSpace(r.Header.Get("X-Request-ID"))
		if !requestIDPattern.MatchString(requestID) {
			requestID = domain.NewID()
		}
		ctx := context.WithValue(r.Context(), requestIDKey, requestID)
		w.Header().Set("X-Request-ID", requestID)
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")
		recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		defer func() {
			if recovered := recover(); recovered != nil {
				s.logger.Error("request panic", "request_id", requestID, "panic", recovered, "stack", string(debug.Stack()))
				s.writeProblem(recorder, r, http.StatusInternalServerError, "Internal Server Error", "The request could not be completed.")
			}
			s.logger.Info("http request", "method", r.Method, "path", r.URL.Path, "status", recorder.status, "duration_ms", time.Since(start).Milliseconds(), "request_id", requestID)
		}()
		next.ServeHTTP(recorder, r.WithContext(ctx))
	})
}

func (s *Server) live(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "live"})
}

func (s *Server) ready(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.store.Ping(ctx); err != nil {
		s.writeProblem(w, r, http.StatusServiceUnavailable, "Not Ready", "Database connectivity check failed.")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (s *Server) build(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, struct {
		Environment string `json:"environment"`
		BuildSHA    string `json:"buildSha"`
	}{s.environment, s.buildSHA})
}

func (s *Server) listParcels(w http.ResponseWriter, r *http.Request) {
	items, err := s.store.ListParcels(r.Context())
	if err != nil {
		s.internal(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, struct {
		Items []domain.Parcel `json:"items"`
		Count int             `json:"count"`
	}{items, len(items)})
}

func (s *Server) createParcel(w http.ResponseWriter, r *http.Request) {
	key, ok := s.idempotencyKey(w, r)
	if !ok {
		return
	}
	var input domain.CreateParcel
	if err := decodeJSON(w, r, &input, 32<<10); err != nil {
		s.writeProblem(w, r, http.StatusBadRequest, "Invalid Request", err.Error())
		return
	}
	if err := domain.ValidateCreate(input); err != nil {
		s.writeProblem(w, r, http.StatusUnprocessableEntity, "Validation Failed", err.Error())
		return
	}
	parcel, replay, err := s.store.CreateParcel(r.Context(), input, key, requestID(r))
	if errors.Is(err, store.ErrConflict) {
		s.writeProblem(w, r, http.StatusConflict, "Idempotency Conflict", "The idempotency key was already used with different content.")
		return
	}
	if err != nil {
		s.internal(w, r, err)
		return
	}
	if replay {
		w.Header().Set("Idempotency-Replayed", "true")
		writeJSON(w, http.StatusOK, parcel)
		return
	}
	w.Header().Set("Location", "/api/v1/parcels/"+parcel.TrackingID)
	writeJSON(w, http.StatusCreated, parcel)
}

func (s *Server) getParcel(w http.ResponseWriter, r *http.Request) {
	trackingID, ok := s.trackingID(w, r)
	if !ok {
		return
	}
	parcel, err := s.store.GetParcel(r.Context(), trackingID)
	if errors.Is(err, store.ErrNotFound) {
		s.writeProblem(w, r, http.StatusNotFound, "Parcel Not Found", "No parcel exists with that tracking ID.")
		return
	}
	if err != nil {
		s.internal(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, parcel)
}

func (s *Server) advance(w http.ResponseWriter, r *http.Request) {
	trackingID, ok := s.trackingID(w, r)
	if !ok {
		return
	}
	key, ok := s.idempotencyKey(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		s.writeProblem(w, r, http.StatusRequestEntityTooLarge, "Request Too Large", "Advance command bodies are limited to 1 KiB.")
		return
	}
	if strings.TrimSpace(string(body)) != "" {
		s.writeProblem(w, r, http.StatusBadRequest, "Invalid Request", "The advance command does not accept a request body.")
		return
	}
	command, replay, err := s.store.Advance(r.Context(), trackingID, key, requestID(r))
	switch {
	case errors.Is(err, store.ErrNotFound):
		s.writeProblem(w, r, http.StatusNotFound, "Parcel Not Found", "No parcel exists with that tracking ID.")
		return
	case errors.Is(err, store.ErrTerminal):
		s.writeProblem(w, r, http.StatusConflict, "Terminal State", "A delivered parcel cannot advance.")
		return
	case errors.Is(err, store.ErrAdvancePending):
		s.writeProblem(w, r, http.StatusConflict, "Advance Pending", "Wait for the outstanding delivery command to complete.")
		return
	case err != nil:
		s.internal(w, r, err)
		return
	}
	if replay {
		w.Header().Set("Idempotency-Replayed", "true")
	}
	writeJSON(w, http.StatusAccepted, command)
}

func (s *Server) uploadProof(w http.ResponseWriter, r *http.Request) {
	trackingID, ok := s.trackingID(w, r)
	if !ok {
		return
	}
	if _, ok := s.idempotencyKey(w, r); !ok {
		return
	}
	contentType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || !allowedContentType(contentType) {
		s.writeProblem(w, r, http.StatusUnsupportedMediaType, "Unsupported Media Type", "Proof must be a PDF, JPEG, or PNG.")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxProofSize+1)
	data, err := io.ReadAll(r.Body)
	if err != nil || len(data) > maxProofSize {
		s.writeProblem(w, r, http.StatusRequestEntityTooLarge, "Proof Too Large", "Proof uploads are limited to 1 MiB.")
		return
	}
	if len(data) == 0 || !contentMatches(contentType, data) {
		s.writeProblem(w, r, http.StatusUnprocessableEntity, "Invalid Proof", "The file content does not match its declared media type.")
		return
	}
	sum := sha256.Sum256(data)
	checksum := hex.EncodeToString(sum[:])
	filename := "proof-" + trackingID + extension(contentType)
	proof := domain.Proof{ContentType: contentType, Filename: filename, SHA256: checksum, Size: int64(len(data)), UploadedAt: time.Now().UTC().Truncate(time.Microsecond)}
	if existing, err := s.store.GetProof(r.Context(), trackingID); err == nil {
		if existing.Proof.SHA256 != checksum || existing.Proof.ContentType != contentType {
			s.writeProblem(w, r, http.StatusConflict, "Proof Conflict", "A different proof is already stored for this parcel.")
			return
		}
		w.Header().Set("Idempotency-Replayed", "true")
		writeJSON(w, http.StatusOK, existing.Proof)
		return
	} else if !errors.Is(err, store.ErrNotFound) {
		s.internal(w, r, err)
		return
	}
	objectKey := "proofs/" + trackingID + "/" + checksum + extension(contentType)
	if err := s.objects.Put(r.Context(), objectKey, contentType, data); err != nil {
		s.internal(w, r, fmt.Errorf("store proof object: %w", err))
		return
	}
	record, replay, err := s.store.SaveProof(r.Context(), trackingID, objectKey, proof)
	if err != nil {
		_ = s.objects.Delete(context.Background(), objectKey)
		if errors.Is(err, store.ErrNotFound) {
			s.writeProblem(w, r, http.StatusNotFound, "Parcel Not Found", "No parcel exists with that tracking ID.")
		} else if errors.Is(err, store.ErrConflict) {
			s.writeProblem(w, r, http.StatusConflict, "Proof Conflict", "Proof can only be added to a delivered parcel and cannot be replaced.")
		} else {
			s.internal(w, r, err)
		}
		return
	}
	if replay {
		w.Header().Set("Idempotency-Replayed", "true")
		writeJSON(w, http.StatusOK, record.Proof)
		return
	}
	writeJSON(w, http.StatusCreated, record.Proof)
}

func (s *Server) downloadProof(w http.ResponseWriter, r *http.Request) {
	trackingID, ok := s.trackingID(w, r)
	if !ok {
		return
	}
	record, err := s.store.GetProof(r.Context(), trackingID)
	if errors.Is(err, store.ErrNotFound) {
		s.writeProblem(w, r, http.StatusNotFound, "Proof Not Found", "No proof of delivery is stored for this parcel.")
		return
	}
	if err != nil {
		s.internal(w, r, err)
		return
	}
	body, err := s.objects.Get(r.Context(), record.ObjectKey)
	if err != nil {
		s.internal(w, r, fmt.Errorf("retrieve proof object: %w", err))
		return
	}
	defer body.Close()
	w.Header().Set("Content-Type", record.Proof.ContentType)
	w.Header().Set("Content-Length", fmt.Sprint(record.Proof.Size))
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": path.Base(record.Proof.Filename)}))
	decodedChecksum, _ := hex.DecodeString(record.Proof.SHA256)
	w.Header().Set("Digest", "sha-256=:"+base64.StdEncoding.EncodeToString(decodedChecksum)+":")
	w.Header().Set("X-Content-SHA256", record.Proof.SHA256)
	w.WriteHeader(http.StatusOK)
	_, _ = io.Copy(w, io.LimitReader(body, maxProofSize+1))
}

func (s *Server) index(w http.ResponseWriter, r *http.Request) {
	body, err := web.Assets.ReadFile("index.html")
	if err != nil {
		s.internal(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(body)
}

func (s *Server) fallback(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/" && r.Method == http.MethodGet {
		s.index(w, r)
		return
	}
	if knownPath(r.URL.Path) {
		w.Header().Set("Allow", allowedMethods(r.URL.Path))
		s.writeProblem(w, r, http.StatusMethodNotAllowed, "Method Not Allowed", "The requested method is not supported for this resource.")
		return
	}
	if r.URL.Path != "/" {
		s.writeProblem(w, r, http.StatusNotFound, "Not Found", "The requested resource does not exist.")
		return
	}
	s.writeProblem(w, r, http.StatusMethodNotAllowed, "Method Not Allowed", "The requested method is not supported for this resource.")
}

func (s *Server) trackingID(w http.ResponseWriter, r *http.Request) (string, bool) {
	value := r.PathValue("trackingID")
	if err := domain.ValidateTrackingID(value); err != nil {
		s.writeProblem(w, r, http.StatusBadRequest, "Invalid Tracking ID", err.Error())
		return "", false
	}
	return value, true
}

func (s *Server) idempotencyKey(w http.ResponseWriter, r *http.Request) (string, bool) {
	value := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if err := domain.ValidateIdempotencyKey(value); err != nil {
		s.writeProblem(w, r, http.StatusBadRequest, "Invalid Idempotency Key", err.Error())
		return "", false
	}
	return value, true
}

func (s *Server) internal(w http.ResponseWriter, r *http.Request, err error) {
	s.logger.Error("request failed", "request_id", requestID(r), "error", err)
	s.writeProblem(w, r, http.StatusInternalServerError, "Internal Server Error", "The request could not be completed.")
}

func (s *Server) writeProblem(w http.ResponseWriter, r *http.Request, status int, title, detail string) {
	w.Header().Set("Content-Type", "application/problem+json")
	writeJSON(w, status, problem{
		Type:  "https://parcelflow.example/problems/" + strings.ReplaceAll(strings.ToLower(title), " ", "-"),
		Title: title, Status: status, Detail: detail, Instance: r.URL.Path, RequestID: requestID(r),
	})
}

func requestID(r *http.Request) string {
	value, _ := r.Context().Value(requestIDKey).(string)
	return value
}

func decodeJSON(w http.ResponseWriter, r *http.Request, target any, max int64) error {
	if mediaType, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type")); mediaType != "application/json" {
		return errors.New("Content-Type must be application/json")
	}
	r.Body = http.MaxBytesReader(w, r.Body, max)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return fmt.Errorf("invalid JSON body: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("request body must contain exactly one JSON object")
	}
	return nil
}

func allowedContentType(v string) bool {
	return v == "application/pdf" || v == "image/jpeg" || v == "image/png"
}

func contentMatches(contentType string, data []byte) bool {
	switch contentType {
	case "application/pdf":
		return len(data) >= 5 && string(data[:5]) == "%PDF-"
	case "image/jpeg":
		return http.DetectContentType(data) == "image/jpeg"
	case "image/png":
		return http.DetectContentType(data) == "image/png"
	default:
		return false
	}
}

func extension(contentType string) string {
	switch contentType {
	case "application/pdf":
		return ".pdf"
	case "image/jpeg":
		return ".jpg"
	default:
		return ".png"
	}
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	if w.Header().Get("Content-Type") == "" {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
	}
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func knownPath(value string) bool {
	if value == "/health/live" || value == "/health/ready" || value == "/api/v1/build" || value == "/api/v1/parcels" {
		return true
	}
	if !strings.HasPrefix(value, "/api/v1/parcels/") {
		return false
	}
	suffix := strings.TrimPrefix(value, "/api/v1/parcels/")
	parts := strings.Split(suffix, "/")
	return len(parts) == 1 ||
		len(parts) == 3 && parts[1] == "commands" && parts[2] == "advance" ||
		len(parts) == 2 && parts[1] == "proof-of-delivery"
}

func allowedMethods(value string) string {
	if value == "/api/v1/parcels" {
		return "GET, POST"
	}
	if strings.HasSuffix(value, "/proof-of-delivery") {
		return "GET, POST"
	}
	if strings.HasSuffix(value, "/commands/advance") {
		return "POST"
	}
	return "GET"
}

type statusRecorder struct {
	http.ResponseWriter
	status int
	wrote  bool
}

func (w *statusRecorder) WriteHeader(status int) {
	if w.wrote {
		return
	}
	w.wrote = true
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (w *statusRecorder) Write(body []byte) (int, error) {
	if !w.wrote {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(body)
}
