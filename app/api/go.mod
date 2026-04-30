module github.com/your-org/production-platform/api

go 1.22

require (
	github.com/aws/aws-sdk-go-v2 v1.26.0
	github.com/aws/aws-sdk-go-v2/config v1.27.7
	github.com/aws/aws-sdk-go-v2/service/secretsmanager v1.28.5
	github.com/jackc/pgx/v5 v5.5.5
	github.com/prometheus/client_golang v1.19.0
	github.com/rs/zerolog v1.32.0
	go.opentelemetry.io/otel v1.24.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp v1.24.0
	go.opentelemetry.io/otel/sdk v1.24.0
)
