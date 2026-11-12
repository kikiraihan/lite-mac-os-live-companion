# Temani — satu image: SPA Vue + server Go (API, worker generate).
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
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/temani ./cmd/server

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata \
 && addgroup -S temani && adduser -S -G temani -h /app temani
WORKDIR /app
COPY --from=api /out/temani /usr/local/bin/temani
COPY --from=web /web/dist /app/web/dist
ENV APP_ADDR=:8080 WEB_DIR=/app/web/dist APP_ENV=production
USER temani
EXPOSE 8080
CMD ["temani", "serve"]
