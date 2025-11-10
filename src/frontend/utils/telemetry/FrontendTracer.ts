// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import { HoneycombWebSDK } from '@honeycombio/opentelemetry-web';
import { getWebAutoInstrumentations } from '@opentelemetry/auto-instrumentations-web';
import { SessionIdProcessor } from './SessionIdProcessor';

const {
  NEXT_PUBLIC_OTEL_SERVICE_NAME = '',
  NEXT_PUBLIC_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT = '',
  IS_SYNTHETIC_REQUEST = '',
} = typeof window !== 'undefined' ? window.ENV : {};

const FrontendTracer = async () => {
  // Use Honeycomb Web SDK which provides:
  // - Automatic instrumentation for fetch, XHR, document load, user interaction
  // - Web Vitals collection (LCP, FID, CLS)
  // - Proper browser-specific configuration
  // - Better error handling and debugging

  const sdk = new HoneycombWebSDK({
    // Use collector endpoint instead of direct API key (secure pattern)
    endpoint: NEXT_PUBLIC_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT || 'http://localhost:4318/v1/traces',

    // Service name for traces
    serviceName: NEXT_PUBLIC_OTEL_SERVICE_NAME || 'frontend-web',

    // Enable debug mode for development troubleshooting
    debug: process.env.NODE_ENV === 'development',

    // Custom instrumentations with app-specific configuration
    instrumentations: [
      getWebAutoInstrumentations({
        '@opentelemetry/instrumentation-fetch': {
          propagateTraceHeaderCorsUrls: /.*/,
          clearTimingResources: true,
          applyCustomAttributesOnSpan(span) {
            span.setAttribute('app.synthetic_request', IS_SYNTHETIC_REQUEST);
          },
        },
        // Enable user interaction instrumentation for better UX insights
        '@opentelemetry/instrumentation-user-interaction': {
          enabled: true,
          eventNames: ['click', 'submit'],
        },
        // Enable document load instrumentation for performance tracking
        '@opentelemetry/instrumentation-document-load': {
          enabled: true,
        },
      }),
    ],

    // Add custom span processors (like SessionIdProcessor)
    spanProcessors: [new SessionIdProcessor()],

    // Skip library detection to avoid extra overhead
    skipOptionsValidation: false,
  });

  sdk.start();
};

export default FrontendTracer;
