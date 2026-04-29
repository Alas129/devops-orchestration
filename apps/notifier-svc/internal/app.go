package notifier

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"sync"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/rds/auth"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nats-io/nats.go"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type App struct {
	cfg *Config
	db  *pgxpool.Pool
	nc  *nats.Conn
	js  nats.JetStreamContext

	subsMu      sync.Mutex
	subscribers map[chan []byte]struct{}

	processed prometheus.Counter
}

func New(ctx context.Context, cfg *Config) (*App, error) {
	pool, err := newDBPool(ctx, cfg)
	if err != nil {
		return nil, err
	}
	nc, err := nats.Connect(cfg.NATSURL,
		nats.Name("notifier-svc"),
		nats.MaxReconnects(-1),
		nats.ReconnectWait(2*time.Second),
	)
	if err != nil {
		return nil, fmt.Errorf("nats: %w", err)
	}
	js, err := nc.JetStream()
	if err != nil {
		return nil, err
	}
	return &App{
		cfg:         cfg,
		db:          pool,
		nc:          nc,
		js:          js,
		subscribers: map[chan []byte]struct{}{},
		processed: promauto.NewCounter(prometheus.CounterOpts{
			Name: "notifier_events_processed_total",
			Help: "Events consumed from NATS and persisted",
		}),
	}, nil
}

func (a *App) Close() {
	if a.nc != nil {
		a.nc.Close()
	}
	if a.db != nil {
		a.db.Close()
	}
}

func (a *App) Router() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RequestID, middleware.RealIP, middleware.Recoverer)
	r.Get("/healthz", a.healthz)
	r.Get("/livez", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200); _, _ = w.Write([]byte("ok")) })
	r.Method("GET", "/metrics", promhttp.HandlerFor(prometheus.DefaultGatherer, promhttp.HandlerOpts{}))

	r.Get("/api/v1/notifications/stream", a.stream)
	return r
}

func (a *App) healthz(w http.ResponseWriter, r *http.Request) {
	if err := a.db.Ping(r.Context()); err != nil {
		http.Error(w, "db", 503)
		return
	}
	if !a.nc.IsConnected() {
		http.Error(w, "nats", 503)
		return
	}
	w.WriteHeader(200)
	_, _ = w.Write([]byte("ok"))
}

// Subscribe consumes from JetStream and persists notifications, then fans
// out to SSE subscribers. JetStream durability means re-deliveries on
// notifier-svc restart.
func (a *App) Subscribe(ctx context.Context) {
	sub, err := a.js.PullSubscribe("tasks.>", "notifier-durable")
	if err != nil {
		slog.Error("pull subscribe", "err", err)
		return
	}
	for ctx.Err() == nil {
		msgs, err := sub.Fetch(10, nats.MaxWait(5*time.Second))
		if err != nil {
			if err != nats.ErrTimeout {
				slog.Warn("fetch", "err", err)
			}
			continue
		}
		for _, m := range msgs {
			a.handle(ctx, m)
			_ = m.Ack()
		}
	}
}

func (a *App) handle(ctx context.Context, m *nats.Msg) {
	var task struct {
		ID     int64  `json:"id"`
		UserID int64  `json:"user_id"`
		Name   string `json:"name"`
	}
	if err := json.Unmarshal(m.Data, &task); err != nil {
		slog.Warn("unmarshal", "err", err)
		return
	}
	body := fmt.Sprintf("event=%s task=%s", m.Subject, task.Name)
	_, err := a.db.Exec(ctx,
		`INSERT INTO notifications (user_id, kind, body) VALUES ($1, $2, $3)`,
		task.UserID, m.Subject, body)
	if err != nil {
		slog.Warn("persist notification", "err", err)
		return
	}
	a.processed.Inc()
	a.fanout([]byte(fmt.Sprintf("data: %s\n\n", body)))
}

func (a *App) fanout(b []byte) {
	a.subsMu.Lock()
	defer a.subsMu.Unlock()
	for ch := range a.subscribers {
		select {
		case ch <- b:
		default: // slow consumer — drop
		}
	}
}

// SSE stream of notifications.
func (a *App) stream(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", 500)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	ch := make(chan []byte, 16)
	a.subsMu.Lock()
	a.subscribers[ch] = struct{}{}
	a.subsMu.Unlock()
	defer func() {
		a.subsMu.Lock()
		delete(a.subscribers, ch)
		a.subsMu.Unlock()
	}()

	for {
		select {
		case <-r.Context().Done():
			return
		case b := <-ch:
			_, _ = w.Write(b)
			flusher.Flush()
		case <-time.After(15 * time.Second):
			_, _ = w.Write([]byte(": keepalive\n\n"))
			flusher.Flush()
		}
	}
}

func newDBPool(ctx context.Context, cfg *Config) (*pgxpool.Pool, error) {
	pwd := cfg.DBPassword
	if cfg.UseIAMAuth {
		awsCfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(cfg.AWSRegion))
		if err != nil {
			return nil, err
		}
		token, err := auth.BuildAuthToken(ctx, fmt.Sprintf("%s:%s", cfg.DBHost, cfg.DBPort), cfg.AWSRegion, cfg.DBUser, awsCfg.Credentials)
		if err != nil {
			return nil, err
		}
		pwd = token
	}
	dsn := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=verify-full",
		cfg.DBHost, cfg.DBPort, cfg.DBUser, pwd, cfg.DBName)
	pcfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	pcfg.MaxConns = 5
	return pgxpool.NewWithConfig(ctx, pcfg)
}

// guard so strconv stays imported even if unused after refactors
var _ = strconv.Itoa
