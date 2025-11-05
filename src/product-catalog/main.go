// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0
package main

//go:generate go install google.golang.org/protobuf/cmd/protoc-gen-go
//go:generate go install google.golang.org/grpc/cmd/protoc-gen-go-grpc
//go:generate protoc --go_out=./ --go-grpc_out=./ --proto_path=../../pb ../../pb/demo.proto

import (
	"context"
	"database/sql"
	"fmt"
	"io/fs"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/XSAM/otelsql"
	"github.com/lib/pq"   // For pq.StringArray type
	_ "github.com/lib/pq" // Register postgres driver
	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.opentelemetry.io/contrib/instrumentation/runtime"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	otelcodes "go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/log/global"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	sdkresource "go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"go.opentelemetry.io/otel/trace"

	otelhooks "github.com/open-feature/go-sdk-contrib/hooks/open-telemetry/pkg"
	flagd "github.com/open-feature/go-sdk-contrib/providers/flagd/pkg"
	"github.com/open-feature/go-sdk/openfeature"
	pb "github.com/opentelemetry/opentelemetry-demo/src/product-catalog/genproto/oteldemo"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"
)

var (
	logger            *slog.Logger
	catalog           []*pb.Product
	db                *sql.DB
	useDatabase       bool
	resource          *sdkresource.Resource
	initResourcesOnce sync.Once
)

const DEFAULT_RELOAD_INTERVAL = 10

func init() {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "[INIT] PANIC in init(): %v\n", r)
			debug.PrintStack()
			os.Exit(1)
		}
	}()
	// Use standard logger initially - will be replaced with OTel logger in main()
	fmt.Fprintf(os.Stderr, "[INIT] Starting initialization...\n")
	logger = slog.Default()
	fmt.Fprintf(os.Stderr, "[INIT] Default logger created\n")
	// Don't load products in init() - do it in main() with proper error handling
	// This prevents crashes if the products directory has issues
	fmt.Fprintf(os.Stderr, "[INIT] Initialization complete - products will load in main()\n")
}

func initResource() *sdkresource.Resource {
	initResourcesOnce.Do(func() {
		extraResources, _ := sdkresource.New(
			context.Background(),
			sdkresource.WithOS(),
			sdkresource.WithProcess(),
			sdkresource.WithContainer(),
			sdkresource.WithHost(),
		)
		resource, _ = sdkresource.Merge(
			sdkresource.Default(),
			extraResources,
		)
	})
	return resource
}

func initTracerProvider() *sdktrace.TracerProvider {
	ctx := context.Background()

	exporter, err := otlptracegrpc.New(ctx)
	if err != nil {
		logger.Error(fmt.Sprintf("OTLP Trace gRPC Creation: %v", err))

	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(initResource()),
	)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))
	return tp
}

func initMeterProvider() *sdkmetric.MeterProvider {
	ctx := context.Background()

	exporter, err := otlpmetricgrpc.New(ctx)
	if err != nil {
		logger.Error(fmt.Sprintf("new otlp metric grpc exporter failed: %v", err))
	}

	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(exporter)),
		sdkmetric.WithResource(initResource()),
	)
	otel.SetMeterProvider(mp)
	return mp
}

func initLoggerProvider() *sdklog.LoggerProvider {
	ctx := context.Background()

	logExporter, err := otlploggrpc.New(ctx)
	if err != nil {
		return nil
	}

	loggerProvider := sdklog.NewLoggerProvider(
		sdklog.WithProcessor(sdklog.NewBatchProcessor(logExporter)),
	)
	global.SetLoggerProvider(loggerProvider)

	return loggerProvider
}

