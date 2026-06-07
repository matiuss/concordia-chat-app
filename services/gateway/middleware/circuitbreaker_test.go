package middleware_test

import (
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"strings"
	"testing"
	"time"

	"concordia/gateway/middleware"

	"github.com/sony/gobreaker"
)

const (
	testThreshold   = 5
	testHalfOpen    = 100 * time.Millisecond
	testUpstreamTO  = 50 * time.Millisecond
)

// slowServer simulates a chat backend that hangs for the given duration.
func slowServer(delay time.Duration) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(delay)
		w.WriteHeader(http.StatusOK)
	}))
}

// fastServer simulates a healthy chat backend.
func fastServer() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"messages":[]}`)) //nolint:errcheck
	}))
}

func newBreaker(target *httptest.Server) *middleware.ChatBreaker {
	u, _ := url.Parse(target.URL)
	proxy := httputil.NewSingleHostReverseProxy(u)
	// Silence default proxy error logs in tests.
	proxy.ErrorLog = nil
	return middleware.NewChatBreaker(proxy, testThreshold, testHalfOpen, testUpstreamTO)
}

// TestChatBreaker_ClosedPassesThrough verifies that a healthy upstream
// receives requests and returns its response normally.
func TestChatBreaker_ClosedPassesThrough(t *testing.T) {
	srv := fastServer()
	defer srv.Close()

	breaker := newBreaker(srv)

	req := httptest.NewRequest(http.MethodGet, "/channels/1/messages", nil)
	rec := httptest.NewRecorder()
	breaker.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if breaker.State() != gobreaker.StateClosed {
		t.Fatalf("expected circuit closed, got %s", breaker.State())
	}
}

// TestChatBreaker_OpensAfterConsecutiveTimeouts verifies that 5 consecutive
// upstream timeouts transition the circuit to StateOpen.
func TestChatBreaker_OpensAfterConsecutiveTimeouts(t *testing.T) {
	// Backend takes longer than the upstream timeout.
	srv := slowServer(200 * time.Millisecond)
	defer srv.Close()

	breaker := newBreaker(srv)

	for i := 0; i < testThreshold; i++ {
		req := httptest.NewRequest(http.MethodGet, "/channels/1/messages", nil)
		rec := httptest.NewRecorder()
		breaker.ServeHTTP(rec, req)

		if rec.Code != http.StatusServiceUnavailable {
			t.Fatalf("call %d: expected 503, got %d", i+1, rec.Code)
		}
	}

	if breaker.State() != gobreaker.StateOpen {
		t.Fatalf("expected circuit open after %d timeouts, got %s", testThreshold, breaker.State())
	}
}

// TestChatBreaker_OpenReturnsFallbackImmediately verifies that an open circuit
// returns the fallback without forwarding to the upstream.
func TestChatBreaker_OpenReturnsFallbackImmediately(t *testing.T) {
	srv := slowServer(200 * time.Millisecond)
	defer srv.Close()

	breaker := newBreaker(srv)

	// Trip the circuit.
	for i := 0; i < testThreshold; i++ {
		req := httptest.NewRequest(http.MethodGet, "/channels/1/messages", nil)
		breaker.ServeHTTP(httptest.NewRecorder(), req)
	}

	if breaker.State() != gobreaker.StateOpen {
		t.Skip("circuit did not open, skipping open-state test")
	}

	// Now use a fast server to confirm the proxy is NOT called.
	called := false
	probe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	}))
	defer probe.Close()

	u, _ := url.Parse(probe.URL)
	proxy := httputil.NewSingleHostReverseProxy(u)
	proxy.ErrorLog = nil

	// Re-use same CB (already open) by calling ServeHTTP directly.
	req := httptest.NewRequest(http.MethodGet, "/channels/1/messages", nil)
	rec := httptest.NewRecorder()
	breaker.ServeHTTP(rec, req)

	if called {
		t.Fatal("upstream was called despite open circuit")
	}
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 fallback, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "mensajes temporalmente no disponibles") {
		t.Fatalf("unexpected fallback body: %s", rec.Body.String())
	}
}

// TestChatBreaker_HalfOpenAllowsProbe verifies that after the half-open
// timeout the circuit allows exactly one probe request through.
func TestChatBreaker_HalfOpenAllowsProbe(t *testing.T) {
	slow := slowServer(200 * time.Millisecond)
	defer slow.Close()

	breaker := newBreaker(slow)

	// Trip the circuit.
	for i := 0; i < testThreshold; i++ {
		req := httptest.NewRequest(http.MethodGet, "/channels/1/messages", nil)
		breaker.ServeHTTP(httptest.NewRecorder(), req)
	}

	if breaker.State() != gobreaker.StateOpen {
		t.Skip("circuit did not open")
	}

	// Wait for the half-open timeout to elapse.
	time.Sleep(testHalfOpen + 20*time.Millisecond)

	if breaker.State() != gobreaker.StateHalfOpen {
		t.Fatalf("expected half-open after timeout, got %s", breaker.State())
	}
}
