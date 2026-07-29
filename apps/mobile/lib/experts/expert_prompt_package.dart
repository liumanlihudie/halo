import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

enum PromptGuard {
  roleIntegrity,
  evidenceBoundaries,
  noFabrication,
  abstainWithoutEvidence,
}

enum ToolDecision { allowed, requiresApproval, denied }

enum RoutingOutcome { match, noMatch, needsClarification }

enum OutputValueType { string, stringList, evidenceList, integer, boolean }

enum MemoryScope {
  conversationContext,
  userProvidedReferences,
  verifiedFacts,
  sessionScratchpad,
}

enum MemoryRetention { none, session }

enum EvidenceStance { supports, contradicts }

enum ExpertValidationPolicy { structural, trustedEvidence }

String claimDigestFor(String claim) {
  _validateText(claim, 'claim', maximumLength: 4096);
  return sha256.convert(utf8.encode(claim)).toString();
}

@immutable
class EvidenceReceipt {
  const EvidenceReceipt._(this.receiptId, this.token);

  final String receiptId;
  final String token;

  @override
  String toString() => 'EvidenceReceipt(receiptId: $receiptId)';
}

abstract interface class EvidenceClock {
  DateTime now();
}

class SystemEvidenceClock implements EvidenceClock {
  const SystemEvidenceClock();

  @override
  DateTime now() => DateTime.now().toUtc();
}

@immutable
class ExpertValidationContext {
  ExpertValidationContext({
    required this.runId,
    required this.turnId,
    required this.outputId,
  }) {
    _validateText(runId, 'runId', maximumLength: 128);
    _validateText(turnId, 'turnId', maximumLength: 128);
    _validateText(outputId, 'outputId', maximumLength: 128);
  }

  final String runId;
  final String turnId;
  final String outputId;

  String get _audience => jsonEncode([runId, turnId, outputId]);
}

/// Trust boundary: model-produced JSON is untrusted. This registry must be
/// created once by the trusted application composition root and bound to a
/// [TrustedExpertOutputValidator]. Never select a registry per model output.
class EvidenceTrustRegistry {
  EvidenceTrustRegistry._(List<int> key, this._random, this._clock)
    : _key = List<int>.unmodifiable(key);

  factory EvidenceTrustRegistry.secure({
    EvidenceClock clock = const SystemEvidenceClock(),
  }) {
    final random = math.Random.secure();
    return EvidenceTrustRegistry._(
      List<int>.generate(32, (_) => random.nextInt(256)),
      random,
      clock,
    );
  }

  @visibleForTesting
  factory EvidenceTrustRegistry.forTesting(
    List<int> key, {
    required EvidenceClock clock,
  }) {
    if (key.length < 16) {
      throw ArgumentError.value(key, 'key', 'Must contain at least 16 bytes.');
    }
    return EvidenceTrustRegistry._(key, math.Random(0), clock);
  }

  final List<int> _key;
  final math.Random _random;
  final EvidenceClock _clock;
  final Map<String, _EvidenceTrustRecord> _records = {};

  EvidenceReceipt issue({
    required ExpertValidationContext context,
    required Duration validFor,
    required String claimDigest,
    required String sourceId,
    required String ref,
    required EvidenceStance stance,
    required String quoteOrSummary,
  }) {
    _validateClaimDigest(claimDigest, 'receipt.claimDigest');
    _validateIdentifier(sourceId, 'receipt.sourceId');
    _validateEvidenceRef(ref);
    _validateText(
      quoteOrSummary,
      'receipt.quoteOrSummary',
      maximumLength: 2048,
    );
    if (validFor <= Duration.zero) {
      throw ArgumentError.value(validFor, 'validFor', 'Must be positive.');
    }
    final issuedAt = _clock.now().toUtc();
    final expiresAt = issuedAt.add(validFor);
    final receiptId = 'rcpt_${_randomBase64Url(16)}';
    final token = _attestationToken(
      receiptId: receiptId,
      audience: context._audience,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      claimDigest: claimDigest,
      sourceId: sourceId,
      ref: ref,
      stance: stance,
      quoteOrSummary: quoteOrSummary,
    );
    _records[receiptId] = _EvidenceTrustRecord(
      receiptId: receiptId,
      token: token,
      audience: context._audience,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
    );
    return EvidenceReceipt._(receiptId, token);
  }

  bool verifyAndConsume({
    required List<EvidenceItem> evidence,
    required String claimDigest,
    required ExpertValidationContext context,
    required String outputDigest,
    EvidenceStance? requiredStance,
  }) {
    _validateClaimDigest(claimDigest, 'claimDigest');
    _validateClaimDigest(outputDigest, 'outputDigest');
    final now = _clock.now().toUtc();
    final records = <_EvidenceTrustRecord>[];
    final receiptIds = <String>{};
    for (final item in evidence) {
      final record = _records[item.receiptId];
      if (record == null ||
          !receiptIds.add(item.receiptId) ||
          record.audience != context._audience ||
          now.isBefore(record.issuedAt) ||
          !now.isBefore(record.expiresAt) ||
          (record.consumedOutputDigest != null &&
              record.consumedOutputDigest != outputDigest) ||
          (requiredStance != null && item.stance != requiredStance) ||
          !_constantTimeEquals(record.token, item.receiptToken)) {
        return false;
      }
      final expectedToken = _attestationToken(
        receiptId: item.receiptId,
        audience: record.audience,
        issuedAt: record.issuedAt,
        expiresAt: record.expiresAt,
        claimDigest: claimDigest,
        sourceId: item.sourceId,
        ref: item.ref,
        stance: item.stance,
        quoteOrSummary: item.quoteOrSummary,
      );
      if (!_constantTimeEquals(expectedToken, item.receiptToken)) return false;
      records.add(record);
    }
    for (final record in records) {
      record.consumedOutputDigest = outputDigest;
    }
    return true;
  }

