# Temu — satu image: SPA Vue + server Go (API, worker generate).
# Tahap 1: build web. Tahap 2: build binary Go. Tahap 3: runtime minimal (non-root).

FROM node:22-alpine AS web
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/ ./
RUN npm run build

FROM golang:1.24-alpine AS api
WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/temu ./cmd/server

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata \
 && addgroup -S temu && adduser -S -G temu -h /app temu
WORKDIR /app
COPY --from=api /out/temu /usr/local/bin/temu
COPY --from=web /web/dist /app/web/dist
ENV APP_ADDR=:8080 WEB_DIR=/app/web/dist APP_ENV=production
USER temu
EXPOSE 8080
CMD ["temu", "serve"]