func initDatabase() (*sql.DB, error) {
	fmt.Fprintf(os.Stderr, "[DB] initDatabase() called\n")
	// Check if database usage is enabled
	useDatabaseEnv := os.Getenv("USE_DATABASE")
	fmt.Fprintf(os.Stderr, "[DB] USE_DATABASE=%s\n", useDatabaseEnv)
	useDatabase = useDatabaseEnv == "true" || useDatabaseEnv == "1"

	if !useDatabase {
		fmt.Fprintf(os.Stderr, "[DB] Database mode disabled, using JSON file catalog\n")
		logger.Info("Database mode disabled, using JSON file catalog")
		return nil, nil
	}

	connStr := os.Getenv("DB_CONNECTION_STRING")
	if connStr == "" {
		fmt.Fprintf(os.Stderr, "[DB] WARNING: DB_CONNECTION_STRING not set, falling back to JSON file catalog\n")
		logger.Warn("DB_CONNECTION_STRING not set, falling back to JSON file catalog")
		useDatabase = false
		return nil, nil
	}

	fmt.Fprintf(os.Stderr, "[DB] Initializing database connection for product catalog\n")
	fmt.Fprintf(os.Stderr, "[DB] Connection string: %s\n", connStr)
	logger.Info("Initializing database connection for product catalog")

	// Open database connection with instrumentation
	fmt.Fprintf(os.Stderr, "[DB] About to call otelsql.Open()\n")
	database, err := otelsql.Open("postgres", connStr,
		otelsql.WithAttributes(semconv.DBSystemPostgreSQL),
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[DB] ERROR: Failed to open database: %v\n", err)
		return nil, fmt.Errorf("failed to open database: %w", err)
	}
	fmt.Fprintf(os.Stderr, "[DB] Database opened successfully\n")

	// Register stats for monitoring
	fmt.Fprintf(os.Stderr, "[DB] About to register DB stats metrics\n")
	if err := otelsql.RegisterDBStatsMetrics(database, otelsql.WithAttributes(
		semconv.DBSystemPostgreSQL,
	)); err != nil {
		fmt.Fprintf(os.Stderr, "[DB] WARNING: Failed to register DB stats metrics: %v\n", err)
		logger.Warn(fmt.Sprintf("Failed to register DB stats metrics: %v", err))
	}
	fmt.Fprintf(os.Stderr, "[DB] DB stats metrics registered\n")

	// Configure connection pool
	fmt.Fprintf(os.Stderr, "[DB] Configuring connection pool\n")
	database.SetMaxOpenConns(25)
	database.SetMaxIdleConns(5)
	database.SetConnMaxLifetime(5 * time.Minute)
	fmt.Fprintf(os.Stderr, "[DB] Connection pool configured\n")

	// Test the connection
	fmt.Fprintf(os.Stderr, "[DB] About to ping database\n")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := database.PingContext(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "[DB] ERROR: Failed to ping database: %v\n", err)
		return nil, fmt.Errorf("failed to ping database: %w", err)
	}
	fmt.Fprintf(os.Stderr, "[DB] Database ping successful\n")

	logger.Info("Database connection established successfully")
	return database, nil
}