  String _attestationToken({
    required String receiptId,
    required String audience,
    required DateTime issuedAt,
    required DateTime expiresAt,
    required String claimDigest,
    required String sourceId,
    required String ref,
    required EvidenceStance stance,
    required String quoteOrSummary,
  }) {
    final contentDigest = sha256
        .convert(utf8.encode(_normalizeEvidenceContent(quoteOrSummary)))
        .toString();
    final payload = jsonEncode([
      receiptId,
      audience,
      issuedAt.microsecondsSinceEpoch,
      expiresAt.microsecondsSinceEpoch,
      claimDigest,
      sourceId,
      ref,
      stance.name,
      contentDigest,
    ]);
    return base64Url
        .encode(Hmac(sha256, _key).convert(utf8.encode(payload)).bytes)
        .replaceAll('=', '');
  }

  String _randomBase64Url(int byteCount) => base64Url
      .encode(List<int>.generate(byteCount, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  @override
  String toString() => 'EvidenceTrustRegistry()';
}

class _EvidenceTrustRecord {
  _EvidenceTrustRecord({
    required this.receiptId,
    required this.token,
    required this.audience,
    required this.issuedAt,
    required this.expiresAt,
  });

  final String receiptId;
  final String token;
  final String audience;
  final DateTime issuedAt;
  final DateTime expiresAt;
  String? consumedOutputDigest;
}

@immutable
class EvidenceItem {
  EvidenceItem({
    required this.sourceId,
    required this.ref,
    required this.quoteOrSummary,
    required this.receiptId,
    required this.receiptToken,
    required this.stance,
  }) {
    _validateIdentifier(sourceId, 'evidence.sourceId');
    _validateEvidenceRef(ref);
    _validateText(
      quoteOrSummary,
      'evidence.quoteOrSummary',
      maximumLength: 2048,
    );
    if (_compactForSafety(quoteOrSummary).contains('trustme')) {
      throw ArgumentError.value(
        quoteOrSummary,
        'evidence.quoteOrSummary',
        'Unsupported trust assertion.',
      );
    }
    _validateReceiptId(receiptId);
    _validateReceiptToken(receiptToken);
  }

  factory EvidenceItem.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'sourceId',
      'ref',
      'quoteOrSummary',
      'receiptId',
      'receiptToken',
      'stance',
    });
    return EvidenceItem(
      sourceId: _readString(json, 'sourceId'),
      ref: _readString(json, 'ref'),
      quoteOrSummary: _readString(json, 'quoteOrSummary'),
      receiptId: _readString(json, 'receiptId'),
      receiptToken: _readString(json, 'receiptToken'),
      stance: _readEnum(json, 'stance', EvidenceStance.values),
    );
  }

  final String sourceId;
  final String ref;
  final String quoteOrSummary;
  final String receiptId;
  final String receiptToken;
  final EvidenceStance stance;

  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    'ref': ref,
    'quoteOrSummary': quoteOrSummary,
    'receiptId': receiptId,
    'receiptToken': receiptToken,
    'stance': stance.name,
  };
}

@immutable
class PromptPackage {
  PromptPackage({
    required this.system,
    required this.personality,
    required List<String> constraints,
    required Set<PromptGuard> guards,
  }) : constraints = _validatedStrings(
         constraints,
         field: 'constraints',
         requireNonEmpty: true,
       ),
       guards = Set<PromptGuard>.unmodifiable(
         _requireNonEmptySet(guards, 'guards'),
       ) {
    _validateText(system, 'system', maximumLength: 8192);
    _validateText(personality, 'personality', maximumLength: 2048);
  }

  factory PromptPackage.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {'system', 'personality', 'constraints', 'guards'});
    return PromptPackage(
      system: _readString(json, 'system'),
      personality: _readString(json, 'personality'),
      constraints: _readStringList(json, 'constraints'),
      guards: _readEnumSet(json, 'guards', PromptGuard.values),
    );
  }

  final String system;
  final String personality;
  final List<String> constraints;
  final Set<PromptGuard> guards;

  Map<String, Object?> toJson() => {
    'system': system,
    'personality': personality,
    'constraints': constraints.toList(),
    'guards': guards.map((value) => value.name).toList()..sort(),
  };

  String render() => [
    system,
    'Personality: $personality',
    'Constraints:',
    for (final constraint in constraints) '- $constraint',
  ].join('\n');
}

@immutable
class RoutingCard {
  RoutingCard({
    required List<String> intents,
    required List<String> capabilities,
    required List<String> negativeTriggers,
  }) : intents = _validatedStrings(
         intents,
         field: 'intents',
         requireNonEmpty: true,
       ),
       capabilities = _validatedIdentifiers(
         capabilities,
         field: 'capabilities',
         requireNonEmpty: true,
       ),
       negativeTriggers = _validatedStrings(
         negativeTriggers,
         field: 'negativeTriggers',
         requireNonEmpty: true,
       );

