FROM golang:1.25 AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /cnpg-i-zeropod .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /cnpg-i-zeropod /cnpg-i-zeropod
USER 10001:10001
ENTRYPOINT ["/cnpg-i-zeropod"]