func main() {
	// IMMEDIATE TEST - Write to both stdout and stderr and flush
	fmt.Println("STDOUT: Starting product-catalog")
	fmt.Fprintf(os.Stderr, "STDERR: Starting product-catalog\n")
	os.Stderr.WriteString("RAW STDERR: Starting product-catalog\n")
	os.Stderr.Sync()
	os.Stdout.Sync()

	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "PANIC RECOVERED: %v\n", r)
			os.Stderr.Sync()
			// Print stack trace if available
			fmt.Fprintf(os.Stderr, "Stack trace:\n")
			debug.PrintStack()
			os.Stderr.Sync()
			os.Exit(1)
		}
	}()

	// Write initial message to stderr in case logging isn't ready
	fmt.Fprintf(os.Stderr, "[DEBUG] Starting product-catalog service...\n")
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 1: About to initialize logger provider\n")

	lp := initLoggerProvider()
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 2: Logger provider initialized\n")
	defer func() {
		fmt.Fprintf(os.Stderr, "[DEBUG] Shutting down logger provider\n")
		if err := lp.Shutdown(context.Background()); err != nil {
			logger.Error(fmt.Sprintf("Logger Provider Shutdown: %v", err))
		}
		logger.Info("Shutdown logger provider")
	}()

	// Replace standard logger with OTel logger now that OTel is initialized
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 3: Creating OTel logger\n")
	logger = otelslog.NewLogger("product-catalog")
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 4: OTel logger created\n")
	logger.Info("Logger initialized successfully")

	// Load product catalog now (moved from init() to avoid crashes)
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 4.5: Loading product catalog\n")
	loadProductCatalog()
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 4.5: Product catalog loaded\n")

	fmt.Fprintf(os.Stderr, "[DEBUG] Step 5: About to initialize tracer provider\n")
	tp := initTracerProvider()
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 6: Tracer provider initialized\n")
	logger.Info("Tracer provider initialized")
	defer func() {
		fmt.Fprintf(os.Stderr, "[DEBUG] Shutting down tracer provider\n")
		if err := tp.Shutdown(context.Background()); err != nil {
			logger.Error(fmt.Sprintf("Tracer Provider Shutdown: %v", err))
		}
		logger.Info("Shutdown tracer provider")
	}()

	// Create a span for the initialization process
	ctx := context.Background()
	tracer := otel.Tracer("product-catalog")
	initCtx, initSpan := tracer.Start(ctx, "product-catalog.init")
	defer initSpan.End()
	initSpan.SetAttributes(attribute.String("service.name", "product-catalog"))

	fmt.Fprintf(os.Stderr, "[DEBUG] Step 7: About to initialize meter provider\n")
	mp := initMeterProvider()
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 8: Meter provider initialized\n")
	logger.Info("Meter provider initialized")
	defer func() {
		fmt.Fprintf(os.Stderr, "[DEBUG] Shutting down meter provider\n")
		if err := mp.Shutdown(context.Background()); err != nil {
			logger.Error(fmt.Sprintf("Error shutting down meter provider: %v", err))
		}
		logger.Info("Shutdown meter provider")
	}()

	fmt.Fprintf(os.Stderr, "[DEBUG] Step 9: OpenTelemetry providers initialized\n")
	initSpan.AddEvent("OpenTelemetry providers initialized")
	logger.Info("All OpenTelemetry providers initialized")

	// Initialize database connection
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 10: About to initialize database connection\n")
	_, dbSpan := tracer.Start(initCtx, "product-catalog.init.database")
	defer dbSpan.End()

	var err error
	db, err = initDatabase()
	if err != nil {
		// Log error and fall back to JSON file catalog instead of exiting
		fmt.Fprintf(os.Stderr, "[DEBUG] Step 10 FAILED: Database initialization failed: %v. Falling back to JSON.\n", err)
		dbSpan.SetStatus(otelcodes.Error, err.Error())
		dbSpan.RecordError(err)
		logger.Error(fmt.Sprintf("Failed to initialize database: %v. Falling back to JSON file catalog.", err))
		useDatabase = false
		// Don't exit - allow service to start with JSON fallback
	} else if db != nil {
		fmt.Fprintf(os.Stderr, "[DEBUG] Step 10 SUCCESS: Database connection successful\n")
		dbSpan.SetAttributes(attribute.String("db.connection.status", "success"))
		dbSpan.AddEvent("Database connection established")
		logger.Info("Database connection established successfully")
		defer func() {
			if err := db.Close(); err != nil {
				logger.Error(fmt.Sprintf("Error closing database: %v", err))
			}
			logger.Info("Database connection closed")
		}()
	} else {
		fmt.Fprintf(os.Stderr, "[DEBUG] Step 10 SKIPPED: Database disabled, using JSON catalog\n")
		dbSpan.SetAttributes(attribute.String("db.connection.status", "disabled"))
		logger.Info("Database disabled, using JSON file catalog")
	}

	fmt.Fprintf(os.Stderr, "[DEBUG] Step 11: About to initialize OpenFeature\n")
	_, featureSpan := tracer.Start(initCtx, "product-catalog.init.feature-flags")
	openfeature.AddHooks(otelhooks.NewTracesHook())
	provider, err := flagd.NewProvider()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[DEBUG] Step 11 WARNING: Flagd provider creation failed: %v\n", err)
		featureSpan.RecordError(err)
		logger.Error(err.Error())
	} else {
		fmt.Fprintf(os.Stderr, "[DEBUG] Step 11: Flagd provider created\n")
	}
	err = openfeature.SetProvider(provider)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[DEBUG] Step 11 WARNING: SetProvider failed: %v\n", err)
		featureSpan.RecordError(err)
		logger.Error(err.Error())
	} else {
		fmt.Fprintf(os.Stderr, "[DEBUG] Step 11: Feature flags provider set\n")
	}
	featureSpan.End()
	logger.Info("Feature flags initialized")

	fmt.Fprintf(os.Stderr, "[DEBUG] Step 12: About to start runtime instrumentation\n")
	_, runtimeSpan := tracer.Start(initCtx, "product-catalog.init.runtime")
	err = runtime.Start(runtime.WithMinimumReadMemStatsInterval(time.Second))
	if err != nil {
		fmt.Fprintf(os.Stderr, "[DEBUG] Step 12 WARNING: Runtime instrumentation failed: %v\n", err)
		runtimeSpan.RecordError(err)
		logger.Error(err.Error())
	} else {
		fmt.Fprintf(os.Stderr, "[DEBUG] Step 12: Runtime instrumentation started\n")
		runtimeSpan.SetAttributes(attribute.String("runtime.status", "started"))
	}
	runtimeSpan.End()
	logger.Info("Runtime instrumentation started")

	fmt.Fprintf(os.Stderr, "[DEBUG] Step 13: About to create service instance\n")
	svc := &productCatalog{}

	fmt.Fprintf(os.Stderr, "[DEBUG] Step 14: About to get PRODUCT_CATALOG_PORT\n")
	var port string
	mustMapEnv(&port, "PRODUCT_CATALOG_PORT")
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 14: PORT=%s\n", port)
	logger.Info(fmt.Sprintf("Product Catalog gRPC server starting on port: %s", port))

	fmt.Fprintf(os.Stderr, "[DEBUG] Step 15: About to listen on TCP port %s\n", port)
	ln, err := net.Listen("tcp", fmt.Sprintf(":%s", port))
	if err != nil {
		fmt.Fprintf(os.Stderr, "[DEBUG] Step 15 FAILED: TCP Listen error: %v\n", err)
		logger.Error(fmt.Sprintf("TCP Listen: %v", err))
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 15: TCP listener created successfully\n")
	logger.Info("TCP listener created")

	fmt.Fprintf(os.Stderr, "[DEBUG] Step 16: About to create gRPC server\n")
	srv := grpc.NewServer(
		grpc.StatsHandler(otelgrpc.NewServerHandler()),
	)
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 16: gRPC server created\n")

	fmt.Fprintf(os.Stderr, "[DEBUG] Step 17: About to register reflection\n")
	reflection.Register(srv)
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 17: Reflection registered\n")

	fmt.Fprintf(os.Stderr, "[DEBUG] Step 18: About to register ProductCatalogService\n")
	pb.RegisterProductCatalogServiceServer(srv, svc)
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 18: ProductCatalogService registered\n")

	fmt.Fprintf(os.Stderr, "[DEBUG] Step 19: About to create health check\n")
	healthcheck := health.NewServer()
	healthpb.RegisterHealthServer(srv, healthcheck)
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 19: Health check registered\n")

	fmt.Fprintf(os.Stderr, "[DEBUG] Step 20: About to set up signal handlers\n")
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGKILL)
	defer cancel()
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 20: Signal handlers set\n")

	fmt.Fprintf(os.Stderr, "[DEBUG] Step 21: About to start gRPC server\n")
	initSpan.AddEvent("gRPC server starting")
	logger.Info("Starting gRPC server")
	fmt.Fprintf(os.Stderr, "[DEBUG] Step 21: Starting server goroutine\n")
	go func() {
		fmt.Fprintf(os.Stderr, "[DEBUG] SERVER RUNNING: gRPC server is now serving\n")
		if err := srv.Serve(ln); err != nil {
			fmt.Fprintf(os.Stderr, "[DEBUG] SERVER ERROR: Failed to serve gRPC server: %v\n", err)
			logger.Error(fmt.Sprintf("Failed to serve gRPC server, err: %v", err))
		}
	}()

	fmt.Fprintf(os.Stderr, "[DEBUG] Step 22: Server started, waiting for shutdown signal\n")
	initSpan.AddEvent("gRPC server started successfully")
	initSpan.SetAttributes(attribute.String("server.port", port))
	initSpan.SetStatus(otelcodes.Ok, "Service initialized successfully")
	logger.Info("Product Catalog gRPC server started and ready")

	<-ctx.Done()
	fmt.Fprintf(os.Stderr, "[DEBUG] Shutdown signal received\n")

	srv.GracefulStop()
	logger.Info("Product Catalog gRPC server stopped")
	fmt.Fprintf(os.Stderr, "[DEBUG] Server stopped\n")
}

