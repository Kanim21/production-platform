package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

var (
	httpRequestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "Total HTTP requests by method, path, and status.",
	}, []string{"method", "path", "status"})

	httpRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request latency by method and path.",
		Buckets: []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5},
	}, []string{"method", "path"})

	dbQueryDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "db_query_duration_seconds",
		Help:    "Database query latency by operation.",
		Buckets: []float64{.001, .005, .01, .025, .05, .1, .25, .5, 1},
	}, []string{"operation"})
)

type dbCredentials struct {
	Host     string `json:"host"`
	Port     int    `json:"port"`
	DBName   string `json:"dbname"`
	Username string `json:"username"`
	Password string `json:"password"`
}

type Product struct {
	ID          int64   `json:"id"`
	Name        string  `json:"name"`
	Description string  `json:"description"`
	PriceCents  int64   `json:"price_cents"`
	Stock       int     `json:"stock"`
	CreatedAt   string  `json:"created_at"`
}

type server struct {
	db     *pgxpool.Pool
	logger zerolog.Logger
}

func main() {
	zerolog.TimeFieldFormat = zerolog.TimeFormatUnix
	logger := log.With().Str("service", "api").Logger()

	ctx := context.Background()

	pool, err := connectDB(ctx, logger)
	if err != nil {
		logger.Fatal().Err(err).Msg("failed to connect to database")
	}
	defer pool.Close()

	s := &server{db: pool, logger: logger}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /health/ready", s.handleReadiness)
	mux.HandleFunc("GET /api/v1/products", s.handleListProducts)
	mux.HandleFunc("GET /api/v1/products/{id}", s.handleGetProduct)
	mux.HandleFunc("POST /api/v1/orders", s.handleCreateOrder)
	mux.Handle("GET /metrics", promhttp.Handler())

	srv := &http.Server{
		Addr:         ":8080",
		Handler:      withMetrics(mux),
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		logger.Info().Str("addr", srv.Addr).Msg("server starting")
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Fatal().Err(err).Msg("server failed")
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	logger.Info().Msg("shutdown signal received")
	shutdownCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error().Err(err).Msg("graceful shutdown failed")
	}
	logger.Info().Msg("server stopped")
}

func connectDB(ctx context.Context, logger zerolog.Logger) (*pgxpool.Pool, error) {
	secretARN := os.Getenv("DB_SECRET_ARN")

	var connStr string
	if secretARN != "" {
		creds, err := fetchDBCredentials(ctx, secretARN)
		if err != nil {
			return nil, fmt.Errorf("fetch credentials: %w", err)
		}
		connStr = fmt.Sprintf("host=%s port=%d dbname=%s user=%s password=%s sslmode=require",
			creds.Host, creds.Port, creds.DBName, creds.Username, creds.Password)
	} else {
		connStr = os.Getenv("DATABASE_URL")
		if connStr == "" {
			return nil, fmt.Errorf("DATABASE_URL or DB_SECRET_ARN must be set")
		}
	}

	cfg, err := pgxpool.ParseConfig(connStr)
	if err != nil {
		return nil, fmt.Errorf("parse db config: %w", err)
	}

	cfg.MaxConns = 20
	cfg.MinConns = 2
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("create pool: %w", err)
	}

	if err := pool.Ping(ctx); err != nil {
		return nil, fmt.Errorf("ping database: %w", err)
	}

	logger.Info().Str("host", cfg.ConnConfig.Host).Msg("database connected")
	return pool, nil
}

func fetchDBCredentials(ctx context.Context, secretARN string) (*dbCredentials, error) {
	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("load aws config: %w", err)
	}

	client := secretsmanager.NewFromConfig(cfg)
	result, err := client.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{
		SecretId: &secretARN,
	})
	if err != nil {
		return nil, fmt.Errorf("get secret: %w", err)
	}

	var creds dbCredentials
	if err := json.Unmarshal([]byte(*result.SecretString), &creds); err != nil {
		return nil, fmt.Errorf("unmarshal credentials: %w", err)
	}
	return &creds, nil
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status":"ok"}`))
}

