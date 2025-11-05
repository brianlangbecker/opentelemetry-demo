# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0


FROM golang:1.24-bookworm AS builder

WORKDIR /usr/src/app/

COPY ./src/product-catalog/go.mod go.mod
COPY ./src/product-catalog/go.sum go.sum

RUN go mod download

COPY ./src/product-catalog/genproto/oteldemo/ genproto/oteldemo/
COPY ./src/product-catalog/products/ products/
COPY ./src/product-catalog/main.go main.go

RUN CGO_ENABLED=0 GOOS=linux GO111MODULE=on go build -ldflags "-s -w" -o product-catalog main.go && chmod +x product-catalog

# Temporarily use alpine for debugging - will switch back to distroless once working
FROM alpine:latest

WORKDIR /usr/src/app/

# Copy binary and products
COPY --from=builder /usr/src/app/product-catalog ./
COPY --from=builder /usr/src/app/products/ ./products/

# Copy wrapper script
COPY src/product-catalog/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Add ca-certificates for HTTPS connections (needed for OTLP gRPC)
RUN apk add --no-cache ca-certificates

EXPOSE ${PRODUCT_CATALOG_PORT}
ENTRYPOINT [ "/docker-entrypoint.sh" ]