type productCatalog struct {
	pb.UnimplementedProductCatalogServiceServer
}

func loadProductCatalog() {
	fmt.Fprintf(os.Stderr, "[LOAD] Loading Product Catalog...\n")
	logger.Info("Loading Product Catalog...")
	var err error
	catalog, err = readProductFiles()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[LOAD] ERROR: Error reading product files: %v. Will use database if available.\n", err)
		logger.Warn(fmt.Sprintf("Error reading product files: %v. Will use database if available.", err))
		catalog = []*pb.Product{} // Initialize empty catalog instead of exiting
		return
	}
	fmt.Fprintf(os.Stderr, "[LOAD] Successfully loaded %d products\n", len(catalog))

	// Default reload interval is 10 seconds
	interval := DEFAULT_RELOAD_INTERVAL
	si := os.Getenv("PRODUCT_CATALOG_RELOAD_INTERVAL")
	if si != "" {
		interval, _ = strconv.Atoi(si)
		if interval <= 0 {
			interval = DEFAULT_RELOAD_INTERVAL
		}
	}
	logger.Info(fmt.Sprintf("Product Catalog reload interval: %d", interval))

	ticker := time.NewTicker(time.Duration(interval) * time.Second)

	go func() {
		for {
			select {
			case <-ticker.C:
				logger.Info("Reloading Product Catalog...")
				catalog, err = readProductFiles()
				if err != nil {
					logger.Error(fmt.Sprintf("Error reading product files: %v", err))
					continue
				}
			}
		}
	}()
}

