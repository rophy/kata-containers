FROM golang:1.25 AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /kata-block-volume-webhook .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /kata-block-volume-webhook /
ENTRYPOINT ["/kata-block-volume-webhook"]
