import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:halo_mobile/experts/expert_prompt_package.dart';

void main() {
  test('expert profile is deeply immutable and JSON round-trips', () {
    final constraints = <String>['Do not invent evidence.'];
    final capabilities = <String>['requirements.analysis'];
    final profile = _profile(
      constraints: constraints,
      capabilities: capabilities,
    );

    constraints.add('Mutated after construction.');
    capabilities.add('unsafe.capability');
    final encoded = jsonEncode(profile.toJson());
    final decoded = ExpertProfile.fromJson(
      jsonDecode(encoded) as Map<String, Object?>,
    );

    expect(profile.promptPackage.constraints, ['Do not invent evidence.']);
    expect(profile.routingCard.capabilities, ['requirements.analysis']);
    expect(decoded.toJson(), profile.toJson());
    expect(
      () => profile.promptPackage.constraints.add('mutation'),
      throwsUnsupportedError,
    );
    expect(
      () => profile.outputSchema.fields['Extra'] = OutputValueType.string,
      throwsUnsupportedError,
    );
  });

  test('strict decoding rejects unknown fields and secret material', () {
    final json = _profile().toJson()..['unexpected'] = true;

    expect(() => ExpertProfile.fromJson(json), throwsFormatException);
    expect(
      () => PromptPackage(
        system: 'Authorization: Bearer abcdefghijklmnop',
        personality: 'Careful',
        constraints: const ['Stay grounded.'],
        guards: const {PromptGuard.noFabrication},
      ),
      throwsArgumentError,
    );
    expect(
      () => ToolPolicy(
        allowedTools: const ['web.search'],
        approvalRequiredTools: const ['web.search'],
        deniedTools: const ['web.search'],
      ),
      throwsArgumentError,
    );
  });

  test(
    'directional evidence contracts cannot downgrade to structural policy',
    () {
      final directionalSchema = _factSchema();
      const trustedGuards = {
        PromptGuard.roleIntegrity,
        PromptGuard.evidenceBoundaries,
        PromptGuard.noFabrication,
        PromptGuard.abstainWithoutEvidence,
      };

      expect(
        () => _profile(
          outputSchema: directionalSchema,
          validationPolicy: ExpertValidationPolicy.structural,
          guards: trustedGuards,
        ),
        throwsArgumentError,
        reason: 'direct construction must reject a structural downgrade',
      );

      final trusted = _profile(
        outputSchema: directionalSchema,
        validationPolicy: ExpertValidationPolicy.trustedEvidence,
        guards: trustedGuards,
      );
      final downgradedJson = trusted.toJson()
        ..['validationPolicy'] = ExpertValidationPolicy.structural.name;
      expect(
        () => ExpertProfile.fromJson(downgradedJson),
        throwsArgumentError,
        reason: 'JSON decoding must reject a structural downgrade',
      );

      final fakeEvidence = EvidenceItem(
        sourceId: 'untrusted-source',
        ref: 'https://fake.invalid/report',
        quoteOrSummary: 'A fabricated supporting statement.',
        receiptId: 'rcpt_AAAAAAAAAAAAAAAAAAAAAA',
        receiptToken: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        stance: EvidenceStance.supports,
      );
      final validator = _trustedValidator(
        directionalSchema,
        EvidenceTrustRegistry.forTesting(
          utf8.encode('0123456789abcdef0123456789abcdef'),
          clock: _MutableEvidenceClock(DateTime.utc(2026, 7, 29, 10)),
        ),
      );
      expect(
        validator.validate(
          {
            'Claim': 'A claim.',
            'Evidence': [fakeEvidence.toJson()],
            'Verdict': 'supported',
            'Confidence': 60,
          },
          ExpertValidationContext(
            runId: 'run-policy',
            turnId: 'turn-1',
            outputId: 'output-1',
          ),
        ),
        isFalse,
        reason: 'directional evidence must never reach the structural branch',
      );
    },
  );

  test('ordinary field names do not imply a directional evidence contract', () {
    final profile = _profile(
      outputSchema: OutputSchema(
        schemaId: 'editor-observations.v1',
        fields: const {
          'Evidence': OutputValueType.stringList,
          'Verdict': OutputValueType.string,
          'Verification': OutputValueType.verificationEnvelope,
        },
      ),
      validationPolicy: ExpertValidationPolicy.structural,
    );

    expect(profile.validationPolicy, ExpertValidationPolicy.structural);
    expect(
      StructuralExpertOutputValidator(
        profile: profile,
        verificationRegistry: null,
      ).preflight(const {
        'Evidence': ['The heading is inconsistent.'],
        'Verdict': 'Revise the heading.',
        'Verification': {
          'claimType': 'advice',
          'tense': 'proposed',
          'verified': false,
          'source': 'none',
          'proposedActions': [
            {
              'verb': 'review',
              'target': 'document-heading',
              'conditions': <String>[],
            },
          ],
          'executedFacts': <String>[],
        },
      }),
      isTrue,
    );
  });

  test('negative routing triggers override intents and capabilities', () {
    final card = RoutingCard(
      intents: const ['产品需求', 'roadmap'],
      capabilities: const ['requirements.analysis', 'prioritization'],
      negativeTriggers: const ['写代码', 'medical diagnosis'],
    );

    expect(
      card.matches(
        '请分析产品需求并写代码',
        requiredCapabilities: const {'requirements.analysis'},
      ),
      isFalse,
    );
    expect(card.excludes('请分析产品需求并写代码'), isTrue);
    expect(
      card.matches(
        '请分析产品需求优先级',
        requiredCapabilities: const {'requirements.analysis'},
      ),
      isTrue,
    );
    expect(
      card.matches(
        '请分析产品需求',
        requiredCapabilities: const {'source.verification'},
      ),
      isFalse,
    );
  });

  test('routing normalizes whitespace, token boundaries, and negation', () {
    final card = RoutingCard(
      intents: const ['产品需求', 'prd'],
      capabilities: const ['requirements.analysis'],
      negativeTriggers: const ['写代码'],
    );

    expect(card.matches('请做产品需求并写 代码'), isFalse);
    expect(card.matches('请做产品需求，不要写 代码'), isTrue);
    expect(card.matches('请做产品需求，不要帮我写代码'), isTrue);
    expect(card.matches('请做产品需求，不要麻烦继续帮我写代码'), isTrue);
    expect(card.excludes('别再写代码'), isFalse);
    expect(card.excludes('无需继续写代码'), isFalse);
    expect(card.matches('不需要产品需求分析'), isFalse);
    expect(card.matches('请识别产品需求中的风险'), isTrue);
    expect(card.matches('不需要识别产品需求中的风险'), isFalse);
    expect(card.matches('请告别产品需求'), isFalse);
    expect(card.matches('离别产品需求'), isFalse);
    expect(card.matches('aprdx'), isFalse);
    expect(card.matches('Need PRD now'), isTrue);
  });

  test('routing returns clarification for ambiguous double negation', () {
    final card = RoutingCard(
      intents: const ['产品需求'],
      capabilities: const ['requirements.analysis'],
      negativeTriggers: const ['写代码'],
    );

    expect(card.matches('请做产品需求，不要在这个需求里继续写代码'), isTrue);
    expect(card.matches('请做产品需求，别在这个阶段再写代码'), isTrue);
    expect(card.excludes('不是要写代码'), isFalse);
    expect(card.excludes('并非要写代码'), isFalse);
    expect(card.evaluate('不是不需要产品需求分析'), RoutingOutcome.needsClarification);
    expect(card.evaluate('不是不要写代码'), RoutingOutcome.needsClarification);
    expect(card.matches('不是不需要产品需求分析'), isFalse);
  });

  test(
    'tool policy exposes deterministic allow, deny, and approval decisions',
    () {
      final policy = ToolPolicy(
        allowedTools: const ['web.search', 'artifact.read'],
        approvalRequiredTools: const ['artifact.read'],
        deniedTools: const ['shell.execute'],
      );

      expect(policy.decisionFor('web.search'), ToolDecision.allowed);
      expect(
        policy.decisionFor('artifact.read'),
        ToolDecision.requiresApproval,
      );
      expect(policy.decisionFor('shell.execute'), ToolDecision.denied);
      expect(policy.decisionFor('unknown.tool'), ToolDecision.denied);
    },
  );

  test('fact-check output schema requires abstention without evidence', () {
    final schema = _factSchema();
    const claim = 'The release shipped.';
    final issued = _issueEvidence(
      claim: claim,
      ref: 'https://docs.acme.com/releases/42',
      quoteOrSummary: 'Version 42 shipped.',
      confidence: 90,
    );
    final evidence = issued.evidence;

    expect(
      schema.unsafeShapeOnly(const {
        'Claim': 'The release shipped.',
        'Evidence': <String>[],
        'Verdict': 'supported',
        'Confidence': 80,
      }),
      isFalse,
    );
    expect(
      schema.unsafeShapeOnly(const {
        'Claim': 'The release shipped.',
        'Evidence': <String>[],
        'Verdict': 'abstain',
        'Confidence': 0,
      }),
      isTrue,
    );
    expect(
      issued.validate(schema, {
        'Claim': claim,
        'Evidence': [evidence.toJson()],
        'Verdict': 'supported',
        'Confidence': 90,
      }),
      isTrue,
    );
    expect(
      issued.validate(schema, {
        'Claim': claim,
        'Evidence': [evidence.toJson()],
        'Verdict': 'supported',
        'Confidence': 101,
      }),
      isFalse,
    );
  });

  test('output schema validates structured evidence decoded from JSON', () {
    final schema = _factSchema();
    const claim = 'Shipped';
    final issued = _issueEvidence(
      claim: claim,
      ref: 'https://docs.acme.com/releases/42',
      quoteOrSummary: 'Version 42 shipped.',
      confidence: 90,
    );
    final evidence = issued.evidence;
    final decoded =
        jsonDecode(
              jsonEncode({
                'Claim': claim,
                'Evidence': [evidence.toJson()],
                'Verdict': 'supported',
                'Confidence': 90,
              }),
            )
            as Map<String, Object?>;

    expect(issued.validate(schema, decoded), isTrue);
  });

  test('structured evidence is locatable and JSON round-trips', () {
    const claim = 'Version 42 shipped.';
    final issued = _issueEvidence(
      claim: claim,
      ref: 'https://docs.acme.com/releases/42',
      quoteOrSummary: 'Version 42 was released on July 29.',
    );
    final evidence = issued.evidence;
    final decoded = EvidenceItem.fromJson(
      jsonDecode(jsonEncode(evidence.toJson())) as Map<String, Object?>,
    );
    final schema = OutputSchema(
      schemaId: 'claim-verification.v1',
      fields: const {
        'Claim': OutputValueType.string,
        'Evidence': OutputValueType.evidenceList,
        'Verdict': OutputValueType.string,
        'Confidence': OutputValueType.integer,
      },
      allowedVerdicts: const {'supported', 'contradicted', 'abstain'},
      evidenceField: 'Evidence',
      verdictField: 'Verdict',
      abstainVerdict: 'abstain',
    );

    expect(decoded.toJson(), evidence.toJson());
    expect(
      issued.validate(schema, {
        'Claim': claim,
        'Evidence': [evidence.toJson()],
        'Verdict': 'supported',
        'Confidence': 95,
      }),
      isTrue,
    );
  });

  test('structured evidence rejects empty and trust-me references', () {
    for (final ref in ['', 'trust-me']) {
      expect(
        () => EvidenceItem(
          sourceId: 'release-notes',
          ref: ref,
          quoteOrSummary: 'A purported release statement.',
          receiptId: _opaqueReceiptId,
          receiptToken: _opaqueReceiptToken,
          stance: EvidenceStance.supports,
        ),
        throwsArgumentError,
        reason: ref,
      );
    }
  });

  test(
    'identifier screening rejects opaque alphabetic and base64url tokens',
    () {
      for (final identifier in [
        'qzmxncbvalskdjfhgpoiuytrewqzmxncbvalskdjfhgpoiuy',
        'QZMXNCBVALSKDJFHGPOIUYTREWQZMXNCBVALSKDJFHGPOIUY',
        'QzMXn_cbVa-LsKdjfHgPoIuYtReWqZmxNCbvAlSkDJfHg',
      ]) {
        expect(
          () => RoutingCard(
            capabilities: [identifier],
            intents: const ['需求'],
            negativeTriggers: const ['写代码'],
          ),
          throwsArgumentError,
          reason: identifier,
        );
      }
    },
  );

  test('evidence references reject credential-bearing URI components', () {
    for (final ref in [
      'https://user:password@docs.acme.com/releases/42',
      'https://docs.acme.com/releases/42?signature=ordinary',
      'https://docs.acme.com/releases/42?access_token=ordinary',
      'https://docs.acme.com/releases/42?page=%73%6b%2Dabcdefghijklmnop',
      'https://docs.acme.com/releases/42#auth=ordinary',
      'https://docs.acme.com/releases/42#%73%6b%2Dabcdefghijklmnop',
      'artifact://release/42?api_key=ordinary',
    ]) {
      expect(
        () => EvidenceItem(
          sourceId: 'release-notes',
          ref: ref,
          quoteOrSummary: 'A release statement.',
          receiptId: _opaqueReceiptId,
          receiptToken: _opaqueReceiptToken,
          stance: EvidenceStance.supports,
        ),
        throwsArgumentError,
        reason: ref,
      );
    }
  });

  test('evidence references recursively reject encoded secrets', () {
    for (final ref in [
      'https://docs.acme.com/releases/42?access%255Ftoken=ordinary',
      'https://docs.acme.com/releases/42?page=%252573%25256b%25252Dabcdefghijklmnop',
      'https://docs.acme.com/releases/42#%252573%25256b%25252Dabcdefghijklmnop',
      'https://docs.acme.com/releases/42?page=%25ZZ',
    ]) {
      expect(
        () => EvidenceItem(
          sourceId: 'release-notes',
          ref: ref,
          quoteOrSummary: 'A release statement.',
          receiptId: _opaqueReceiptId,
          receiptToken: _opaqueReceiptToken,
          stance: EvidenceStance.supports,
        ),
        throwsArgumentError,
        reason: ref,
      );
    }
  });

  test('fabricated URL is untrusted without a verified receipt', () {
    const claim = 'A claim';
    final evidence = EvidenceItem(
      sourceId: 'release-notes',
      ref: 'https://fake.invalid/source',
      quoteOrSummary: 'A fabricated statement.',
      receiptId: _opaqueReceiptId,
      receiptToken: _opaqueReceiptToken,
      stance: EvidenceStance.supports,
    );

    expect(jsonEncode(evidence.toJson()), isNot(contains('sk-')));
    final output = {
      'Claim': claim,
      'Evidence': [evidence.toJson()],
      'Verdict': 'supported',
      'Confidence': 50,
    };
    expect(_factSchema().unsafeShapeOnly(output), isTrue);
    expect(
      _trustedValidator(
        _factSchema(),
        EvidenceTrustRegistry.forTesting(
          utf8.encode('0123456789abcdef0123456789abcdef'),
          clock: _MutableEvidenceClock(DateTime.utc(2026, 7, 29, 10)),
        ),
      ).validate(
        output,
        ExpertValidationContext(
          runId: 'run-test',
          turnId: 'turn-test',
          outputId: 'output-test',
        ),
      ),
      isFalse,
    );
  });

  test('identifier fields reject secrets and high-entropy values', () {
    expect(
      () => RoutingCard(
        capabilities: const ['sk-abcdefghijklmnop'],
        intents: const ['需求'],
        negativeTriggers: const ['写代码'],
      ),
      throwsArgumentError,
    );
    expect(
      () => ToolPolicy(
        allowedTools: const ['sk-abcdefghijklmnop'],
        approvalRequiredTools: const [],
        deniedTools: const [],
      ),
      throwsArgumentError,
    );
    expect(
      () => OutputSchema(
        schemaId: 'sk-abcdefghijklmnop',
        fields: const {'Result': OutputValueType.string},
      ),
      throwsArgumentError,
    );
    expect(
      () => RoutingCard(
        capabilities: const ['a9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4'],
        intents: const ['需求'],
        negativeTriggers: const ['写代码'],
      ),
      throwsArgumentError,
    );
    expect(
      () => EvidenceItem(
        sourceId: 'sk-abcdefghijklmnop',
        ref: 'artifact://requirements/1',
        quoteOrSummary: 'A requirement',
        receiptId: _opaqueReceiptId,
        receiptToken: _opaqueReceiptToken,
        stance: EvidenceStance.supports,
      ),
      throwsArgumentError,
    );

    final json = _profile().toJson();
    json['id'] = 'sk-abcdefghijklmnop';
    expect(
      () => ExpertProfile.fromJson(json),
      throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
    );
  });

  test('fromJson rejects duplicate enum-set values', () {
    final json = _profile().promptPackage.toJson();
    json['guards'] = ['roleIntegrity', 'roleIntegrity'];

    expect(() => PromptPackage.fromJson(json), throwsFormatException);
  });

  test('fromJson rejects duplicate allowedVerdicts', () {
    final schema = OutputSchema(
      schemaId: 'fact_check',
      fields: const {
        'Claim': OutputValueType.string,
        'Verdict': OutputValueType.string,
        'Evidence': OutputValueType.evidenceList,
      },
      allowedVerdicts: const {'supported', 'contradicted', 'abstain'},
      verdictField: 'Verdict',
      evidenceField: 'Evidence',
      abstainVerdict: 'abstain',
    );
    final json = schema.toJson();
    json['allowedVerdicts'] = [
      'supported',
      'supported',
      'contradicted',
      'abstain',
    ];

    expect(() => OutputSchema.fromJson(json), throwsFormatException);
  });

  test('directional evidence contract requires an explicit Claim field', () {
    expect(
      () => OutputSchema(
        schemaId: 'fact_check',
        fields: const {
          'Verdict': OutputValueType.string,
          'Evidence': OutputValueType.evidenceList,
        },
        allowedVerdicts: const {'supported', 'contradicted', 'abstain'},
        verdictField: 'Verdict',
        evidenceField: 'Evidence',
        abstainVerdict: 'abstain',
      ),
      throwsArgumentError,
    );
  });

  test('directional verdicts reject malformed evidence items', () {
    final schema = OutputSchema(
      schemaId: 'claim-verification.v1',
      fields: const {
        'Claim': OutputValueType.string,
        'Evidence': OutputValueType.evidenceList,
        'Verdict': OutputValueType.string,
        'Confidence': OutputValueType.integer,
      },
      allowedVerdicts: const {'supported', 'contradicted', 'abstain'},
      evidenceField: 'Evidence',
      verdictField: 'Verdict',
      abstainVerdict: 'abstain',
    );

    expect(
      schema.unsafeShapeOnly(const {
        'Claim': 'Version 42 shipped.',
        'Evidence': <Object?>[
          {
            'sourceId': 'release-notes',
            'ref': 'trust-me',
            'quoteOrSummary': 'No locatable source.',
          },
        ],
        'Verdict': 'contradicted',
        'Confidence': 80,
      }),
      isFalse,
    );
  });

  test('directional verdicts require verified claim-bound receipts', () {
    const claim = 'Version 42 shipped.';
    final issued = _issueEvidence(
      claim: claim,
      ref: 'https://docs.acme.com/releases/42',
      quoteOrSummary: 'Version 42 shipped.',
    );
    final schema = _factSchema();
    final output = {
      'Claim': claim,
      'Evidence': [issued.evidence.toJson()],
      'Verdict': 'supported',
      'Confidence': 95,
    };

    expect(schema.unsafeShapeOnly(output), isTrue);
    expect(issued.validate(schema, output), isTrue);
  });

  test(
    'receipt verification rejects unknown, duplicate, and tampered data',
    () {
      const claim = 'Version 42 shipped.';
      final issued = _issueEvidence(
        claim: claim,
        ref: 'https://fabricated.example.net/releases/42',
        quoteOrSummary: 'A purported release statement.',
        confidence: 80,
      );
      final valid = issued.evidence;
      final schema = _factSchema();
      Map<String, Object?> output(
        List<EvidenceItem> evidence, {
        String verdict = 'supported',
      }) => {
        'Claim': claim,
        'Evidence': evidence.map((value) => value.toJson()).toList(),
        'Verdict': verdict,
        'Confidence': 80,
      };

      expect(
        _trustedValidator(
          schema,
          EvidenceTrustRegistry.forTesting(
            utf8.encode('0123456789abcdef0123456789abcdef'),
            clock: _MutableEvidenceClock(DateTime.utc(2026, 7, 29, 10)),
          ),
        ).validate(output([valid]), issued.context),
        isFalse,
        reason: 'unknown receipt',
      );
      expect(
        issued.validate(schema, output([valid, valid])),
        isFalse,
        reason: 'duplicate receipt',
      );

      expect(
        issued.validate(schema, {
          ...output([valid]),
          'Claim': 'Another claim',
        }),
        isFalse,
        reason: 'wrong claim digest',
      );

      for (final tampered in [
        _copyEvidence(valid, stance: EvidenceStance.contradicts),
        _copyEvidence(valid, quoteOrSummary: 'The summary was changed.'),
        _copyEvidence(valid, sourceId: 'other-source'),
        _copyEvidence(valid, ref: 'artifact://other/source'),
        _copyEvidence(valid, receiptId: 'rcpt_BBBBBBBBBBBBBBBBBBBBBB'),
        _copyEvidence(
          valid,
          receiptToken:
              '${valid.receiptToken.substring(0, 42)}'
              '${valid.receiptToken.endsWith('A') ? 'B' : 'A'}',
        ),
      ]) {
        expect(
          issued.validate(schema, output([tampered])),
          isFalse,
          reason: tampered.toJson().toString(),
        );
      }

      expect(
        issued.validate(
          schema,
          output([
            _copyEvidence(
              valid,
              quoteOrSummary: '  A  purported release statement. ',
            ),
          ]),
        ),
        isFalse,
        reason: 'raw canonical UTF-8 must preserve whitespace differences',
      );
    },
  );

  test('abstain verifies every non-empty receipt but ignores stance', () {
    const claim = 'Version 42 shipped.';
    final issued = _issueEvidence(
      claim: claim,
      ref: 'artifact://release-notes/42',
      quoteOrSummary: 'The release status is disputed.',
      stance: EvidenceStance.contradicts,
      verdict: 'abstain',
      confidence: 0,
    );
    final output = {
      'Claim': claim,
      'Evidence': [issued.evidence.toJson()],
      'Verdict': 'abstain',
      'Confidence': 0,
    };

    expect(_factSchema().unsafeShapeOnly(output), isTrue);
    expect(issued.validate(_factSchema(), output), isTrue);
    expect(
      issued.validate(_factSchema(), {
        ...output,
        'Evidence': [
          _copyEvidence(
            issued.evidence,
            quoteOrSummary: 'An unverified replacement.',
          ).toJson(),
        ],
      }),
      isFalse,
    );
  });

  test('contradicted verdict accepts only contradicting receipts', () {
    const claim = 'Version 42 shipped.';
    final schema = _factSchema();
    Map<String, Object?> output(EvidenceItem evidence) => {
      'Claim': claim,
      'Evidence': [evidence.toJson()],
      'Verdict': 'contradicted',
      'Confidence': 80,
    };
    final supports = _issueEvidence(
      claim: claim,
      ref: 'artifact://release-notes/42',
      quoteOrSummary: 'The release was cancelled.',
      verdict: 'contradicted',
      confidence: 80,
    );
    final contradicts = _issueEvidence(
      claim: claim,
      ref: 'artifact://release-notes/42',
      quoteOrSummary: 'The release was cancelled.',
      stance: EvidenceStance.contradicts,
      verdict: 'contradicted',
      confidence: 80,
    );

    expect(supports.validate(schema, output(supports.evidence)), isFalse);
    expect(contradicts.validate(schema, output(contradicts.evidence)), isTrue);
  });

  test('authority receipts are opaque, registered, and tamper evident', () {
    const claim = 'Version 42 shipped.';
    final clock = _MutableEvidenceClock(DateTime.utc(2026, 7, 29, 10));
    final context = ExpertValidationContext(
      runId: 'run-42',
      turnId: 'turn-7',
      outputId: 'output-1',
    );
    final registry = EvidenceTrustRegistry.forTesting(
      utf8.encode('0123456789abcdef0123456789abcdef'),
      clock: clock,
    );
    final unsignedOutput = {
      'Claim': claim,
      'Evidence': [
        {
          'sourceId': 'release-notes',
          'ref': 'artifact://release-notes/42',
          'quoteOrSummary': 'Version 42 shipped.',
          'stance': EvidenceStance.supports.name,
        },
      ],
      'Verdict': 'supported',
      'Confidence': 95,
    };
    final receipt = registry.issue(
      expertId: 'fact-checker',
      schemaId: 'claim-verification.v1',
      profileVersion: 1,
      context: context,
      validFor: const Duration(minutes: 5),
      outputDigest: expertOutputDigestFor(unsignedOutput),
      claimDigest: claimDigestFor(claim),
      sourceId: 'release-notes',
      ref: 'artifact://release-notes/42',
      stance: EvidenceStance.supports,
      quoteOrSummary: 'Version 42 shipped.',
    );
    final evidence = EvidenceItem(
      sourceId: 'release-notes',
      ref: 'artifact://release-notes/42',
      quoteOrSummary: 'Version 42 shipped.',
      receiptId: receipt.receiptId,
      receiptToken: receipt.token,
      stance: EvidenceStance.supports,
    );
    final output = {
      'Claim': claim,
      'Evidence': [evidence.toJson()],
      'Verdict': 'supported',
      'Confidence': 95,
    };

    expect(evidence.toJson().keys, {
      'sourceId',
      'ref',
      'quoteOrSummary',
      'receiptId',
      'receiptToken',
      'stance',
    });
    expect(registry.toString(), isNot(contains('0123456789abcdef')));
    expect(receipt.toString(), isNot(contains(receipt.token)));
    expect(
      _trustedValidator(_factSchema(), registry).validate(output, context),
      isTrue,
    );
  });

  test(
    'trusted validator binds registry, audience, expiry, and consumption',
    () {
      final clock = _MutableEvidenceClock(DateTime.utc(2026, 7, 29, 10));
      final context = ExpertValidationContext(
        runId: 'run-42',
        turnId: 'turn-7',
        outputId: 'output-1',
      );
      final registry = EvidenceTrustRegistry.forTesting(
        utf8.encode('0123456789abcdef0123456789abcdef'),
        clock: clock,
      );
      const claim = 'Version 42 shipped.';
      final unsignedOutput = {
        'Claim': claim,
        'Evidence': [
          {
            'sourceId': 'release-notes',
            'ref': 'artifact://release-notes/42',
            'quoteOrSummary': 'Version 42 shipped.',
            'stance': EvidenceStance.supports.name,
          },
        ],
        'Verdict': 'supported',
        'Confidence': 95,
      };
      final receipt = registry.issue(
        expertId: 'fact-checker',
        schemaId: 'claim-verification.v1',
        profileVersion: 1,
        context: context,
        validFor: const Duration(minutes: 5),
        outputDigest: expertOutputDigestFor(unsignedOutput),
        claimDigest: claimDigestFor(claim),
        sourceId: 'release-notes',
        ref: 'artifact://release-notes/42',
        stance: EvidenceStance.supports,
        quoteOrSummary: 'Version 42 shipped.',
      );
      final evidence = EvidenceItem(
        sourceId: 'release-notes',
        ref: 'artifact://release-notes/42',
        quoteOrSummary: 'Version 42 shipped.',
        receiptId: receipt.receiptId,
        receiptToken: receipt.token,
        stance: EvidenceStance.supports,
      );
      final output = {
        'Claim': claim,
        'Evidence': [evidence.toJson()],
        'Verdict': 'supported',
        'Confidence': 95,
      };
      final validator = _trustedValidator(_factSchema(), registry);

      expect(validator.validate(output, context), isTrue);
      expect(validator.validate(output, context), isFalse);
      expect(
        validator.validate({...output, 'Confidence': 94}, context),
        isFalse,
      );
      for (final replayContext in [
        ExpertValidationContext(
          runId: 'run-43',
          turnId: 'turn-7',
          outputId: 'output-1',
        ),
        ExpertValidationContext(
          runId: 'run-42',
          turnId: 'turn-8',
          outputId: 'output-1',
        ),
        ExpertValidationContext(
          runId: 'run-42',
          turnId: 'turn-7',
          outputId: 'output-2',
        ),
      ]) {
        expect(
          validator.validate(output, replayContext),
          isFalse,
          reason:
              '${replayContext.runId}/'
              '${replayContext.turnId}/'
              '${replayContext.outputId}',
        );
      }
      final wrongRegistry = EvidenceTrustRegistry.forTesting(
        utf8.encode('abcdef0123456789abcdef0123456789'),
        clock: clock,
      );
      expect(
        _trustedValidator(
          _factSchema(),
          wrongRegistry,
        ).validate(output, context),
        isFalse,
      );
      clock.advance(const Duration(minutes: 6));
      expect(validator.validate(output, context), isFalse);
    },
  );
}