func readProductFiles() ([]*pb.Product, error) {

	// find all .json files in the products directory
	entries, err := os.ReadDir("./products")
	if err != nil {
		return nil, err
	}

	jsonFiles := make([]fs.FileInfo, 0, len(entries))
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".json") {
			info, err := entry.Info()
			if err != nil {
				return nil, err
			}
			jsonFiles = append(jsonFiles, info)
		}
	}

	// read the contents of each .json file and unmarshal into a ListProductsResponse
	// then append the products to the catalog
	var products []*pb.Product
	for _, f := range jsonFiles {
		jsonData, err := os.ReadFile("./products/" + f.Name())
		if err != nil {
			return nil, err
		}

		var res pb.ListProductsResponse
		if err := protojson.Unmarshal(jsonData, &res); err != nil {
			return nil, err
		}

		products = append(products, res.Products...)
	}

	logger.LogAttrs(
		context.Background(),
		slog.LevelInfo,
		fmt.Sprintf("Loaded %d products\n", len(products)),
		slog.Int("products", len(products)),
	)

	return products, nil
}

func mustMapEnv(target *string, key string) {
	value, present := os.LookupEnv(key)
	if !present {
		logger.Error(fmt.Sprintf("Environment Variable Not Set: %q", key))
	}
	*target = value
}

func (p *productCatalog) Check(ctx context.Context, req *healthpb.HealthCheckRequest) (*healthpb.HealthCheckResponse, error) {
	return &healthpb.HealthCheckResponse{Status: healthpb.HealthCheckResponse_SERVING}, nil
}

func (p *productCatalog) Watch(req *healthpb.HealthCheckRequest, ws healthpb.Health_WatchServer) error {
	return status.Errorf(codes.Unimplemented, "health check via Watch not implemented")
}

func listProductsFromDB(ctx context.Context) ([]*pb.Product, error) {
	tracer := otel.Tracer("product-catalog")
	ctx, span := tracer.Start(ctx, "db.products.list")
	defer span.End()

	span.SetAttributes(
		semconv.DBSystemPostgreSQL,
		attribute.String("db.operation", "SELECT"),
		attribute.String("db.sql.table", "products"),
	)

	query := `SELECT id, name, description, picture, price_currency_code, price_units, price_nanos, categories 
	          FROM products ORDER BY name`

	span.SetAttributes(attribute.String("db.statement", query))

	// Execute query with explicit span
	ctx, querySpan := tracer.Start(ctx, "db.query.execute")
	rows, err := db.QueryContext(ctx, query)
	querySpan.End()

	if err != nil {
		span.RecordError(err)
		span.SetStatus(otelcodes.Error, fmt.Sprintf("Database query failed: %v", err))
		span.SetAttributes(
			attribute.Bool("db.query.error", true),
			attribute.String("db.error.message", err.Error()),
		)
		return nil, fmt.Errorf("failed to query products: %w", err)
	}
	defer rows.Close()

	span.SetAttributes(attribute.Bool("db.query.success", true))

	// Scan rows with explicit span
	var products []*pb.Product
	ctx, scanSpan := tracer.Start(ctx, "db.rows.scan")
	scanCount := 0

	for rows.Next() {
		var product pb.Product
		product.PriceUsd = &pb.Money{}
		var categories pq.StringArray

		err := rows.Scan(
			&product.Id,
			&product.Name,
			&product.Description,
			&product.Picture,
			&product.PriceUsd.CurrencyCode,
			&product.PriceUsd.Units,
			&product.PriceUsd.Nanos,
			&categories,
		)

		if err != nil {
			scanSpan.RecordError(err)
			scanSpan.SetStatus(otelcodes.Error, fmt.Sprintf("Row scan failed: %v", err))
			scanSpan.SetAttributes(
				attribute.Int("db.rows.scanned", scanCount),
				attribute.Bool("db.scan.error", true),
				attribute.String("db.error.message", err.Error()),
			)
			scanSpan.End()
			span.RecordError(err)
			span.SetStatus(otelcodes.Error, fmt.Sprintf("Failed to scan product row: %v", err))
			return nil, fmt.Errorf("failed to scan product row: %w", err)
		}

		product.Categories = categories
		products = append(products, &product)
		scanCount++
	}

	if err = rows.Err(); err != nil {
		scanSpan.RecordError(err)
		scanSpan.SetStatus(otelcodes.Error, fmt.Sprintf("Row iteration error: %v", err))
		scanSpan.SetAttributes(
			attribute.Int("db.rows.scanned", scanCount),
			attribute.Bool("db.iteration.error", true),
			attribute.String("db.error.message", err.Error()),
		)
		scanSpan.End()
		span.RecordError(err)
		span.SetStatus(otelcodes.Error, fmt.Sprintf("Error iterating product rows: %v", err))
		return nil, fmt.Errorf("error iterating product rows: %w", err)
	}

	scanSpan.SetAttributes(
		attribute.Int("db.rows.scanned", scanCount),
		attribute.Bool("db.scan.success", true),
	)
	scanSpan.End()

	span.SetAttributes(
		attribute.Int("db.rows_returned", len(products)),
		attribute.Bool("db.operation.success", true),
	)
	span.SetStatus(otelcodes.Ok, "Products retrieved successfully")
	return products, nil
}

