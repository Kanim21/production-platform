FROM golang:1.22-alpine AS builder

WORKDIR /src

# Cache dependency layer separately from source
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION:-dev}" \
    -o /out/api .

# ── Final image ───────────────────────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /out/api /api

EXPOSE 8080

ENTRYPOINT ["/api"]