const _opaqueReceiptId = 'rcpt_AAAAAAAAAAAAAAAAAAAAAA';
const _opaqueReceiptToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

class _MutableEvidenceClock implements EvidenceClock {
  _MutableEvidenceClock(this._now);

  DateTime _now;

  void advance(Duration duration) {
    _now = _now.add(duration);
  }

  @override
  DateTime now() => _now;
}

class _IssuedEvidence {
  const _IssuedEvidence(this.evidence, this.registry, this.context);

  final EvidenceItem evidence;
  final EvidenceTrustRegistry registry;
  final ExpertValidationContext context;

  bool validate(OutputSchema schema, Map<String, Object?> output) =>
      _trustedValidator(schema, registry).validate(output, context);
}

_IssuedEvidence _issueEvidence({
  required String claim,
  required String ref,
  required String quoteOrSummary,
  String sourceId = 'release-notes',
  EvidenceStance stance = EvidenceStance.supports,
  String verdict = 'supported',
  int confidence = 95,
}) {
  final clock = _MutableEvidenceClock(DateTime.utc(2026, 7, 29, 10));
  final context = ExpertValidationContext(
    runId: 'run-test',
    turnId: 'turn-test',
    outputId: 'output-test',
  );
  final registry = EvidenceTrustRegistry.forTesting(
    utf8.encode('0123456789abcdef0123456789abcdef'),
    clock: clock,
  );
  final unsignedOutput = {
    'Claim': claim,
    'Evidence': [
      {
        'sourceId': sourceId,
        'ref': ref,
        'quoteOrSummary': quoteOrSummary,
        'stance': stance.name,
      },
    ],
    'Verdict': verdict,
    'Confidence': confidence,
  };
  final receipt = registry.issue(
    expertId: 'fact-checker',
    schemaId: 'claim-verification.v1',
    profileVersion: 1,
    context: context,
    validFor: const Duration(minutes: 5),
    outputDigest: expertOutputDigestFor(unsignedOutput),
    claimDigest: claimDigestFor(claim),
    sourceId: sourceId,
    ref: ref,
    stance: stance,
    quoteOrSummary: quoteOrSummary,
  );
  return _IssuedEvidence(
    EvidenceItem(
      sourceId: sourceId,
      ref: ref,
      quoteOrSummary: quoteOrSummary,
      receiptId: receipt.receiptId,
      receiptToken: receipt.token,
      stance: stance,
    ),
    registry,
    context,
  );
}