func (s *server) handleReadiness(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()

	if err := s.db.Ping(ctx); err != nil {
		s.logger.Error().Err(err).Msg("readiness check failed: database unreachable")
		http.Error(w, `{"status":"not ready","error":"database unreachable"}`, http.StatusServiceUnavailable)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status":"ready"}`))
}

func (s *server) handleListProducts(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	timer := prometheus.NewTimer(dbQueryDuration.WithLabelValues("list_products"))
	defer timer.ObserveDuration()

	rows, err := s.db.Query(ctx,
		`SELECT id, name, description, price_cents, stock, created_at
		 FROM products
		 WHERE stock > 0
		 ORDER BY created_at DESC
		 LIMIT 50`,
	)
	if err != nil {
		s.logger.Error().Err(err).Msg("list products query failed")
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	products := make([]Product, 0, 50)
	for rows.Next() {
		var p Product
		if err := rows.Scan(&p.ID, &p.Name, &p.Description, &p.PriceCents, &p.Stock, &p.CreatedAt); err != nil {
			s.logger.Error().Err(err).Msg("scan product row failed")
			continue
		}
		products = append(products, p)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"products": products, "count": len(products)})
}

func (s *server) handleGetProduct(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := r.PathValue("id")

	timer := prometheus.NewTimer(dbQueryDuration.WithLabelValues("get_product"))
	defer timer.ObserveDuration()

	var p Product
	err := s.db.QueryRow(ctx,
		`SELECT id, name, description, price_cents, stock, created_at FROM products WHERE id = $1`,
		id,
	).Scan(&p.ID, &p.Name, &p.Description, &p.PriceCents, &p.Stock, &p.CreatedAt)
	if err != nil {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(p)
}

type createOrderRequest struct {
	ProductID int64 `json:"product_id"`
	Quantity  int   `json:"quantity"`
	UserID    int64 `json:"user_id"`
}

func (s *server) handleCreateOrder(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	var req createOrderRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
		return
	}

	if req.ProductID == 0 || req.Quantity <= 0 || req.UserID == 0 {
		http.Error(w, `{"error":"product_id, quantity, and user_id are required"}`, http.StatusBadRequest)
		return
	}

	timer := prometheus.NewTimer(dbQueryDuration.WithLabelValues("create_order"))
	defer timer.ObserveDuration()

	tx, err := s.db.Begin(ctx)
	if err != nil {
		s.logger.Error().Err(err).Msg("begin transaction failed")
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}
	defer tx.Rollback(ctx)

	var stock int
	err = tx.QueryRow(ctx,
		`SELECT stock FROM products WHERE id = $1 FOR UPDATE`,
		req.ProductID,
	).Scan(&stock)
	if err != nil {
		http.Error(w, `{"error":"product not found"}`, http.StatusNotFound)
		return
	}

	if stock < req.Quantity {
		http.Error(w, `{"error":"insufficient stock"}`, http.StatusConflict)
		return
	}

	_, err = tx.Exec(ctx,
		`UPDATE products SET stock = stock - $1 WHERE id = $2`,
		req.Quantity, req.ProductID,
	)
	if err != nil {
		s.logger.Error().Err(err).Msg("update stock failed")
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}

	var orderID int64
	err = tx.QueryRow(ctx,
		`INSERT INTO orders (user_id, product_id, quantity, status, created_at)
		 VALUES ($1, $2, $3, 'pending', NOW())
		 RETURNING id`,
		req.UserID, req.ProductID, req.Quantity,
	).Scan(&orderID)
	if err != nil {
		s.logger.Error().Err(err).Msg("insert order failed")
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}

	if err := tx.Commit(ctx); err != nil {
		s.logger.Error().Err(err).Msg("commit transaction failed")
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}

	s.logger.Info().
		Int64("order_id", orderID).
		Int64("user_id", req.UserID).
		Int64("product_id", req.ProductID).
		Int("quantity", req.Quantity).
		Msg("order created")

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]any{"order_id": orderID, "status": "pending"})
}

func withMetrics(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/metrics" || r.URL.Path == "/health" {
			next.ServeHTTP(w, r)
			return
		}

		rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}
		start := time.Now()
		next.ServeHTTP(rw, r)
		duration := time.Since(start).Seconds()

		status := fmt.Sprintf("%d", rw.statusCode)
		httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, status).Inc()
		httpRequestDuration.WithLabelValues(r.Method, r.URL.Path).Observe(duration)
	})
}

type responseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}
