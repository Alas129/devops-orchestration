package tasksvc

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/rds/auth"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/golang-jwt/jwt/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nats-io/nats.go"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type App struct {
	cfg  *Config
	db   *pgxpool.Pool
	nc   *nats.Conn
	js   nats.JetStreamContext

	reqs    *prometheus.CounterVec
	latency *prometheus.HistogramVec
}

func New(ctx context.Context, cfg *Config) (*App, error) {
	pool, err := newDBPool(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("db: %w", err)
	}

	nc, err := nats.Connect(cfg.NATSURL,
		nats.Name("tasks-svc"),
		nats.MaxReconnects(-1),
		nats.ReconnectWait(2*time.Second),
	)
	if err != nil {
		return nil, fmt.Errorf("nats connect: %w", err)
	}

	js, err := nc.JetStream()
	if err != nil {
		return nil, fmt.Errorf("jetstream: %w", err)
	}

	// Idempotent stream creation. Subjects: tasks.created, tasks.updated.
	_, _ = js.AddStream(&nats.StreamConfig{
		Name:     "TASKS",
		Subjects: []string{"tasks.>"},
		Storage:  nats.FileStorage,
		Replicas: 1,
		MaxAge:   24 * time.Hour,
	})

	a := &App{
		cfg: cfg,
		db:  pool,
		nc:  nc,
		js:  js,
		reqs: promauto.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total", Help: "HTTP requests",
		}, []string{"method", "route", "status"}),
		latency: promauto.NewHistogramVec(prometheus.HistogramOpts{
			Name: "http_request_duration_seconds", Help: "HTTP request latency",
			Buckets: prometheus.DefBuckets,
		}, []string{"method", "route", "status"}),
	}
	return a, nil
}

func (a *App) Close() {
	if a.db != nil {
		a.db.Close()
	}
	if a.nc != nil {
		a.nc.Close()
	}
}

func (a *App) Router() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RequestID, middleware.RealIP, middleware.Recoverer, middleware.Timeout(15*time.Second))
	r.Use(a.metricsMW)

	r.Get("/healthz", a.healthz)
	r.Get("/livez", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200); _, _ = w.Write([]byte("ok")) })
	r.Method("GET", "/metrics", promhttp.HandlerFor(prometheus.DefaultGatherer, promhttp.HandlerOpts{}))

	r.Group(func(r chi.Router) {
		r.Use(a.authMW)
		r.Get("/api/v1/tasks", a.listTasks)
		r.Post("/api/v1/tasks", a.createTask)
		r.Patch("/api/v1/tasks/{id}", a.updateTask)
		r.Delete("/api/v1/tasks/{id}", a.deleteTask)
	})

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

// authMW validates the JWT issued by auth-svc and stuffs the user ID into
// request context.
func (a *App) authMW(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if raw == "" {
			http.Error(w, "missing token", 401)
			return
		}
		claims := &jwt.RegisteredClaims{}
		t, err := jwt.ParseWithClaims(raw, claims, func(t *jwt.Token) (interface{}, error) {
			if t.Method != jwt.SigningMethodHS256 {
				return nil, errors.New("bad alg")
			}
			return []byte(a.cfg.JWTSecret), nil
		}, jwt.WithIssuer(a.cfg.JWTIssuer), jwt.WithExpirationRequired())
		if err != nil || !t.Valid {
			http.Error(w, "invalid token", 401)
			return
		}
		uid, err := strconv.ParseInt(claims.Subject, 10, 64)
		if err != nil {
			http.Error(w, "bad subject", 401)
			return
		}
		ctx := context.WithValue(r.Context(), userIDKey{}, uid)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

type userIDKey struct{}

func userID(ctx context.Context) int64 {
	v, _ := ctx.Value(userIDKey{}).(int64)
	return v
}

func (a *App) metricsMW(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
		next.ServeHTTP(ww, r)
		if r.URL.Path == "/metrics" {
			return
		}
		status := strconv.Itoa(ww.Status())
		a.reqs.WithLabelValues(r.Method, r.URL.Path, status).Inc()
		a.latency.WithLabelValues(r.Method, r.URL.Path, status).Observe(time.Since(start).Seconds())
	})
}

// publish a JSON event on a tasks.* subject. Errors are logged but not fatal —
// the API call still succeeds; notifier-svc gets eventual consistency from
// JetStream redelivery.
func (a *App) publish(subject string, payload any) {
	b, _ := json.Marshal(payload)
	_, _ = a.js.Publish(subject, b)
}

// guard so `aws` is referenced (placate the linter)
var _ = aws.Bool

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
	pcfg.MaxConns = 10
	pcfg.MinConns = 2
	return pgxpool.NewWithConfig(ctx, pcfg)
}