  factory RoutingCard.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {'intents', 'capabilities', 'negativeTriggers'});
    return RoutingCard(
      intents: _readStringList(json, 'intents'),
      capabilities: _readStringList(json, 'capabilities'),
      negativeTriggers: _readStringList(json, 'negativeTriggers'),
    );
  }

  final List<String> intents;
  final List<String> capabilities;
  final List<String> negativeTriggers;

  bool excludes(String request) => negativeTriggers.any(
    (trigger) =>
        _routingPhraseStatus(request, trigger) == _RoutingPhraseStatus.matched,
  );

  bool matches(String request, {Set<String> requiredCapabilities = const {}}) {
    return evaluate(request, requiredCapabilities: requiredCapabilities) ==
        RoutingOutcome.match;
  }

  RoutingOutcome evaluate(
    String request, {
    Set<String> requiredCapabilities = const {},
  }) {
    if (_normalizeRoutingText(request).isEmpty) return RoutingOutcome.noMatch;
    final available = capabilities.toSet();
    if (!available.containsAll(requiredCapabilities)) {
      return RoutingOutcome.noMatch;
    }
    var ambiguous = false;
    for (final trigger in negativeTriggers) {
      final status = _routingPhraseStatus(request, trigger);
      if (status == _RoutingPhraseStatus.matched) {
        return RoutingOutcome.noMatch;
      }
      ambiguous |= status == _RoutingPhraseStatus.ambiguous;
    }
    var hasIntent = false;
    for (final intent in intents) {
      final status = _routingPhraseStatus(request, intent);
      hasIntent |= status == _RoutingPhraseStatus.matched;
      ambiguous |= status == _RoutingPhraseStatus.ambiguous;
    }
    if (ambiguous) return RoutingOutcome.needsClarification;
    return hasIntent ? RoutingOutcome.match : RoutingOutcome.noMatch;
  }

  Map<String, Object?> toJson() => {
    'intents': intents.toList(),
    'capabilities': capabilities.toList(),
    'negativeTriggers': negativeTriggers.toList(),
  };
}

@immutable
class ToolPolicy {
  ToolPolicy({
    required List<String> allowedTools,
    required List<String> approvalRequiredTools,
    required List<String> deniedTools,
  }) : allowedTools = _validatedIdentifiers(
         allowedTools,
         field: 'allowedTools',
       ),
       approvalRequiredTools = _validatedIdentifiers(
         approvalRequiredTools,
         field: 'approvalRequiredTools',
       ),
       deniedTools = _validatedIdentifiers(deniedTools, field: 'deniedTools') {
    final allowed = this.allowedTools.toSet();
    final approval = this.approvalRequiredTools.toSet();
    final denied = this.deniedTools.toSet();
    if (!allowed.containsAll(approval) ||
        allowed.intersection(denied).isNotEmpty) {
      throw ArgumentError(
        'Approval tools must be allowed and allowed tools cannot be denied.',
      );
    }
  }

  factory ToolPolicy.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'allowedTools',
      'approvalRequiredTools',
      'deniedTools',
    });
    return ToolPolicy(
      allowedTools: _readStringList(json, 'allowedTools'),
      approvalRequiredTools: _readStringList(json, 'approvalRequiredTools'),
      deniedTools: _readStringList(json, 'deniedTools'),
    );
  }

  final List<String> allowedTools;
  final List<String> approvalRequiredTools;
  final List<String> deniedTools;

  ToolDecision decisionFor(String toolId) {
    if (deniedTools.contains(toolId) || !allowedTools.contains(toolId)) {
      return ToolDecision.denied;
    }
    return approvalRequiredTools.contains(toolId)
        ? ToolDecision.requiresApproval
        : ToolDecision.allowed;
  }

  Map<String, Object?> toJson() => {
    'allowedTools': allowedTools.toList(),
    'approvalRequiredTools': approvalRequiredTools.toList(),
    'deniedTools': deniedTools.toList(),
  };
}

@immutable
class OutputSchema {
  OutputSchema({
    required this.schemaId,
    required Map<String, OutputValueType> fields,
    Set<String> allowedVerdicts = const {},
    this.evidenceField,
    this.verdictField,
    this.abstainVerdict,
    this.allowAdditionalFields = false,
  }) : fields = Map<String, OutputValueType>.unmodifiable(
         _validatedOutputFields(fields),
       ),
       allowedVerdicts = Set<String>.unmodifiable(
         _validatedIdentifiers(allowedVerdicts, field: 'allowedVerdicts'),
       ) {
    _validateIdentifier(schemaId, 'schemaId');
    final abstentionFields = [evidenceField, verdictField, abstainVerdict];
    final configured = abstentionFields.whereType<String>().length;
    if (configured != 0 && configured != abstentionFields.length) {
      throw ArgumentError(
        'Evidence, verdict, and abstain fields must be configured together.',
      );
    }
    if (configured == abstentionFields.length) {
      if (this.fields['Claim'] != OutputValueType.string ||
          this.fields[evidenceField] != OutputValueType.evidenceList ||
          this.fields[verdictField] != OutputValueType.string ||
          !this.allowedVerdicts.contains(abstainVerdict)) {
        throw ArgumentError('Invalid abstention output contract.');
      }
    } else if (this.allowedVerdicts.isNotEmpty) {
      throw ArgumentError('Allowed verdicts require a verdict contract.');
    }
  }

