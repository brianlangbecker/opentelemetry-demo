// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

using Confluent.Kafka;
using Microsoft.Extensions.Logging;
using Oteldemo;
using Microsoft.EntityFrameworkCore;
using System.Diagnostics;
using System.Text;

namespace Accounting;

internal class DBContext : DbContext
{
    public DbSet<OrderEntity> Orders { get; set; }
    public DbSet<OrderItemEntity> CartItems { get; set; }
    public DbSet<ShippingEntity> Shipping { get; set; }

    protected override void OnConfiguring(DbContextOptionsBuilder optionsBuilder)
    {
        var connectionString = Environment.GetEnvironmentVariable("DB_CONNECTION_STRING");

        optionsBuilder.UseNpgsql(connectionString).UseSnakeCaseNamingConvention();
    }
}


internal class Consumer : IDisposable
{
    private const string TopicName = "orders";

    private ILogger _logger;
    private IConsumer<string, byte[]> _consumer;
    private bool _isListening;
    private string? _connectionString;
    private static readonly ActivitySource MyActivitySource = new("Accounting.Consumer");

    public Consumer(ILogger<Consumer> logger)
    {
        _logger = logger;

        var servers = Environment.GetEnvironmentVariable("KAFKA_ADDR")
            ?? throw new ArgumentNullException("KAFKA_ADDR");

        _consumer = BuildConsumer(servers);
        _consumer.Subscribe(TopicName);

        _logger.LogInformation($"Connecting to Kafka: {servers}");
        _connectionString = Environment.GetEnvironmentVariable("DB_CONNECTION_STRING");
    }

    public void StartListening()
    {
        _isListening = true;

        try
        {
            while (_isListening)
            {
                try
                {
                    var consumeResult = _consumer.Consume();

                    // Extract parent trace context from Kafka message headers
                    var parentContext = ExtractTraceContextFromKafkaHeaders(consumeResult.Message.Headers);

                    // Create span with parent context
                    using var activity = parentContext != default
                        ? MyActivitySource.StartActivity(
                            "order-consumed",
                            ActivityKind.Consumer,  // Changed from Internal to Consumer
                            parentContext
                          )
                        : MyActivitySource.StartActivity(
                            "order-consumed",
                            ActivityKind.Consumer
                          );

                    // Add Kafka-specific attributes
                    if (activity != null)
                    {
                        activity.SetTag("messaging.system", "kafka");
                        activity.SetTag("messaging.destination", TopicName);
                        activity.SetTag("messaging.operation", "receive");
                    }

                    ProcessMessage(consumeResult.Message);
                }
                catch (ConsumeException e)
                {
                    _logger.LogError(e, "Consume error: {0}", e.Error.Reason);
                }
            }
        }
        catch (OperationCanceledException)
        {
            _logger.LogInformation("Closing consumer");

            _consumer.Close();
        }
    }

    private void ProcessMessage(Message<string, byte[]> message)
    {
        try
        {
            // Parse protobuf message
            OrderResult order;
            using (var parseActivity = MyActivitySource.StartActivity("parse-order", ActivityKind.Internal))
            {
                order = OrderResult.Parser.ParseFrom(message.Value);
                parseActivity?.SetTag("order.id", order.OrderId);
                parseActivity?.SetTag("order.item_count", order.Items.Count);
            }

            Log.OrderReceivedMessage(_logger, order);

            if (_connectionString == null)
            {
                return;
            }

            // Create database context
            DBContext dbContext;
            using (var contextActivity = MyActivitySource.StartActivity("create-dbcontext", ActivityKind.Internal))
            {
                // Create a new DBContext for each message to avoid memory bloat
                dbContext = new DBContext();
            }

            using (dbContext)
            {
                // Build entities
                using (var buildActivity = MyActivitySource.StartActivity("build-entities", ActivityKind.Internal))
                {
                    var orderEntity = new OrderEntity
                    {
                        Id = order.OrderId
                    };
                    dbContext.Add(orderEntity);

                    foreach (var item in order.Items)
                    {
                        var orderItem = new OrderItemEntity
                        {
                            ItemCostCurrencyCode = item.Cost.CurrencyCode,
                            ItemCostUnits = item.Cost.Units,
                            ItemCostNanos = item.Cost.Nanos,
                            ProductId = item.Item.ProductId,
                            Quantity = item.Item.Quantity,
                            OrderId = order.OrderId
                        };

                        dbContext.Add(orderItem);
                    }

                    var shipping = new ShippingEntity
                    {
                        ShippingTrackingId = order.ShippingTrackingId,
                        ShippingCostCurrencyCode = order.ShippingCost.CurrencyCode,
                        ShippingCostUnits = order.ShippingCost.Units,
                        ShippingCostNanos = order.ShippingCost.Nanos,
                        StreetAddress = order.ShippingAddress.StreetAddress,
                        City = order.ShippingAddress.City,
                        State = order.ShippingAddress.State,
                        Country = order.ShippingAddress.Country,
                        ZipCode = order.ShippingAddress.ZipCode,
                        OrderId = order.OrderId
                    };
                    dbContext.Add(shipping);
                    buildActivity?.SetTag("entities.total", order.Items.Count + 2);
                }

                // Save to database (auto-instrumented by EF Core)
                using (var saveActivity = MyActivitySource.StartActivity("save-changes", ActivityKind.Internal))
                {
                    dbContext.SaveChanges();
                }
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Order parsing failed:");
        }
    }

    private ActivityContext ExtractTraceContextFromKafkaHeaders(Headers headers)
    {
        try
        {
            // Extract traceparent header (W3C Trace Context format)
            var traceparentHeader = headers?.FirstOrDefault(h => h.Key == "traceparent");
            if (traceparentHeader != null)
            {
                var traceparent = Encoding.UTF8.GetString(traceparentHeader.GetValueBytes());

                // Parse W3C traceparent: 00-{traceId}-{spanId}-{flags}
                if (ActivityContext.TryParse(traceparent, null, out var context))
                {
                    _logger.LogDebug($"Extracted trace context: TraceId={context.TraceId}, SpanId={context.SpanId}");
                    return context;
                }
                else
                {
                    _logger.LogWarning($"Failed to parse traceparent header: {traceparent}");
                }
            }
            else
            {
                _logger.LogDebug("No traceparent header found in Kafka message");
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to extract trace context from Kafka headers");
        }

        return default; // Return empty context if extraction fails
    }

    private IConsumer<string, byte[]> BuildConsumer(string servers)
    {
        var conf = new ConsumerConfig
        {
            GroupId = $"accounting",
            BootstrapServers = servers,
            // https://github.com/confluentinc/confluent-kafka-dotnet/tree/07de95ed647af80a0db39ce6a8891a630423b952#basic-consumer-example
            AutoOffsetReset = AutoOffsetReset.Earliest,
            EnableAutoCommit = true
        };

        return new ConsumerBuilder<string, byte[]>(conf)
            .Build();
    }

    public void Dispose()
    {
        _isListening = false;
        _consumer?.Dispose();
    }
}
