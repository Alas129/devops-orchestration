package authsvc

import (
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5/middleware"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

type metrics struct {
	reqs    *prometheus.CounterVec
	latency *prometheus.HistogramVec
}

func newMetrics() *metrics {
	return &metrics{
		reqs: promauto.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "HTTP requests",
		}, []string{"method", "route", "status"}),
		latency: promauto.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request latency",
			Buckets: prometheus.DefBuckets,
		}, []string{"method", "route", "status"}),
	}
}

func (m *metrics) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
		next.ServeHTTP(ww, r)
		status := strconv.Itoa(ww.Status())
		route := r.URL.Path
		// Don't include /metrics in metrics — avoid recursion blowup.
		if route == "/metrics" {
			return
		}
		m.reqs.WithLabelValues(r.Method, route, status).Inc()
		m.latency.WithLabelValues(r.Method, route, status).Observe(time.Since(start).Seconds())
	})
}