  factory OutputSchema.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'schemaId',
      'fields',
      'allowedVerdicts',
      'evidenceField',
      'verdictField',
      'abstainVerdict',
      'allowAdditionalFields',
    });
    final rawFields = _readMap(json, 'fields');
    final fields = <String, OutputValueType>{};
    for (final entry in rawFields.entries) {
      fields[entry.key] = _readEnumValue(
        entry.value,
        'fields.${entry.key}',
        OutputValueType.values,
      );
    }
    return OutputSchema(
      schemaId: _readString(json, 'schemaId'),
      fields: fields,
      allowedVerdicts: _readUniqueStringSet(json, 'allowedVerdicts'),
      evidenceField: _readNullableString(json, 'evidenceField'),
      verdictField: _readNullableString(json, 'verdictField'),
      abstainVerdict: _readNullableString(json, 'abstainVerdict'),
      allowAdditionalFields: _readBool(json, 'allowAdditionalFields'),
    );
  }

  final String schemaId;
  final Map<String, OutputValueType> fields;
  final Set<String> allowedVerdicts;
  final String? evidenceField;
  final String? verdictField;
  final String? abstainVerdict;
  final bool allowAdditionalFields;

  /// Whether this schema expresses an abstaining, directional evidence
  /// decision rather than merely using ordinary fields with similar names.
  bool get hasDirectionalEvidenceContract =>
      evidenceField != null || verdictField != null || abstainVerdict != null;

  /// Checks only JSON shape and value types.
  ///
  /// This is not an authorization or evidence-trust decision. Production
  /// catalog output must be accepted through [ExecutableExpert.validateOutput].
  bool unsafeShapeOnly(Map<String, Object?> output) {
    if (!output.keys.toSet().containsAll(fields.keys)) return false;
    if (!allowAdditionalFields &&
        output.keys.any((key) => !fields.containsKey(key))) {
      return false;
    }
    for (final entry in fields.entries) {
      final value = output[entry.key];
      final valid = switch (entry.value) {
        OutputValueType.string => value is String && value.trim().isNotEmpty,
        OutputValueType.stringList =>
          value is List &&
              value.every((item) => item is String && item.trim().isNotEmpty),
        OutputValueType.evidenceList =>
          value is List && value.every(_isValidEvidenceValue),
        OutputValueType.integer => value is int,
        OutputValueType.boolean => value is bool,
      };
      if (!valid) return false;
    }
    final verdictKey = verdictField;
    if (verdictKey != null) {
      final verdict = output[verdictKey];
      if (verdict is! String || !allowedVerdicts.contains(verdict)) {
        return false;
      }
      final evidence = output[evidenceField];
      if (evidence is! List ||
          evidence.any((item) => !_isValidEvidenceValue(item))) {
        return false;
      }
      if (evidence.isEmpty && verdict != abstainVerdict) return false;
    }
    final confidence = output['Confidence'];
    if (confidence != null &&
        (confidence is! int || confidence < 0 || confidence > 100)) {
      return false;
    }
    return true;
  }

  Map<String, Object?> toJson() => {
    'schemaId': schemaId,
    'fields': fields.map((key, value) => MapEntry(key, value.name)),
    'allowedVerdicts': allowedVerdicts.toList()..sort(),
    'evidenceField': evidenceField,
    'verdictField': verdictField,
    'abstainVerdict': abstainVerdict,
    'allowAdditionalFields': allowAdditionalFields,
  };
}

/// Runtime validator for the trusted application side of the boundary.
///
/// The schema is inert structure. The registry is fixed once by the trusted
/// composition root; untrusted model output can provide only data and a
/// [ExpertValidationContext], never a replacement trust root.
class TrustedExpertOutputValidator {
  const TrustedExpertOutputValidator({
    required this.schema,
    required this.trustRegistry,
  });

  final OutputSchema schema;
  final EvidenceTrustRegistry trustRegistry;

  bool validate(Map<String, Object?> output, ExpertValidationContext context) {
    if (!schema.unsafeShapeOnly(output)) return false;
    final verdictKey = schema.verdictField;
    if (verdictKey == null) return true;
    final verdict = output[verdictKey];
    final claim = output['Claim'];
    final rawEvidence = output[schema.evidenceField];
    if (verdict is! String || claim is! String || rawEvidence is! List) {
      return false;
    }
    if (rawEvidence.isEmpty) return verdict == schema.abstainVerdict;
    final evidence = <EvidenceItem>[];
    for (final raw in rawEvidence) {
      final item = _decodeEvidenceValue(raw);
      if (item == null) return false;
      evidence.add(item);
    }
    final requiredStance = verdict == schema.abstainVerdict
        ? null
        : switch (verdict) {
            'supported' => EvidenceStance.supports,
            'contradicted' => EvidenceStance.contradicts,
            _ => null,
          };
    if (verdict != schema.abstainVerdict && requiredStance == null) {
      return false;
    }
    return trustRegistry.verifyAndConsume(
      evidence: evidence,
      claimDigest: claimDigestFor(claim),
      context: context,
      outputDigest: _expertOutputDigest(output),
      requiredStance: requiredStance,
    );
  }
}

/// The application-level output validation composition root.
///
/// A gateway may omit [trustRegistry] for structural-only catalogs. Experts
/// whose policy requires trusted evidence still bind, but their executable
/// validator fails closed.
class ExpertOutputValidationGateway {
  const ExpertOutputValidationGateway({this.trustRegistry});

  final EvidenceTrustRegistry? trustRegistry;

  ExecutableExpert bind(ExpertProfile profile) {
    final registry = trustRegistry;
    final trustedValidator =
        profile.validationPolicy == ExpertValidationPolicy.trustedEvidence &&
            registry != null
        ? TrustedExpertOutputValidator(
            schema: profile.outputSchema,
            trustRegistry: registry,
          )
        : null;
    return ExecutableExpert._(profile, trustedValidator);
  }
}

/// An expert profile bound to its executable output-validation policy.
///
/// Production callers should validate catalog output only through
/// [validateOutput]. Shape-only checks are intentionally not exposed here.
class ExecutableExpert {
  const ExecutableExpert._(this.profile, this._trustedValidator);

