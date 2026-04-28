package authsvc

import (
	"context"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type App struct {
	cfg     *Config
	db      *pgxpool.Pool
	metrics *metrics
	store   *Store
	tokens  *Tokens
}

func New(ctx context.Context, cfg *Config) (*App, error) {
	pool, err := newDBPool(ctx, cfg)
	if err != nil {
		return nil, err
	}

	m := newMetrics()

	a := &App{
		cfg:     cfg,
		db:      pool,
		metrics: m,
		store:   &Store{Pool: pool},
		tokens:  &Tokens{Secret: []byte(cfg.JWTSecret), Issuer: cfg.JWTIssuer, TTL: cfg.JWTTTL},
	}
	return a, nil
}

func (a *App) Close() {
	if a.db != nil {
		a.db.Close()
	}
}

func (a *App) Router() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(middleware.Recoverer)
	r.Use(middleware.Timeout(15 * time.Second))
	r.Use(a.metrics.middleware)

	r.Get("/healthz", a.healthz)
	r.Get("/livez", a.livez)
	r.Method("GET", "/metrics", promhttp.HandlerFor(prometheus.DefaultGatherer, promhttp.HandlerOpts{}))

	r.Post("/api/v1/signup", a.signup)
	r.Post("/api/v1/login", a.login)
	r.Get("/api/v1/me", a.me)

	return r
}