func getProductFromDB(ctx context.Context, id string) (*pb.Product, error) {
	tracer := otel.Tracer("product-catalog")
	ctx, span := tracer.Start(ctx, "db.products.get")
	defer span.End()

	span.SetAttributes(
		semconv.DBSystemPostgreSQL,
		attribute.String("db.operation", "SELECT"),
		attribute.String("db.sql.table", "products"),
		attribute.String("app.product.id", id),
	)

	query := `SELECT id, name, description, picture, price_currency_code, price_units, price_nanos, categories 
	          FROM products WHERE id = $1`

	span.SetAttributes(attribute.String("db.statement", query))

	// Execute query with explicit span
	ctx, querySpan := tracer.Start(ctx, "db.query.execute")
	row := db.QueryRowContext(ctx, query, id)
	querySpan.End()

	var product pb.Product
	product.PriceUsd = &pb.Money{}
	var categories pq.StringArray

	// Scan with explicit span
	ctx, scanSpan := tracer.Start(ctx, "db.row.scan")
	err := row.Scan(
		&product.Id,
		&product.Name,
		&product.Description,
		&product.Picture,
		&product.PriceUsd.CurrencyCode,
		&product.PriceUsd.Units,
		&product.PriceUsd.Nanos,
		&categories,
	)
	scanSpan.End()

	if err == sql.ErrNoRows {
		span.SetAttributes(
			attribute.Bool("db.query.not_found", true),
			attribute.Bool("db.operation.success", false),
		)
		span.SetStatus(otelcodes.Error, fmt.Sprintf("Product not found: %s", id))
		return nil, status.Errorf(codes.NotFound, "Product Not Found: %s", id)
	}

	if err != nil {
		span.RecordError(err)
		span.SetStatus(otelcodes.Error, fmt.Sprintf("Database query failed: %v", err))
		span.SetAttributes(
			attribute.Bool("db.query.error", true),
			attribute.String("db.error.message", err.Error()),
		)
		return nil, fmt.Errorf("failed to query product: %w", err)
	}

	product.Categories = categories

	span.SetAttributes(
		attribute.Bool("db.operation.success", true),
		attribute.String("app.product.name", product.Name),
	)
	span.SetStatus(otelcodes.Ok, "Product retrieved successfully")
	return &product, nil
}