  final ExpertProfile profile;
  final TrustedExpertOutputValidator? _trustedValidator;

  bool validateOutput(
    Map<String, Object?> output, {
    ExpertValidationContext? context,
  }) {
    return switch (profile.validationPolicy) {
      ExpertValidationPolicy.structural => profile.outputSchema.unsafeShapeOnly(
        output,
      ),
      ExpertValidationPolicy.trustedEvidence =>
        context != null &&
            _trustedValidator != null &&
            _trustedValidator.validate(output, context),
    };
  }
}

@immutable
class MemoryPolicy {
  MemoryPolicy({
    required Set<MemoryScope> readableScopes,
    required this.retention,
  }) : readableScopes = Set<MemoryScope>.unmodifiable(readableScopes);

  factory MemoryPolicy.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {'readableScopes', 'retention'});
    return MemoryPolicy(
      readableScopes: _readEnumSet(json, 'readableScopes', MemoryScope.values),
      retention: _readEnum(json, 'retention', MemoryRetention.values),
    );
  }

  final Set<MemoryScope> readableScopes;
  final MemoryRetention retention;

  bool get canReadPrivateMemory => false;

  Map<String, Object?> toJson() => {
    'readableScopes': readableScopes.map((value) => value.name).toList()
      ..sort(),
    'retention': retention.name,
  };
}

@immutable
class EvaluationCase {
  EvaluationCase({
    required this.id,
    required this.input,
    required this.shouldRoute,
    required List<String> expectedBehaviors,
    required List<String> forbiddenBehaviors,
  }) : expectedBehaviors = _validatedStrings(
         expectedBehaviors,
         field: 'expectedBehaviors',
         requireNonEmpty: true,
       ),
       forbiddenBehaviors = _validatedStrings(
         forbiddenBehaviors,
         field: 'forbiddenBehaviors',
         requireNonEmpty: true,
       ) {
    _validateIdentifier(id, 'evaluationCase.id');
    _validateText(input, 'evaluationCase.input', maximumLength: 2048);
  }

  factory EvaluationCase.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'id',
      'input',
      'shouldRoute',
      'expectedBehaviors',
      'forbiddenBehaviors',
    });
    return EvaluationCase(
      id: _readString(json, 'id'),
      input: _readString(json, 'input'),
      shouldRoute: _readBool(json, 'shouldRoute'),
      expectedBehaviors: _readStringList(json, 'expectedBehaviors'),
      forbiddenBehaviors: _readStringList(json, 'forbiddenBehaviors'),
    );
  }

  final String id;
  final String input;
  final bool shouldRoute;
  final List<String> expectedBehaviors;
  final List<String> forbiddenBehaviors;

  Map<String, Object?> toJson() => {
    'id': id,
    'input': input,
    'shouldRoute': shouldRoute,
    'expectedBehaviors': expectedBehaviors.toList(),
    'forbiddenBehaviors': forbiddenBehaviors.toList(),
  };
}

@immutable
class ExpertProfile {
  ExpertProfile({
    required this.id,
    required this.displayName,
    required this.description,
    required this.version,
    required this.promptPackage,
    required this.routingCard,
    required this.toolPolicy,
    required this.outputSchema,
    required this.validationPolicy,
    required this.memoryPolicy,
    required List<EvaluationCase> evaluationCases,
  }) : evaluationCases = List<EvaluationCase>.unmodifiable(evaluationCases) {
    _validateIdentifier(id, 'expert.id');
    _validateText(displayName, 'displayName', maximumLength: 128);
    _validateText(description, 'description', maximumLength: 1024);
    if (version <= 0) throw ArgumentError.value(version, 'version');
    if (this.evaluationCases.isEmpty) {
      throw ArgumentError('At least one evaluation case is required.');
    }
    final caseIds = this.evaluationCases.map((value) => value.id).toSet();
    if (caseIds.length != this.evaluationCases.length) {
      throw ArgumentError('Evaluation case IDs must be unique.');
    }
    if (outputSchema.hasDirectionalEvidenceContract &&
        validationPolicy != ExpertValidationPolicy.trustedEvidence) {
      throw ArgumentError(
        'Directional evidence schemas require trusted-evidence validation.',
      );
    }
    if (validationPolicy == ExpertValidationPolicy.trustedEvidence &&
        (!outputSchema.hasDirectionalEvidenceContract ||
            !promptPackage.guards.contains(
              PromptGuard.abstainWithoutEvidence,
            ))) {
      throw ArgumentError(
        'Trusted-evidence experts require an abstaining evidence schema.',
      );
    }
  }

