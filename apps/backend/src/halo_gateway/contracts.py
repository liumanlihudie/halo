from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field, HttpUrl, model_validator


class ContractModel(BaseModel):
    model_config = ConfigDict(
        alias_generator=lambda name: "".join(
            word if index == 0 else word.capitalize()
            for index, word in enumerate(name.split("_"))
        ),
        populate_by_name=True,
        extra="forbid",
    )


class AdapterType(str, Enum):
    TOAPIS = "toapis"
    OPENAI_COMPATIBLE = "openai_compatible"
    OPENAI = "openai"
    ANTHROPIC = "anthropic"
    GEMINI = "gemini"
    DOUBAO_REALTIME_VOICE = "doubao_realtime_voice"
    CUSTOM_GATEWAY = "custom_gateway"


class ProviderConfig(ContractModel):
    id: str = Field(min_length=1, max_length=128, pattern=r"^[a-z0-9][a-z0-9._-]*$")
    adapter_type: AdapterType
    display_name: str = Field(min_length=1, max_length=128)
    base_url: HttpUrl
    secret_ref: str = Field(pattern=r"^vault://[A-Za-z0-9._/-]+$")
    enabled: bool = True
    priority: int = Field(default=100, ge=0, le=10_000)


class ModelRef(ContractModel):
    provider_id: str = Field(min_length=1, max_length=128)
    model_id: str = Field(min_length=1, max_length=256)


class ModelAssignment(ContractModel):
    agent_id: str = Field(min_length=1, max_length=128)
    model_ref: ModelRef


class GraphSpecRef(ContractModel):
    graph_id: str = Field(min_length=1, max_length=128)
    version: int = Field(ge=1)
    content_hash: str = Field(pattern=r"^sha256:[0-9a-f]{16,64}$")


class StateSchemaRef(ContractModel):
    schema_id: str = Field(min_length=1, max_length=128)
    version: int = Field(ge=1)


class OrchestrationMode(str, Enum):
    CREATIVE = "creative"
    GROUNDED = "grounded"
    HIGH_STAKES = "high_stakes"


class RunBudget(ContractModel):
    max_agent_messages: int = Field(ge=1, le=100)
    max_model_calls: int = Field(ge=1, le=100)
    max_wall_clock_seconds: int = Field(ge=1, le=86_400)


class AuthorizedStateSlice(ContractModel):
    authorized_message_ids: list[str] = Field(default_factory=list, max_length=500)
    authorized_asset_ids: list[str] = Field(default_factory=list, max_length=500)


class OrchestrationValidationRequest(ContractModel):
    offload_id: str = Field(min_length=1, max_length=128)
    client_command_id: str = Field(min_length=1, max_length=128)
    graph_spec_ref: GraphSpecRef
    state_schema_ref: StateSchemaRef
    executable_agent_ids: list[str] = Field(min_length=1, max_length=50)
    model_assignments: list[ModelAssignment] = Field(
        default_factory=list, max_length=50
    )
    mode: OrchestrationMode
    budget: RunBudget
    state_slice: AuthorizedStateSlice

    @model_validator(mode="after")
    def assignments_only_target_executable_agents(
        self,
    ) -> OrchestrationValidationRequest:
        executable = set(self.executable_agent_ids)
        assigned = {assignment.agent_id for assignment in self.model_assignments}
        unapproved = assigned - executable
        if unapproved:
            raise ValueError(
                "model assignments reference unapproved agents: "
                + ", ".join(sorted(unapproved))
            )
        if len(executable) != len(self.executable_agent_ids):
            raise ValueError("executableAgentIds must be unique")
        return self


class ClaimType(str, Enum):
    FACT = "fact"
    INFERENCE = "inference"
    OPINION = "opinion"
    PROPOSAL = "proposal"