func searchProductsFromDB(ctx context.Context, query string) ([]*pb.Product, error) {
	tracer := otel.Tracer("product-catalog")
	ctx, span := tracer.Start(ctx, "db.products.search")
	defer span.End()

	span.SetAttributes(
		semconv.DBSystemPostgreSQL,
		attribute.String("db.operation", "SELECT"),
		attribute.String("db.sql.table", "products"),
		attribute.String("app.search.query", query),
	)

	sqlQuery := `SELECT id, name, description, picture, price_currency_code, price_units, price_nanos, categories 
	             FROM products 
	             WHERE name ILIKE $1 OR description ILIKE $1
	             ORDER BY name`

	searchPattern := "%" + query + "%"
	span.SetAttributes(
		attribute.String("db.statement", sqlQuery),
		attribute.String("db.query.parameter", searchPattern),
	)

	// Execute query with explicit span
	ctx, querySpan := tracer.Start(ctx, "db.query.execute")
	rows, err := db.QueryContext(ctx, sqlQuery, searchPattern)
	querySpan.End()

	if err != nil {
		span.RecordError(err)
		span.SetStatus(otelcodes.Error, fmt.Sprintf("Database query failed: %v", err))
		span.SetAttributes(
			attribute.Bool("db.query.error", true),
			attribute.String("db.error.message", err.Error()),
		)
		return nil, fmt.Errorf("failed to search products: %w", err)
	}
	defer rows.Close()

	span.SetAttributes(attribute.Bool("db.query.success", true))

	// Scan rows with explicit span
	var products []*pb.Product
	ctx, scanSpan := tracer.Start(ctx, "db.rows.scan")
	scanCount := 0

	for rows.Next() {
		var product pb.Product
		product.PriceUsd = &pb.Money{}
		var categories pq.StringArray

		err := rows.Scan(
			&product.Id,
			&product.Name,
			&product.Description,
			&product.Picture,
			&product.PriceUsd.CurrencyCode,
			&product.PriceUsd.Units,
			&product.PriceUsd.Nanos,
			&categories,
		)

		if err != nil {
			scanSpan.RecordError(err)
			scanSpan.SetStatus(otelcodes.Error, fmt.Sprintf("Row scan failed: %v", err))
			scanSpan.SetAttributes(
				attribute.Int("db.rows.scanned", scanCount),
				attribute.Bool("db.scan.error", true),
				attribute.String("db.error.message", err.Error()),
			)
			scanSpan.End()
			span.RecordError(err)
			span.SetStatus(otelcodes.Error, fmt.Sprintf("Failed to scan product row: %v", err))
			return nil, fmt.Errorf("failed to scan product row: %w", err)
		}

		product.Categories = categories
		products = append(products, &product)
		scanCount++
	}

	if err = rows.Err(); err != nil {
		scanSpan.RecordError(err)
		scanSpan.SetStatus(otelcodes.Error, fmt.Sprintf("Row iteration error: %v", err))
		scanSpan.SetAttributes(
			attribute.Int("db.rows.scanned", scanCount),
			attribute.Bool("db.iteration.error", true),
			attribute.String("db.error.message", err.Error()),
		)
		scanSpan.End()
		span.RecordError(err)
		span.SetStatus(otelcodes.Error, fmt.Sprintf("Error iterating product rows: %v", err))
		return nil, fmt.Errorf("error iterating product rows: %w", err)
	}

	scanSpan.SetAttributes(
		attribute.Int("db.rows.scanned", scanCount),
		attribute.Bool("db.scan.success", true),
	)
	scanSpan.End()

	span.SetAttributes(
		attribute.Int("db.rows_returned", len(products)),
		attribute.Bool("db.operation.success", true),
	)
	span.SetStatus(otelcodes.Ok, "Products search completed successfully")
	return products, nil
}

func (p *productCatalog) ListProducts(ctx context.Context, req *pb.Empty) (*pb.ListProductsResponse, error) {
	span := trace.SpanFromContext(ctx)

	if useDatabase && db != nil {
		products, err := listProductsFromDB(ctx)
		if err != nil {
			// Create explicit error span for visibility in traces
			tracer := otel.Tracer("product-catalog")
			_, errorSpan := tracer.Start(ctx, "error.list-products-failed")
			errorSpan.SetAttributes(
				attribute.String("error.type", "database_query_failure"),
				attribute.String("error.message", err.Error()),
			)
			errorSpan.RecordError(err)
			errorSpan.SetStatus(otelcodes.Error, "Failed to list products from database")
			errorSpan.End()

			span.SetStatus(otelcodes.Error, err.Error())
			logger.Error(fmt.Sprintf("Failed to list products from database: %v", err))
			return nil, status.Errorf(codes.Internal, "Failed to list products: %v", err)
		}
		span.SetAttributes(
			attribute.Int("app.products.count", len(products)),
			attribute.String("app.products.source", "database"),
		)
		return &pb.ListProductsResponse{Products: products}, nil
	}

	span.SetAttributes(
		attribute.Int("app.products.count", len(catalog)),
		attribute.String("app.products.source", "json"),
	)
	return &pb.ListProductsResponse{Products: catalog}, nil
}