  factory ExpertProfile.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'id',
      'displayName',
      'description',
      'version',
      'promptPackage',
      'routingCard',
      'toolPolicy',
      'outputSchema',
      'validationPolicy',
      'memoryPolicy',
      'evaluationCases',
    });
    return ExpertProfile(
      id: _readString(json, 'id'),
      displayName: _readString(json, 'displayName'),
      description: _readString(json, 'description'),
      version: _readInt(json, 'version'),
      promptPackage: PromptPackage.fromJson(_readMap(json, 'promptPackage')),
      routingCard: RoutingCard.fromJson(_readMap(json, 'routingCard')),
      toolPolicy: ToolPolicy.fromJson(_readMap(json, 'toolPolicy')),
      outputSchema: OutputSchema.fromJson(_readMap(json, 'outputSchema')),
      validationPolicy: _readEnum(
        json,
        'validationPolicy',
        ExpertValidationPolicy.values,
      ),
      memoryPolicy: MemoryPolicy.fromJson(_readMap(json, 'memoryPolicy')),
      evaluationCases: _readMapList(
        json,
        'evaluationCases',
      ).map(EvaluationCase.fromJson).toList(),
    );
  }

  final String id;
  final String displayName;
  final String description;
  final int version;
  final PromptPackage promptPackage;
  final RoutingCard routingCard;
  final ToolPolicy toolPolicy;
  final OutputSchema outputSchema;
  final ExpertValidationPolicy validationPolicy;
  final MemoryPolicy memoryPolicy;
  final List<EvaluationCase> evaluationCases;

  Map<String, Object?> toJson() => {
    'id': id,
    'displayName': displayName,
    'description': description,
    'version': version,
    'promptPackage': promptPackage.toJson(),
    'routingCard': routingCard.toJson(),
    'toolPolicy': toolPolicy.toJson(),
    'outputSchema': outputSchema.toJson(),
    'validationPolicy': validationPolicy.name,
    'memoryPolicy': memoryPolicy.toJson(),
    'evaluationCases': evaluationCases.map((value) => value.toJson()).toList(),
  };
}

final _identifierPattern = RegExp(r'^[a-z][a-z0-9._-]{2,63}$');
final _secretPatterns = [
  RegExp(r'authorization\s*:\s*(?:bearer|basic)\s+\S+', caseSensitive: false),
  RegExp(r'\bsk-[A-Za-z0-9_-]{12,}\b', caseSensitive: false),
  RegExp(
    r'\b(?:api[_ -]?key|password|token|credential)\s*[:=]\s*\S+',
    caseSensitive: false,
  ),
  RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
];

void _validateText(String value, String field, {int maximumLength = 512}) {
  if (value.trim().isEmpty || value.length > maximumLength) {
    throw ArgumentError.value(value, field, 'Must be non-empty and bounded.');
  }
  if (_secretPatterns.any((pattern) => pattern.hasMatch(value))) {
    throw ArgumentError.value(value, field, 'Secret material is not allowed.');
  }
}

void _validateIdentifier(String value, String field) {
  _validateText(value, field, maximumLength: 64);
  if (!_identifierPattern.hasMatch(value)) {
    throw ArgumentError.value(value, field, 'Invalid identifier.');
  }
  if (_looksHighEntropySecret(value)) {
    throw ArgumentError.value(
      value,
      field,
      'High-entropy secret-like identifiers are not allowed.',
    );
  }
}

bool _looksHighEntropySecret(String value) {
  if (RegExp(r'^[a-f0-9]{32,}$', caseSensitive: false).hasMatch(value)) {
    return true;
  }
  final compact = value.replaceAll(RegExp(r'[-_.]'), '');
  if (compact.length < 24) return false;
  final counts = <String, int>{};
  for (final character in compact.split('')) {
    counts.update(character, (count) => count + 1, ifAbsent: () => 1);
  }
  final entropy = counts.values.fold<double>(0, (sum, count) {
    final probability = count / compact.length;
    return sum - probability * (math.log(probability) / math.ln2);
  });
  return entropy >= 4;
}

List<String> _validatedStrings(
  Iterable<String> values, {
  required String field,
  bool requireNonEmpty = false,
}) {
  final copied = List<String>.of(values);
  if (requireNonEmpty && copied.isEmpty) {
    throw ArgumentError('$field must not be empty.');
  }
  for (final value in copied) {
    _validateText(value, field);
  }
  if (copied.toSet().length != copied.length) {
    throw ArgumentError('$field must not contain duplicates.');
  }
  return List<String>.unmodifiable(copied);
}

List<String> _validatedIdentifiers(
  Iterable<String> values, {
  required String field,
  bool requireNonEmpty = false,
}) {
  final copied = List<String>.of(values);
  if (requireNonEmpty && copied.isEmpty) {
    throw ArgumentError('$field must not be empty.');
  }
  for (final value in copied) {
    _validateIdentifier(value, field);
  }
  if (copied.toSet().length != copied.length) {
    throw ArgumentError('$field must not contain duplicates.');
  }
  return List<String>.unmodifiable(copied);
}

Set<T> _requireNonEmptySet<T>(Set<T> values, String field) {
  if (values.isEmpty) throw ArgumentError('$field must not be empty.');
  return Set<T>.of(values);
}

Map<String, OutputValueType> _validatedOutputFields(
  Map<String, OutputValueType> fields,
) {
  if (fields.isEmpty) throw ArgumentError('Output fields must not be empty.');
  for (final key in fields.keys) {
    _validateText(key, 'output field', maximumLength: 64);
  }
  return Map<String, OutputValueType>.of(fields);
}

String _normalizeRoutingText(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'\s+'), '');

enum _RoutingPhraseStatus { absent, matched, negated, ambiguous }

