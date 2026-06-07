package middleware

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"time"

	"github.com/sony/gobreaker"
)

// chatFallback is returned to clients when the circuit is open.
var chatFallback = map[string]string{"error": "mensajes temporalmente no disponibles"}

// ChatBreaker wraps a ReverseProxy with a circuit breaker that trips after
// consecutiveFailures consecutive upstream timeouts and recovers after halfOpen.
type ChatBreaker struct {
	proxy           *httputil.ReverseProxy
	cb              *gobreaker.CircuitBreaker
	upstreamTimeout time.Duration
}

func NewChatBreaker(
	proxy *httputil.ReverseProxy,
	consecutiveFailures uint32,
	halfOpen time.Duration,
	upstreamTimeout time.Duration,
) *ChatBreaker {
	settings := gobreaker.Settings{
		Name:        "chat",
		MaxRequests: 1, // one probe request in half-open state
		Timeout:     halfOpen,
		ReadyToTrip: func(counts gobreaker.Counts) bool {
			return counts.ConsecutiveFailures >= consecutiveFailures
		},
		OnStateChange: func(name string, from, to gobreaker.State) {
			log.Printf("circuit breaker %q: %s → %s", name, from, to)
		},
	}
	return &ChatBreaker{
		proxy:           proxy,
		cb:              gobreaker.NewCircuitBreaker(settings),
		upstreamTimeout: upstreamTimeout,
	}
}

func (h *ChatBreaker) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Fast path: circuit open — skip the proxy entirely.
	if h.cb.State() == gobreaker.StateOpen {
		writeFallback(w)
		return
	}

	_, err := h.cb.Execute(func() (interface{}, error) {
		ctx, cancel := context.WithTimeout(r.Context(), h.upstreamTimeout)
		defer cancel()

		rec := httptest.NewRecorder()
		h.proxy.ServeHTTP(rec, r.WithContext(ctx))

		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, context.DeadlineExceeded
		}

		// Forward the buffered response to the real writer.
		for k, v := range rec.Result().Header {
			w.Header()[k] = v
		}
		w.WriteHeader(rec.Code)
		rec.Body.WriteTo(w) //nolint:errcheck
		return nil, nil
	})

	if err != nil {
		writeFallback(w)
	}
}

// State exposes the current breaker state for testing and observability.
func (h *ChatBreaker) State() gobreaker.State {
	return h.cb.State()
}

func writeFallback(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusServiceUnavailable)
	json.NewEncoder(w).Encode(chatFallback) //nolint:errcheck
}