func (p *productCatalog) GetProduct(ctx context.Context, req *pb.GetProductRequest) (*pb.Product, error) {
	span := trace.SpanFromContext(ctx)
	span.SetAttributes(
		attribute.String("app.product.id", req.Id),
	)

	// GetProduct will fail on a specific product when feature flag is enabled
	if p.checkProductFailure(ctx, req.Id) {
		msg := "Error: Product Catalog Fail Feature Flag Enabled"
		span.SetStatus(otelcodes.Error, msg)
		span.AddEvent(msg)
		return nil, status.Errorf(codes.Internal, msg)
	}

	var found *pb.Product
	var err error

	if useDatabase && db != nil {
		found, err = getProductFromDB(ctx, req.Id)
		if err != nil {
			// Create explicit error span for visibility in traces
			tracer := otel.Tracer("product-catalog")
			_, errorSpan := tracer.Start(ctx, "error.get-product-failed")
			errorSpan.SetAttributes(
				attribute.String("error.type", "database_query_failure"),
				attribute.String("error.message", err.Error()),
				attribute.String("app.product.id", req.Id),
			)
			errorSpan.RecordError(err)
			errorSpan.SetStatus(otelcodes.Error, "Failed to get product from database")
			errorSpan.End()

			span.SetStatus(otelcodes.Error, err.Error())
			span.AddEvent(err.Error())
			logger.Error(fmt.Sprintf("Failed to get product from database: %v", err))
			return nil, err
		}
		span.SetAttributes(attribute.String("app.products.source", "database"))
	} else {
		for _, product := range catalog {
			if req.Id == product.Id {
				found = product
				break
			}
		}
		span.SetAttributes(attribute.String("app.products.source", "json"))

		if found == nil {
			msg := fmt.Sprintf("Product Not Found: %s", req.Id)
			span.SetStatus(otelcodes.Error, msg)
			span.AddEvent(msg)
			return nil, status.Errorf(codes.NotFound, msg)
		}
	}

	span.AddEvent("Product Found")
	span.SetAttributes(
		attribute.String("app.product.id", req.Id),
		attribute.String("app.product.name", found.Name),
	)

	logger.LogAttrs(
		ctx,
		slog.LevelInfo, "Product Found",
		slog.String("app.product.name", found.Name),
		slog.String("app.product.id", req.Id),
	)

	return found, nil
}

func (p *productCatalog) SearchProducts(ctx context.Context, req *pb.SearchProductsRequest) (*pb.SearchProductsResponse, error) {
	span := trace.SpanFromContext(ctx)

	var result []*pb.Product
	var err error

	if useDatabase && db != nil {
		result, err = searchProductsFromDB(ctx, req.Query)
		if err != nil {
			// Create explicit error span for visibility in traces
			tracer := otel.Tracer("product-catalog")
			_, errorSpan := tracer.Start(ctx, "error.search-products-failed")
			errorSpan.SetAttributes(
				attribute.String("error.type", "database_query_failure"),
				attribute.String("error.message", err.Error()),
				attribute.String("app.search.query", req.Query),
			)
			errorSpan.RecordError(err)
			errorSpan.SetStatus(otelcodes.Error, "Failed to search products from database")
			errorSpan.End()

			span.SetStatus(otelcodes.Error, err.Error())
			logger.Error(fmt.Sprintf("Failed to search products from database: %v", err))
			return nil, status.Errorf(codes.Internal, "Failed to search products: %v", err)
		}
		span.SetAttributes(attribute.String("app.products.source", "database"))
	} else {
		for _, product := range catalog {
			if strings.Contains(strings.ToLower(product.Name), strings.ToLower(req.Query)) ||
				strings.Contains(strings.ToLower(product.Description), strings.ToLower(req.Query)) {
				result = append(result, product)
			}
		}
		span.SetAttributes(attribute.String("app.products.source", "json"))
	}

	span.SetAttributes(
		attribute.Int("app.products_search.count", len(result)),
	)
	return &pb.SearchProductsResponse{Results: result}, nil
}

func (p *productCatalog) checkProductFailure(ctx context.Context, id string) bool {
	if id != "OLJCESPC7Z" {
		return false
	}

	client := openfeature.NewClient("productCatalog")
	failureEnabled, _ := client.BooleanValue(
		ctx, "productCatalogFailure", false, openfeature.EvaluationContext{},
	)
	return failureEnabled
}

func createClient(ctx context.Context, svcAddr string) (*grpc.ClientConn, error) {
	return grpc.DialContext(ctx, svcAddr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithStatsHandler(otelgrpc.NewClientHandler()),
	)
}