EvidenceItem _copyEvidence(
  EvidenceItem source, {
  String? sourceId,
  String? ref,
  String? quoteOrSummary,
  String? receiptId,
  String? receiptToken,
  EvidenceStance? stance,
}) => EvidenceItem(
  sourceId: sourceId ?? source.sourceId,
  ref: ref ?? source.ref,
  quoteOrSummary: quoteOrSummary ?? source.quoteOrSummary,
  receiptId: receiptId ?? source.receiptId,
  receiptToken: receiptToken ?? source.receiptToken,
  stance: stance ?? source.stance,
);

OutputSchema _factSchema() => OutputSchema(
  schemaId: 'claim-verification.v1',
  fields: const {
    'Claim': OutputValueType.string,
    'Evidence': OutputValueType.evidenceList,
    'Verdict': OutputValueType.string,
    'Confidence': OutputValueType.integer,
  },
  allowedVerdicts: const {'supported', 'contradicted', 'abstain'},
  evidenceField: 'Evidence',
  verdictField: 'Verdict',
  abstainVerdict: 'abstain',
);

TrustedExpertOutputValidator _trustedValidator(
  OutputSchema schema,
  EvidenceTrustRegistry registry,
) => TrustedExpertOutputValidator(
  schema: schema,
  trustRegistry: registry,
  expertId: 'fact-checker',
  schemaId: schema.schemaId,
  profileVersion: 1,
);

