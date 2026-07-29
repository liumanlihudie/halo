import unittest

from fastapi.testclient import TestClient

from halo_gateway.app import app


class GatewayApiTest(unittest.TestCase):
    def setUp(self) -> None:
        self.client = TestClient(app)

    def test_health_check_exposes_protocol_compatibility(self) -> None:
        response = self.client.get("/healthz")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json(),
            {
                "status": "ok",
                "service": "halo-gateway",
                "version": "0.1.0",
                "protocolVersion": "1.0",
            },
        )

    def test_provider_metadata_can_be_validated_without_a_secret(self) -> None:
        response = self.client.post(
            "/v1/providers/validate",
            json={
                "id": "deepseek-official",
                "adapterType": "openai_compatible",
                "displayName": "DeepSeek",
                "baseUrl": "https://api.deepseek.com/v1",
                "secretRef": "vault://provider/deepseek-official",
                "enabled": True,
                "priority": 10,
            },
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["provider"]["id"], "deepseek-official")
        self.assertEqual(
            body["provider"]["secretRef"], "vault://provider/deepseek-official"
        )
        self.assertNotIn("apiKey", body["provider"])
        self.assertFalse(body["persisted"])

    def test_provider_payload_rejects_inline_api_keys(self) -> None:
        response = self.client.post(
            "/v1/providers/validate",
            json={
                "id": "toapis",
                "adapterType": "toapis",
                "displayName": "ToAPIs",
                "baseUrl": "https://toapis.com/v1",
                "secretRef": "vault://provider/toapis",
                "enabled": True,
                "priority": 1,
                "apiKey": "must-never-enter-the-gateway-contract",
            },
        )

        self.assertEqual(response.status_code, 422)

    def test_orchestration_request_validates_an_explicit_gateway_offload(self) -> None:
        response = self.client.post(
            "/v1/orchestration/validate",
            json={
                "offloadId": "offload-01",
                "clientCommandId": "command-01",
                "graphSpecRef": {
                    "graphId": "research-review",
                    "version": 1,
                    "contentHash": "sha256:0123456789abcdef",
                },
                "stateSchemaRef": {"schemaId": "halo.run-state", "version": 1},
                "executableAgentIds": [
                    "product-manager",
                    "technical-architect",
                    "fact-checker",
                ],
                "modelAssignments": [
                    {
                        "agentId": "product-manager",
                        "modelRef": {
                            "providerId": "toapis",
                            "modelId": "claude-sonnet",
                        },
                    },
                    {
                        "agentId": "fact-checker",
                        "modelRef": {
                            "providerId": "deepseek-official",
                            "modelId": "deepseek-reasoner",
                        },
                    },
                ],
                "mode": "grounded",
                "budget": {
                    "maxAgentMessages": 20,
                    "maxModelCalls": 12,
                    "maxWallClockSeconds": 300,
                },
                "stateSlice": {
                    "authorizedMessageIds": ["message-01"],
                    "authorizedAssetIds": [],
                },
            },
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertTrue(body["valid"])
        self.assertEqual(body["executionOwner"], "gateway")
        self.assertEqual(body["offloadId"], "offload-01")
        self.assertFalse(body["started"])

    def test_orchestration_request_rejects_model_for_unapproved_agent(self) -> None:
        response = self.client.post(
            "/v1/orchestration/validate",
            json={
                "offloadId": "offload-02",
                "clientCommandId": "command-02",
                "graphSpecRef": {
                    "graphId": "research-review",
                    "version": 1,
                    "contentHash": "sha256:0123456789abcdef",
                },
                "stateSchemaRef": {"schemaId": "halo.run-state", "version": 1},
                "executableAgentIds": ["fact-checker"],
                "modelAssignments": [
                    {
                        "agentId": "unapproved-agent",
                        "modelRef": {
                            "providerId": "openai",
                            "modelId": "gpt-5",
                        },
                    }
                ],
                "mode": "grounded",
                "budget": {
                    "maxAgentMessages": 20,
                    "maxModelCalls": 12,
                    "maxWallClockSeconds": 300,
                },
                "stateSlice": {
                    "authorizedMessageIds": ["message-01"],
                    "authorizedAssetIds": [],
                },
            },
        )

        self.assertEqual(response.status_code, 422)

    def test_publish_gate_blocks_unverified_facts(self) -> None:
        response = self.client.post(
            "/v1/verification/publishability",
            json={
                "claims": [
                    {
                        "id": "claim-01",
                        "runId": "run-01",
                        "authorAgentId": "product-manager",
                        "text": "The market grew by 20 percent.",
                        "type": "fact",
                        "risk": "medium",
                        "evidenceRefIds": [],
                        "verificationStatus": "unverified",
                    }
                ],
                "evidence": [],
                "verifierResults": [],
            },
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json(),
            {
                "publishable": False,
                "blockedClaimIds": ["claim-01"],
                "reasons": ["unverified_fact"],
            },
        )

    def test_publish_gate_accepts_supported_fact_with_traceable_evidence(self) -> None:
        response = self.client.post(
            "/v1/verification/publishability",
            json={
                "claims": [
                    {
                        "id": "claim-02",
                        "runId": "run-01",
                        "authorAgentId": "fact-checker",
                        "text": "The test suite completed successfully.",
                        "type": "fact",
                        "risk": "low",
                        "evidenceRefIds": ["evidence-01"],
                        "verificationStatus": "supported",
                        "verifierRunId": "verify-01",
                    }
                ],
                "evidence": [
                    {
                        "id": "evidence-01",
                        "sourceType": "test_result",
                        "sourceId": "test-run-01",
                        "sourceTitle": "Backend tests",
                        "locator": "tests/",
                        "capturedAt": "2026-07-29T10:00:00Z",
                        "contentHash": "sha256:fedcba9876543210",
                        "excerpt": "7 tests passed",
                        "trustTier": "E4",
                    }
                ],
                "verifierResults": [
                    {
                        "runId": "verify-01",
                        "claimId": "claim-02",
                        "status": "supported",
                        "supportingEvidenceRefIds": ["evidence-01"],
                        "conflictingEvidenceRefIds": [],
                        "notes": "Reproducible test result.",
                    }
                ],
            },
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json(),
            {"publishable": True, "blockedClaimIds": [], "reasons": []},
        )


if __name__ == "__main__":
    unittest.main()