class ClaimRisk(str, Enum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"


class VerificationStatus(str, Enum):
    UNVERIFIED = "unverified"
    SUPPORTED = "supported"
    PARTIALLY_SUPPORTED = "partiallySupported"
    CONTRADICTED = "contradicted"
    UNVERIFIABLE = "unverifiable"
    STALE = "stale"


class Claim(ContractModel):
    id: str = Field(min_length=1, max_length=128)
    run_id: str = Field(min_length=1, max_length=128)
    author_agent_id: str = Field(min_length=1, max_length=128)
    text: str = Field(min_length=1, max_length=10_000)
    type: ClaimType
    risk: ClaimRisk
    temporal_scope: Optional[str] = Field(default=None, max_length=256)
    evidence_ref_ids: list[str] = Field(default_factory=list, max_length=100)
    verification_status: VerificationStatus
    verifier_run_id: Optional[str] = Field(default=None, max_length=128)
    verification_notes: Optional[str] = Field(default=None, max_length=4_000)


class EvidenceSourceType(str, Enum):
    USER_MESSAGE = "user_message"
    LOCAL_ASSET = "local_asset"
    WEB_SOURCE = "web_source"
    TOOL_RESULT = "tool_result"
    DATABASE_RECORD = "database_record"
    TEST_RESULT = "test_result"


class TrustTier(str, Enum):
    E0 = "E0"
    E1 = "E1"
    E2 = "E2"
    E3 = "E3"
    E4 = "E4"


class EvidenceRef(ContractModel):
    id: str = Field(min_length=1, max_length=128)
    source_type: EvidenceSourceType
    source_id: str = Field(min_length=1, max_length=512)
    source_title: str = Field(min_length=1, max_length=512)
    locator: str = Field(min_length=1, max_length=2_048)
    captured_at: datetime
    content_hash: str = Field(pattern=r"^sha256:[0-9a-f]{16,64}$")
    excerpt: str = Field(min_length=1, max_length=4_000)
    trust_tier: TrustTier


class VerifierResult(ContractModel):
    run_id: str = Field(min_length=1, max_length=128)
    claim_id: str = Field(min_length=1, max_length=128)
    status: VerificationStatus
    supporting_evidence_ref_ids: list[str] = Field(default_factory=list, max_length=100)
    conflicting_evidence_ref_ids: list[str] = Field(
        default_factory=list, max_length=100
    )
    notes: str = Field(min_length=1, max_length=4_000)


class PublishabilityRequest(ContractModel):
    claims: list[Claim] = Field(max_length=500)
    evidence: list[EvidenceRef] = Field(max_length=1_000)
    verifier_results: list[VerifierResult] = Field(max_length=500)


class PublishabilityResult(ContractModel):
    publishable: bool
    blocked_claim_ids: list[str]
    reasons: list[str]


def evaluate_publishability(request: PublishabilityRequest) -> PublishabilityResult:
    evidence_ids = {item.id for item in request.evidence}
    verifier_by_claim = {result.claim_id: result for result in request.verifier_results}
    blocked_claim_ids: list[str] = []
    reasons: list[str] = []

    def block(claim_id: str, reason: str) -> None:
        if claim_id not in blocked_claim_ids:
            blocked_claim_ids.append(claim_id)
        if reason not in reasons:
            reasons.append(reason)

    for claim in request.claims:
        if claim.type is not ClaimType.FACT:
            continue
        if claim.verification_status is not VerificationStatus.SUPPORTED:
            block(claim.id, "unverified_fact")
            continue
        if not claim.evidence_ref_ids or not set(claim.evidence_ref_ids).issubset(
            evidence_ids
        ):
            block(claim.id, "missing_traceable_evidence")
            continue
        verifier = verifier_by_claim.get(claim.id)
        if (
            verifier is None
            or verifier.run_id != claim.verifier_run_id
            or verifier.status is not VerificationStatus.SUPPORTED
            or not set(claim.evidence_ref_ids).issubset(
                set(verifier.supporting_evidence_ref_ids)
            )
        ):
            block(claim.id, "missing_independent_verification")

    return PublishabilityResult(
        publishable=not blocked_claim_ids,
        blocked_claim_ids=blocked_claim_ids,
        reasons=reasons,
    )