ExpertProfile _profile({
  List<String>? constraints,
  List<String>? capabilities,
  OutputSchema? outputSchema,
  ExpertValidationPolicy validationPolicy = ExpertValidationPolicy.structural,
  Set<PromptGuard> guards = const {
    PromptGuard.roleIntegrity,
    PromptGuard.evidenceBoundaries,
    PromptGuard.noFabrication,
  },
}) {
  return ExpertProfile(
    id: 'product-manager',
    displayName: '产品经理',
    description: 'Turns ambiguous product goals into testable decisions.',
    version: 1,
    promptPackage: PromptPackage(
      system: 'Act only as the assigned product manager.',
      personality: 'Structured, candid, and user-centered.',
      constraints: constraints ?? const ['Do not invent evidence.'],
      guards: guards,
    ),
    routingCard: RoutingCard(
      intents: const ['产品需求'],
      capabilities: capabilities ?? const ['requirements.analysis'],
      negativeTriggers: const ['写代码'],
    ),
    toolPolicy: ToolPolicy(
      allowedTools: const ['web.search'],
      approvalRequiredTools: const [],
      deniedTools: const ['shell.execute'],
    ),
    outputSchema:
        outputSchema ??
        OutputSchema(
          schemaId: 'product-brief.v1',
          fields: const {
            'Problem': OutputValueType.string,
            'Recommendation': OutputValueType.string,
          },
        ),
    validationPolicy: validationPolicy,
    memoryPolicy: MemoryPolicy(
      readableScopes: const {
        MemoryScope.conversationContext,
        MemoryScope.userProvidedReferences,
      },
      retention: MemoryRetention.session,
    ),
    evaluationCases: [
      EvaluationCase(
        id: 'product-requirements',
        input: '把模糊想法整理成产品需求',
        shouldRoute: true,
        expectedBehaviors: const ['Ask for missing success criteria.'],
        forbiddenBehaviors: const ['Invent user research.'],
      ),
    ],
  );
}