_RoutingPhraseStatus _routingPhraseStatus(String request, String phrase) {
  final collapsedPhrase = phrase.trim().toLowerCase().replaceAll(
    RegExp(r'\s+'),
    ' ',
  );
  final usesAsciiTokenBoundary = RegExp(
    r'^[a-z0-9]+(?: [a-z0-9]+)*$',
  ).hasMatch(collapsedPhrase);
  final normalizedRequest = usesAsciiTokenBoundary
      ? request.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ')
      : _normalizeRoutingText(request);
  final normalizedPhrase = usesAsciiTokenBoundary
      ? collapsedPhrase
      : _normalizeRoutingText(phrase);
  if (normalizedRequest.isEmpty || normalizedPhrase.isEmpty) {
    return _RoutingPhraseStatus.absent;
  }

  var foundNegated = false;
  var foundAmbiguous = false;
  var start = 0;
  while (start <= normalizedRequest.length - normalizedPhrase.length) {
    final index = normalizedRequest.indexOf(normalizedPhrase, start);
    if (index < 0) break;
    final end = index + normalizedPhrase.length;
    final hasTokenBoundary =
        !usesAsciiTokenBoundary ||
        ((index == 0 || !_isAsciiAlphaNumeric(normalizedRequest[index - 1])) &&
            (end == normalizedRequest.length ||
                !_isAsciiAlphaNumeric(normalizedRequest[end])));
    final prefix = _normalizeRoutingText(normalizedRequest.substring(0, index));
    if (hasTokenBoundary) {
      final negation = _chineseNegationStatus(prefix);
      if (negation == _ChineseNegationStatus.ambiguous) {
        foundAmbiguous = true;
      } else if (negation == _ChineseNegationStatus.negated) {
        foundNegated = true;
      } else {
        return _RoutingPhraseStatus.matched;
      }
    }
    start = index + normalizedPhrase.length;
  }
  if (foundAmbiguous) return _RoutingPhraseStatus.ambiguous;
  if (foundNegated) return _RoutingPhraseStatus.negated;
  return _RoutingPhraseStatus.absent;
}

bool _isAsciiAlphaNumeric(String character) =>
    RegExp(r'^[a-z0-9]$').hasMatch(character);

enum _ChineseNegationStatus { none, negated, ambiguous }

_ChineseNegationStatus _chineseNegationStatus(String prefix) {
  final clauseStart = prefix.lastIndexOf(RegExp(r'[，。！？；,.!?;]')) + 1;
  final clause = prefix.substring(clauseStart);
  if (RegExp(r'(?:不是|并非)(?:不需要|不要|无需|不必|禁止|别)').hasMatch(clause)) {
    return _ChineseNegationStatus.ambiguous;
  }
  const negators = ['不是要', '并非要', '不需要', '不要', '无需', '不必', '禁止', '别'];
  var latestIndex = -1;
  var latestNegator = '';
  for (final negator in negators) {
    var index = clause.lastIndexOf(negator);
    if (negator == '别') {
      while (index >= 0 && _isLexicalBie(clause, index)) {
        index = clause.lastIndexOf(negator, index - 1);
      }
    }
    if (index > latestIndex) {
      latestIndex = index;
      latestNegator = negator;
    }
  }
  if (latestIndex < 0) return _ChineseNegationStatus.none;
  final filler = clause.substring(latestIndex + latestNegator.length);
  if (RegExp(r'(?:不是|并非|不要|无需|不需要|不必|禁止|别).*不$').hasMatch(clause)) {
    return _ChineseNegationStatus.ambiguous;
  }
  if (const ['但', '但是', '而是', '却', '不过'].any(filler.contains)) {
    return _ChineseNegationStatus.none;
  }
  return _ChineseNegationStatus.negated;
}

bool _isLexicalBie(String clause, int index) {
  if (index == 0) return false;
  final word = clause.substring(index - 1, index + 1);
  return const {
    '识别',
    '辨别',
    '分别',
    '区别',
    '差别',
    '个别',
    '类别',
    '特别',
    '级别',
    '性别',
    '判别',
    '鉴别',
  }.contains(word);
}

bool _isValidEvidenceValue(Object? value) {
  return _decodeEvidenceValue(value) != null;
}

EvidenceItem? _decodeEvidenceValue(Object? value) {
  if (value is EvidenceItem) return value;
  if (value is! Map || value.keys.any((key) => key is! String)) return null;
  try {
    return EvidenceItem.fromJson(Map<String, Object?>.from(value));
  } on Object {
    return null;
  }
}

void _validateClaimDigest(String value, String field) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw ArgumentError.value(value, field, 'Must be a SHA-256 digest.');
  }
}

void _validateReceiptId(String value) {
  if (!RegExp(r'^rcpt_[A-Za-z0-9_-]{22}$').hasMatch(value)) {
    throw ArgumentError.value(value, 'receiptId', 'Invalid opaque receipt ID.');
  }
}

void _validateReceiptToken(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) {
    throw ArgumentError.value(
      value,
      'receiptToken',
      'Invalid receipt attestation token.',
    );
  }
}

String _normalizeEvidenceContent(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ');

bool _constantTimeEquals(String left, String right) {
  final leftBytes = utf8.encode(left);
  final rightBytes = utf8.encode(right);
  var difference = leftBytes.length ^ rightBytes.length;
  final length = math.max(leftBytes.length, rightBytes.length);
  for (var index = 0; index < length; index++) {
    final leftByte = index < leftBytes.length ? leftBytes[index] : 0;
    final rightByte = index < rightBytes.length ? rightBytes[index] : 0;
    difference |= leftByte ^ rightByte;
  }
  return difference == 0;
}

String _expertOutputDigest(Map<String, Object?> output) {
  final canonicalJson = jsonEncode(_canonicalJsonValue(output));
  return sha256.convert(utf8.encode(canonicalJson)).toString();
}

Object? _canonicalJsonValue(Object? value) {
  if (value is EvidenceItem) return _canonicalJsonValue(value.toJson());
  if (value is Map) {
    final keys = value.keys.whereType<String>().toList()..sort();
    return {for (final key in keys) key: _canonicalJsonValue(value[key])};
  }
  if (value is List) return value.map(_canonicalJsonValue).toList();
  return value;
}

void _validateEvidenceRef(String value) {
  _validateText(value, 'evidence.ref', maximumLength: 2048);
  if (_compactForSafety(value).contains('trustme')) {
    throw ArgumentError.value(
      value,
      'evidence.ref',
      'Reference is not locatable.',
    );
  }
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme) {
    throw ArgumentError.value(
      value,
      'evidence.ref',
      'Reference must be a URI.',
    );
  }
  if (uri.userInfo.isNotEmpty ||
      _containsSensitiveUriComponent(uri.fragment) ||
      uri.queryParametersAll.entries.any(
        (entry) =>
            _containsSensitiveUriKey(entry.key) ||
            entry.value.any(_containsSensitiveUriComponent),
      )) {
    throw ArgumentError.value(
      value,
      'evidence.ref',
      'Credential-bearing URI components are not allowed.',
    );
  }
  if (uri.scheme == 'https') {
    if (uri.host.isEmpty) {
      throw ArgumentError.value(
        value,
        'evidence.ref',
        'HTTPS reference must include a host.',
      );
    }
    return;
  }
  const internalSchemes = {
    'artifact',
    'document',
    'message',
    'release-note',
    'source',
  };
  if (!internalSchemes.contains(uri.scheme) ||
      (uri.host.isEmpty && uri.path.isEmpty)) {
    throw ArgumentError.value(
      value,
      'evidence.ref',
      'Unsupported source reference.',
    );
  }
}

