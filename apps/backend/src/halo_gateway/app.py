from fastapi import FastAPI

from halo_gateway import __version__
from halo_gateway.contracts import (
    OrchestrationValidationRequest,
    ProviderConfig,
    PublishabilityRequest,
    PublishabilityResult,
    evaluate_publishability,
)

app = FastAPI(
    title="Halo Gateway",
    version=__version__,
    description="Optional self-hosted boundary for explicit Halo graph offloads.",
)


@app.get("/healthz")
def health_check() -> dict:
    return {
        "status": "ok",
        "service": "halo-gateway",
        "version": __version__,
        "protocolVersion": "1.0",
    }


@app.post("/v1/providers/validate")
def validate_provider(provider: ProviderConfig) -> dict:
    return {
        "provider": provider.model_dump(by_alias=True, mode="json"),
        "persisted": False,
    }


@app.post("/v1/orchestration/validate")
def validate_orchestration(request: OrchestrationValidationRequest) -> dict:
    return {
        "valid": True,
        "executionOwner": "gateway",
        "offloadId": request.offload_id,
        "started": False,
    }


@app.post(
    "/v1/verification/publishability",
    response_model=PublishabilityResult,
)
def publishability(request: PublishabilityRequest) -> PublishabilityResult:
    return evaluate_publishability(request)
