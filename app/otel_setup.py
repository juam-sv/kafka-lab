"""OpenTelemetry initialization for producer/consumer."""
import logging
import os

from opentelemetry import trace


def init_tracer(service_name: str) -> trace.Tracer:
    if not os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
        return trace.get_tracer(service_name)

    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.instrumentation.logging import LoggingInstrumentor
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    resource = Resource.create({
        "service.name": service_name,
        "deployment.environment": os.getenv("OTEL_DEPLOYMENT_ENVIRONMENT", "local"),
        "cloud.region": os.getenv("AWS_REGION", "us-east-1"),
        "service.version": os.getenv("APP_VERSION", "0.0.1"),
    })
    provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(
        endpoint=os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
        insecure=os.getenv("OTEL_EXPORTER_OTLP_INSECURE", "true").lower() == "true",
    )
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)

    LoggingInstrumentor().instrument(set_logging_format=True, log_level=logging.INFO)

    return trace.get_tracer(service_name)