bool _isSensitiveQueryKey(String value) {
  final normalized = value.toLowerCase().replaceAll(RegExp(r'[-_.\s]+'), '');
  if (const {
    'auth',
    'authorization',
    'sig',
    'credential',
    'password',
  }.contains(normalized)) {
    return true;
  }
  return RegExp(
    r'^(?:(?:access|refresh|id|api|auth|session|private|public|signing))?'
    r'(?:token|key|secret|signature)$',
  ).hasMatch(normalized);
}

bool _containsSensitiveUriComponent(String value) {
  if (value.isEmpty) return false;
  for (final decoded in _percentDecodeLayers(value)) {
    if (_secretPatterns.any((pattern) => pattern.hasMatch(decoded)) ||
        _looksHighEntropySecret(decoded)) {
      return true;
    }
    final separator = decoded.indexOf('=');
    if (separator > 0 &&
        _containsSensitiveUriKey(decoded.substring(0, separator))) {
      return true;
    }
  }
  return false;
}

bool _containsSensitiveUriKey(String value) =>
    _percentDecodeLayers(value).any(_isSensitiveQueryKey);

List<String> _percentDecodeLayers(String value) {
  const maximumDecodeRounds = 4;
  final layers = <String>[value];
  var current = value;
  for (var round = 0; round < maximumDecodeRounds; round++) {
    String decoded;
    try {
      decoded = Uri.decodeComponent(current);
    } on FormatException {
      throw ArgumentError.value(value, 'evidence.ref', 'Invalid URI encoding.');
    }
    if (decoded == current) return layers;
    layers.add(decoded);
    current = decoded;
  }
  throw ArgumentError.value(
    value,
    'evidence.ref',
    'URI encoding did not stabilize.',
  );
}

String _compactForSafety(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');

void _expectKeys(Map<String, Object?> json, Set<String> expected) {
  final actual = json.keys.toSet();
  if (actual.length != expected.length || !actual.containsAll(expected)) {
    throw FormatException('Unexpected JSON fields: $actual');
  }
}

String _readString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string.');
  return value;
}

String? _readNullableString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is String) return value as String?;
  throw FormatException('$key must be a nullable string.');
}

int _readInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) throw FormatException('$key must be an integer.');
  return value;
}

bool _readBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('$key must be a boolean.');
  return value;
}

List<String> _readStringList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List || value.any((item) => item is! String)) {
    throw FormatException('$key must be a string list.');
  }
  return List<String>.from(value);
}

Map<String, Object?> _readMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map || value.keys.any((item) => item is! String)) {
    throw FormatException('$key must be an object.');
  }
  return Map<String, Object?>.from(value);
}

List<Map<String, Object?>> _readMapList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) throw FormatException('$key must be an object list.');
  return value.map((item) {
    if (item is! Map || item.keys.any((nestedKey) => nestedKey is! String)) {
      throw FormatException('$key must be an object list.');
    }
    return Map<String, Object?>.from(item);
  }).toList();
}

T _readEnum<T extends Enum>(
  Map<String, Object?> json,
  String key,
  List<T> values,
) => _readEnumValue(json[key], key, values);

T _readEnumValue<T extends Enum>(Object? value, String key, List<T> values) {
  if (value is! String) throw FormatException('$key must be an enum name.');
  try {
    _validateText(value, key, maximumLength: 64);
  } on ArgumentError {
    throw FormatException('$key contains invalid or sensitive material.');
  }
  if (_looksHighEntropySecret(value)) {
    throw FormatException('$key contains invalid or sensitive material.');
  }
  for (final candidate in values) {
    if (candidate.name == value) return candidate;
  }
  throw FormatException('$key has an unknown enum value.');
}

Set<T> _readEnumSet<T extends Enum>(
  Map<String, Object?> json,
  String key,
  List<T> values,
) {
  final raw = _readStringList(json, key);
  if (raw.toSet().length != raw.length) {
    throw FormatException('$key must not contain duplicates.');
  }
  return raw.map((value) => _readEnumValue(value, key, values)).toSet();
}

Set<String> _readUniqueStringSet(Map<String, Object?> json, String key) {
  final raw = _readStringList(json, key);
  if (raw.toSet().length != raw.length) {
    throw FormatException('$key must not contain duplicates.');
  }
  return raw.toSet();
}
