import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'built_in_experts.dart';
import 'expert_catalog_batch_one.dart';
import 'expert_catalog_batch_two.dart';

enum PromptGuard {
  roleIntegrity,
  evidenceBoundaries,
  noFabrication,
  abstainWithoutEvidence,
}

enum ToolDecision { allowed, requiresApproval, denied }

enum RoutingOutcome { match, noMatch, needsClarification }

enum OutputValueType {
  string,
  stringList,
  evidenceList,
  integer,
  boolean,
  proposedActionList,
  verificationEnvelope,

  /// A natural-language reply written for the user.
  ///
  /// This is the one field whose free text is shown verbatim. It is safe to
  /// surface only because the envelope beside it is structurally pinned to
  /// `claimType=advice` / `verified=false`, and the UI renders that as 未核验 —
  /// the framing is structural, not a scan of the prose.
  answerText,
}

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

@immutable
class VerificationReceipt {
  const VerificationReceipt._(this.receiptId, this.token);

  final String receiptId;
  final String token;

  @override
  String toString() => 'VerificationReceipt(receiptId: $receiptId)';
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

/// Trusted application-side attestations for structural verification results.
///
/// Model output can name a source but cannot create a matching record. An
/// attestation is bound to the expert, schema/version, validation context,
/// complete canonical output digest, and source.
class VerificationRegistry {
  VerificationRegistry._(List<int> key, this._random, this._clock)
    : _key = List<int>.unmodifiable(key);

  factory VerificationRegistry.secure({
    EvidenceClock clock = const SystemEvidenceClock(),
  }) {
    final random = math.Random.secure();
    return VerificationRegistry._(
      List<int>.generate(32, (_) => random.nextInt(256)),
      random,
      clock,
    );
  }

  @visibleForTesting
  factory VerificationRegistry.forTesting(
    List<int> key, {
    required EvidenceClock clock,
  }) {
    if (key.length < 16) {
      throw ArgumentError.value(key, 'key', 'Must contain at least 16 bytes.');
    }
    return VerificationRegistry._(key, math.Random(0), clock);
  }

  final List<int> _key;
  final math.Random _random;
  final EvidenceClock _clock;
  final Map<String, _VerificationRecord> _recordsById = {};

  VerificationReceipt issue({
    required String expertId,
    required String schemaId,
    required int profileVersion,
    required ExpertValidationContext context,
    required Map<String, Object?> output,
    required String source,
    required Duration validFor,
  }) {
    _validateIdentifier(expertId, 'verification.expertId');
    _validateIdentifier(schemaId, 'verification.schemaId');
    if (profileVersion <= 0) {
      throw ArgumentError.value(profileVersion, 'profileVersion');
    }
    _validateText(source, 'verification.source', maximumLength: 2048);
    if (source == 'none') {
      throw ArgumentError.value(source, 'source', 'Must identify a source.');
    }
    final snapshot = _ExpertOutputSnapshot.tryParse(output);
    if (snapshot == null) {
      throw ArgumentError.value(output, 'output', 'Must be canonical JSON.');
    }
    final envelope = snapshot.value['Verification'];
    if (envelope is! Map ||
        envelope['verified'] != true ||
        envelope['source'] != source) {
      throw ArgumentError(
        'Verification output must be verified and match its trusted source.',
      );
    }
    if (validFor <= Duration.zero) {
      throw ArgumentError.value(validFor, 'validFor', 'Must be positive.');
    }
    final issuedAt = _clock.now().toUtc();
    final expiresAt = issuedAt.add(validFor);
    final outputDigest = snapshot.digest;
    final receiptId = 'vrcpt_${_randomBase64Url(16)}';
    final binding = _verificationBinding(
      expertId: expertId,
      schemaId: schemaId,
      profileVersion: profileVersion,
      audience: context._audience,
      outputDigest: outputDigest,
      source: source,
    );
    final token = base64Url
        .encode(
          Hmac(sha256, _key)
              .convert(
                utf8.encode(
                  jsonEncode([
                    receiptId,
                    binding,
                    issuedAt.microsecondsSinceEpoch,
                    expiresAt.microsecondsSinceEpoch,
                  ]),
                ),
              )
              .bytes,
        )
        .replaceAll('=', '');
    _recordsById[receiptId] = _VerificationRecord(
      receiptId: receiptId,
      token: token,
      binding: binding,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
    );
    return VerificationReceipt._(receiptId, token);
  }

  bool verifyAndConsume({
    required String expertId,
    required String schemaId,
    required int profileVersion,
    required ExpertValidationContext context,
    required Map<String, Object?> output,
    required String receiptId,
    required String receiptToken,
  }) {
    final snapshot = _ExpertOutputSnapshot.tryParse(output);
    if (snapshot == null) return false;
    final envelope = snapshot.value['Verification'];
    if (envelope is! Map) return false;
    final source = envelope['source'];
    if (source is! String || source == 'none') return false;
    return _verifySnapshotAndConsume(
      expertId: expertId,
      schemaId: schemaId,
      profileVersion: profileVersion,
      context: context,
      outputDigest: snapshot.digest,
      source: source,
      receiptId: receiptId,
      receiptToken: receiptToken,
    );
  }

  bool _verifySnapshotAndConsume({
    required String expertId,
    required String schemaId,
    required int profileVersion,
    required ExpertValidationContext context,
    required String outputDigest,
    required String source,
    required String receiptId,
    required String receiptToken,
  }) {
    final binding = _verificationBinding(
      expertId: expertId,
      schemaId: schemaId,
      profileVersion: profileVersion,
      audience: context._audience,
      outputDigest: outputDigest,
      source: source,
    );
    final record = _recordsById[receiptId];
    if (record == null) return false;
    final now = _clock.now().toUtc();
    if (record.consumed ||
        record.binding != binding ||
        !_constantTimeEquals(record.token, receiptToken) ||
        now.isBefore(record.issuedAt) ||
        !now.isBefore(record.expiresAt)) {
      return false;
    }
    final expectedToken = base64Url
        .encode(
          Hmac(sha256, _key)
              .convert(
                utf8.encode(
                  jsonEncode([
                    record.receiptId,
                    record.binding,
                    record.issuedAt.microsecondsSinceEpoch,
                    record.expiresAt.microsecondsSinceEpoch,
                  ]),
                ),
              )
              .bytes,
        )
        .replaceAll('=', '');
    if (!_constantTimeEquals(expectedToken, record.token)) return false;
    record.consumed = true;
    return true;
  }

  String _randomBase64Url(int byteCount) => base64Url
      .encode(List<int>.generate(byteCount, (_) => _random.nextInt(256)))
      .replaceAll('=', '');
}

class _VerificationRecord {
  _VerificationRecord({
    required this.receiptId,
    required this.token,
    required this.binding,
    required this.issuedAt,
    required this.expiresAt,
  });

  final String receiptId;
  final String token;
  final String binding;
  final DateTime issuedAt;
  final DateTime expiresAt;
  bool consumed = false;
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
    required String expertId,
    required String schemaId,
    required int profileVersion,
    required ExpertValidationContext context,
    required Duration validFor,
    required String outputDigest,
    required String claimDigest,
    required String sourceId,
    required String ref,
    required EvidenceStance stance,
    required String quoteOrSummary,
  }) {
    _validateIdentifier(expertId, 'receipt.expertId');
    _validateIdentifier(schemaId, 'receipt.schemaId');
    if (profileVersion <= 0) {
      throw ArgumentError.value(profileVersion, 'profileVersion');
    }
    _validateClaimDigest(outputDigest, 'receipt.outputDigest');
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
      expertId: expertId,
      schemaId: schemaId,
      profileVersion: profileVersion,
      outputDigest: outputDigest,
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
      expertId: expertId,
      schemaId: schemaId,
      profileVersion: profileVersion,
      outputDigest: outputDigest,
    );
    return EvidenceReceipt._(receiptId, token);
  }

  bool verifyAndConsume({
    required String expertId,
    required String schemaId,
    required int profileVersion,
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
          record.consumed ||
          record.expertId != expertId ||
          record.schemaId != schemaId ||
          record.profileVersion != profileVersion ||
          record.outputDigest != outputDigest ||
          record.audience != context._audience ||
          now.isBefore(record.issuedAt) ||
          !now.isBefore(record.expiresAt) ||
          (requiredStance != null && item.stance != requiredStance) ||
          !_constantTimeEquals(record.token, item.receiptToken)) {
        return false;
      }
      final expectedToken = _attestationToken(
        receiptId: item.receiptId,
        audience: record.audience,
        issuedAt: record.issuedAt,
        expiresAt: record.expiresAt,
        expertId: record.expertId,
        schemaId: record.schemaId,
        profileVersion: record.profileVersion,
        outputDigest: record.outputDigest,
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
      record.consumed = true;
    }
    return true;
  }

  String _attestationToken({
    required String receiptId,
    required String audience,
    required DateTime issuedAt,
    required DateTime expiresAt,
    required String expertId,
    required String schemaId,
    required int profileVersion,
    required String outputDigest,
    required String claimDigest,
    required String sourceId,
    required String ref,
    required EvidenceStance stance,
    required String quoteOrSummary,
  }) {
    final contentDigest = sha256
        .convert(utf8.encode(quoteOrSummary))
        .toString();
    final payload = jsonEncode([
      receiptId,
      audience,
      issuedAt.microsecondsSinceEpoch,
      expiresAt.microsecondsSinceEpoch,
      expertId,
      schemaId,
      profileVersion,
      outputDigest,
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
    required this.expertId,
    required this.schemaId,
    required this.profileVersion,
    required this.outputDigest,
  });

  final String receiptId;
  final String token;
  final String audience;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final String expertId;
  final String schemaId;
  final int profileVersion;
  final String outputDigest;
  bool consumed = false;
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
  /// output must be accepted and projected atomically through
  /// [ExecutableExpert.validateAndProject].
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
        OutputValueType.answerText => _isValidAnswerText(value),
        OutputValueType.stringList =>
          value is List &&
              value.every((item) => item is String && item.trim().isNotEmpty),
        OutputValueType.evidenceList =>
          value is List && value.every(_isValidEvidenceValue),
        OutputValueType.integer => value is int,
        OutputValueType.boolean => value is bool,
        OutputValueType.proposedActionList => _isValidProposedActionList(value),
        OutputValueType.verificationEnvelope => _isValidVerificationEnvelope(
          value,
        ),
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
    required this.expertId,
    required this.schemaId,
    required this.profileVersion,
  });

  final OutputSchema schema;
  final EvidenceTrustRegistry trustRegistry;
  final String expertId;
  final String schemaId;
  final int profileVersion;

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
      expertId: expertId,
      schemaId: schemaId,
      profileVersion: profileVersion,
      evidence: evidence,
      claimDigest: claimDigestFor(claim),
      context: context,
      outputDigest: expertOutputDigestFor(output),
      requiredStance: requiredStance,
    );
  }
}

/// The application-level output validation composition root.
///
/// Binding is library-private and used only by [ExecutableExpertRegistry].
/// Trusted-evidence profiles may be routed, but remain fail-closed in
/// [ExecutableExpert] until a trusted evidence projection is supplied.
class ExpertOutputValidationGateway {
  const ExpertOutputValidationGateway({this.verificationRegistry});

  final VerificationRegistry? verificationRegistry;

  ExecutableExpert _bind(ExpertProfile profile) {
    // Fail fast at construction rather than shipping a launchable expert whose
    // every reply fails closed in [ExecutableExpert.validateAndProject].
    if (profile.validationPolicy != ExpertValidationPolicy.structural) {
      throw StateError('Only structural launch profiles are executable.');
    }
    return ExecutableExpert._(
      profile,
      StructuralExpertOutputValidator(
        profile: profile,
        verificationRegistry: verificationRegistry,
      ),
    );
  }
}

class StructuralExpertOutputValidator {
  const StructuralExpertOutputValidator({
    required this.profile,
    required this.verificationRegistry,
  });

  final ExpertProfile profile;
  final VerificationRegistry? verificationRegistry;

  bool preflight(Map<String, Object?> output) {
    final snapshot = _ExpertOutputSnapshot.tryParse(output);
    return snapshot != null && _validateSnapshot(snapshot);
  }

  bool _validateSnapshot(
    _ExpertOutputSnapshot snapshot, {
    ExpertValidationContext? context,
    VerificationReceipt? verificationReceipt,
  }) {
    final output = snapshot.value;
    if (!profile.outputSchema.unsafeShapeOnly(output)) return false;
    if (profile.outputSchema.fields['Verification'] !=
        OutputValueType.verificationEnvelope) {
      return false;
    }
    final envelope = output['Verification'];
    if (envelope is! Map) return false;
    final topLevelRecommendations = output['Recommendations'];
    if (topLevelRecommendations != null) {
      final envelopeRecommendations = envelope['proposedActions'];
      if (topLevelRecommendations is! List ||
          envelopeRecommendations is! List ||
          expertOutputDigestFor({'actions': topLevelRecommendations}) !=
              expertOutputDigestFor({'actions': envelopeRecommendations})) {
        return false;
      }
    }
    final verified = envelope['verified'];
    if (verified == false) return true;
    if (verified != true) return false;
    final registry = verificationRegistry;
    return context != null &&
        registry != null &&
        verificationReceipt != null &&
        registry._verifySnapshotAndConsume(
          expertId: profile.id,
          schemaId: profile.outputSchema.schemaId,
          profileVersion: profile.version,
          context: context,
          outputDigest: snapshot.digest,
          source: envelope['source']! as String,
          receiptId: verificationReceipt.receiptId,
          receiptToken: verificationReceipt.token,
        );
  }
}

/// An expert profile bound to its executable output-validation policy.
///
/// Production presentation must use [validateAndProject], which validates and
/// returns a controlled immutable string in one operation. Shape-only checks
/// are intentionally not exposed here.
class ExecutableExpert {
  const ExecutableExpert._(this.profile, this._structuralValidator);

  final ExpertProfile profile;
  final StructuralExpertOutputValidator _structuralValidator;

  /// Non-consuming structural preflight for offline contract evaluation.
  ///
  /// Completed claims always fail here because only [validateAndProject] may
  /// consume a verification receipt.
  bool preflightOutput(Map<String, Object?> output) =>
      profile.validationPolicy == ExpertValidationPolicy.structural &&
      _structuralValidator.preflight(output);

  /// Whether this expert answers in plain text instead of a JSON envelope.
  ///
  /// The advice envelope is a constant the application pins, so for these
  /// experts the JSON wrapper carried no information and only created a way
  /// for a finished answer to be thrown away. Experts that adjudicate
  /// evidence still return structured output.
  bool get usesPlainAnswer =>
      profile.validationPolicy == ExpertValidationPolicy.structural &&
      profile.outputSchema.fields[expertAnswerField] ==
          OutputValueType.answerText &&
      !profile.outputSchema.hasDirectionalEvidenceContract;

  /// Makes a plain-text reply safe to display without ever discarding it.
  ///
  /// Rejecting a reply the user already watched arrive is the worst possible
  /// outcome, and the reasons the strict path rejects — a stray tab, a
  /// zero-width character — are display concerns, not safety ones, so they are
  /// repaired rather than fatal. Length is not a reason to touch a reply at
  /// all. Null is returned only when there was genuinely nothing to show.
  String? sanitizePlainAnswer(String raw) {
    if (!usesPlainAnswer) return null;
    final buffer = StringBuffer();
    for (final rune in raw.runes) {
      if (rune == 0x0A) {
        buffer.writeCharCode(rune);
        continue;
      }
      if (rune == 0x09) {
        buffer.write('  ');
        continue;
      }
      // Control characters, bidi overrides and zero-width joiners are
      // display-layer spoofing tools, never content.
      if (rune < 0x20 || (rune >= 0x7F && rune <= 0x9F)) continue;
      if (rune >= 0x200B && rune <= 0x200F) continue;
      if (rune >= 0x202A && rune <= 0x202E) continue;
      if (rune >= 0x2066 && rune <= 0x2069) continue;
      if (rune >= 0xFFF9 && rune <= 0xFFFB) continue;
      buffer.writeCharCode(rune);
    }
    final cleaned = buffer.toString().trim();
    // No length ceiling: a long answer is a long answer. Cutting one off (or
    // worse, discarding it) is a product decision nobody asked for.
    return cleaned.isEmpty ? null : cleaned;
  }

  /// Projects a natural answer when only the answer itself is trustworthy.
  ///
  /// The advice envelope this expert would otherwise have to echo
  /// (claimType=advice, tense=proposed, verified=false, source=none) is a
  /// constant the application pins regardless of model output, so demanding
  /// the model reproduce it exactly adds no safety while routinely destroying
  /// complete answers over a stray verb or a non-kebab-case target.
  ///
  /// This path is therefore deliberately narrow: structural policy only, an
  /// `Answer` field the schema itself declares as answer text, and no
  /// directional evidence contract — a verdict/evidence expert must still go
  /// through [validateAndProject], where evidence is actually adjudicated. The
  /// answer text passes the same content rules as the strict path, and no
  /// model-supplied verification or execution claim is consulted at all.
  String? projectAdviceAnswer(Object? answerValue) {
    if (profile.validationPolicy != ExpertValidationPolicy.structural) {
      return null;
    }
    final schema = profile.outputSchema;
    if (schema.fields[expertAnswerField] != OutputValueType.answerText ||
        schema.hasDirectionalEvidenceContract) {
      return null;
    }
    if (!_isValidAnswerText(answerValue)) return null;
    return answerValue! as String;
  }

  /// Returns the only structural text safe for direct user presentation.
  ///
  /// Raw model fields such as `Analysis` are deliberately excluded. Advice is
  /// rendered only from typed proposed actions; completed facts
  /// are rendered only after consuming a matching verification receipt.
  String? validateAndProject(
    Map<String, Object?> output, {
    ExpertValidationContext? context,
    VerificationReceipt? verificationReceipt,
  }) {
    final snapshot = _ExpertOutputSnapshot.tryParse(output);
    if (snapshot == null ||
        profile.validationPolicy != ExpertValidationPolicy.structural ||
        !_structuralValidator._validateSnapshot(
          snapshot,
          context: context,
          verificationReceipt: verificationReceipt,
        )) {
      return null;
    }
    final snapshotOutput = snapshot.value;
    final envelope = snapshotOutput['Verification'];
    if (envelope is! Map) return null;
    if (envelope['claimType'] == 'execution') {
      final facts = envelope['executedFacts'];
      final projected = facts is List
          ? facts.whereType<String>().join('\n')
          : '';
      return projected.isEmpty ? null : projected;
    }
    // The schema-declared natural answer is what the user reads. The typed
    // actions remain validated and available; they are only the fallback for
    // schemas that predate the answer field.
    if (profile.outputSchema.fields[expertAnswerField] ==
        OutputValueType.answerText) {
      final answer = snapshotOutput[expertAnswerField];
      if (answer is String && answer.trim().isNotEmpty) return answer;
      return null;
    }
    final actions = envelope['proposedActions'];
    final projected = actions is List
        ? actions.map(_renderProposedAction).join('\n')
        : '';
    return projected.isEmpty ? null : projected;
  }
}

/// Central authorization boundary for executable expert capabilities.
///
/// Catalog APIs expose metadata only. The private gateway binding below is
/// invoked solely for explicit launch allowlists in this registry.
@immutable
class InstalledExpertIdentity {
  const InstalledExpertIdentity({
    required this.profileId,
    required this.conversationId,
    required this.canonicalExpertId,
  });

  final String profileId;
  final String conversationId;
  final String canonicalExpertId;
}

class ExecutableExpertRegistry {
  factory ExecutableExpertRegistry({
    required ExpertOutputValidationGateway gateway,
  }) {
    final profiles = <ExpertProfile>[
      ...BuiltInExperts.all,
      ...ExpertCatalogBatchOne.all,
      ...ExpertCatalogBatchTwo.all,
    ];
    final profilesById = <String, ExpertProfile>{};
    for (final profile in profiles) {
      if (profilesById.containsKey(profile.id)) {
        throw StateError('Duplicate canonical expert ID: ${profile.id}');
      }
      profilesById[profile.id] = profile;
    }
    final installedProfileIds = <String>{};
    final installedConversationIds = <String>{};
    final installedCanonicalIds = <String>{};
    if (installedExpertIdentities.any(
      (identity) =>
          !_identifierPattern.hasMatch(identity.profileId) ||
          !_identifierPattern.hasMatch(identity.conversationId) ||
          !installedProfileIds.add(identity.profileId) ||
          !installedConversationIds.add(identity.conversationId) ||
          !installedCanonicalIds.add(identity.canonicalExpertId) ||
          !profilesById.containsKey(identity.canonicalExpertId) ||
          !_singleChatIds.contains(identity.canonicalExpertId),
    )) {
      throw StateError('Invalid installed expert identity mapping');
    }
    final authorizedIds = {..._singleChatIds, ..._groupChatIds};
    final executableById = <String, ExecutableExpert>{
      for (final id in authorizedIds)
        id: gateway._bind(
          profilesById[id] ??
              (throw StateError('Unknown authorized expert ID: $id')),
        ),
    };
    return ExecutableExpertRegistry._(
      all: List<ExpertProfile>.unmodifiable(profiles),
      profilesById: Map<String, ExpertProfile>.unmodifiable(profilesById),
      executableById: Map<String, ExecutableExpert>.unmodifiable(
        executableById,
      ),
      routingCards: Map<String, RoutingCard>.unmodifiable({
        for (final profile in profiles) profile.id: profile.routingCard,
      }),
      availableForSingleChat: _resolveRequired(executableById, _singleChatIds),
      productDeliveryGroup: _resolveRequired(
        executableById,
        _productDeliveryGroupIds,
      ),
      mobileReviewGroup: _resolveRequired(
        executableById,
        _mobileReviewGroupIds,
      ),
      availableForGroupChat: _resolveRequired(executableById, _groupChatIds),
    );
  }

  const ExecutableExpertRegistry._({
    required this.all,
    required this._profilesById,
    required this._executableById,
    required this.routingCards,
    required this.availableForSingleChat,
    required this.availableForGroupChat,
    required this.productDeliveryGroup,
    required this.mobileReviewGroup,
  });

  static const _singleChatIds = <String>[
    'halo-assistant',
    'product-manager',
    'technical-architect',
    'ux-designer',
    'project-manager',
    'qa-test-engineer',
    'ios-engineer',
    'flutter-engineer',
    'data-analyst',
    'content-strategist',
    'operations-manager',
    'legal-risk-advisor',
    'fact-checker',
    'industry-researcher',
    'fitness-planner',
  ];

  static const _productDeliveryGroupIds = <String>[
    'product-manager',
    'technical-architect',
    'ux-designer',
    'project-manager',
    'qa-test-engineer',
  ];

  static const _mobileReviewGroupIds = <String>[
    'product-manager',
    'technical-architect',
    'ios-engineer',
    'flutter-engineer',
    'qa-test-engineer',
  ];

  static const _groupChatIds = <String>[
    'product-manager',
    'technical-architect',
    'ux-designer',
    'project-manager',
    'qa-test-engineer',
    'ios-engineer',
    'flutter-engineer',
  ];

  static const marketIdMappings = <String, String>{
    'market-5': 'project-manager',
    'market-9': 'automation-engineer',
    'market-10': 'user-researcher',
    'market-11': 'industry-researcher',
    'market-15': 'fact-checker',
    'market-20': 'editor-proofreader',
    'market-24': 'localization-specialist',
    'market-27': 'data-analyst',
    'market-28': 'database-engineer',
    'market-35': 'legal-risk-advisor',
    'market-36': 'finance-tax-analyst',
  };

  /// Installed contact profiles that have an executable single-chat expert.
  static const installedExpertIdentities = <InstalledExpertIdentity>[
    InstalledExpertIdentity(
      profileId: 'general',
      conversationId: 'general-assistant',
      canonicalExpertId: 'halo-assistant',
    ),
    InstalledExpertIdentity(
      profileId: 'product',
      conversationId: 'product-manager-chat',
      canonicalExpertId: 'product-manager',
    ),
    InstalledExpertIdentity(
      profileId: 'data',
      conversationId: 'data-analyst-chat',
      canonicalExpertId: 'data-analyst',
    ),
    InstalledExpertIdentity(
      profileId: 'writing',
      conversationId: 'writing-advisor-chat',
      canonicalExpertId: 'content-strategist',
    ),
    InstalledExpertIdentity(
      profileId: 'calendar',
      conversationId: 'calendar-assistant',
      canonicalExpertId: 'operations-manager',
    ),
    InstalledExpertIdentity(
      profileId: 'contract',
      conversationId: 'contract-review-chat',
      canonicalExpertId: 'legal-risk-advisor',
    ),
    InstalledExpertIdentity(
      profileId: 'watcher',
      conversationId: 'monitoring-chat',
      canonicalExpertId: 'fact-checker',
    ),
    InstalledExpertIdentity(
      profileId: 'researcher',
      conversationId: 'deep-research-task',
      canonicalExpertId: 'industry-researcher',
    ),
    InstalledExpertIdentity(
      profileId: 'fitness',
      conversationId: 'fitness-planner-chat',
      canonicalExpertId: 'fitness-planner',
    ),
  ];

  static final Map<String, InstalledExpertIdentity>
  _installedIdentityByProfileId = Map.unmodifiable({
    for (final identity in installedExpertIdentities)
      identity.profileId: identity,
  });

  final List<ExpertProfile> all;
  final Map<String, ExpertProfile> _profilesById;
  final Map<String, ExecutableExpert> _executableById;
  final Map<String, RoutingCard> routingCards;
  final List<ExecutableExpert> availableForSingleChat;
  final List<ExecutableExpert> availableForGroupChat;
  final List<ExecutableExpert> productDeliveryGroup;
  final List<ExecutableExpert> mobileReviewGroup;

  ExpertProfile? catalogById(String canonicalExpertId) =>
      _profilesById[canonicalExpertId];

  String? canonicalIdForMarketId(String marketId) => marketIdMappings[marketId];

  InstalledExpertIdentity? installedIdentityForProfileId(
    String installedProfileId,
  ) {
    final normalized = installedProfileId == 'general-assistant'
        ? 'general'
        : installedProfileId;
    return _installedIdentityByProfileId[normalized];
  }

  ExecutableExpert? singleChatById(String canonicalExpertId) =>
      _singleChatIds.contains(canonicalExpertId)
      ? _executableById[canonicalExpertId]
      : null;

  ExecutableExpert? singleChatByMarketId(String marketId) {
    final canonicalId = canonicalIdForMarketId(marketId);
    return canonicalId == null ? null : singleChatById(canonicalId);
  }

  ExecutableExpert? groupChatById(String canonicalExpertId) =>
      _groupChatIds.contains(canonicalExpertId)
      ? _executableById[canonicalExpertId]
      : null;

  List<ExecutableExpert>? resolveTeam(String teamId) => switch (teamId) {
    'product-delivery' => productDeliveryGroup,
    'mobile-review' => mobileReviewGroup,
    _ => null,
  };
}

List<ExecutableExpert> _resolveRequired(
  Map<String, ExecutableExpert> executableById,
  List<String> canonicalIds,
) {
  final resolved = <ExecutableExpert>[];
  for (final id in canonicalIds) {
    final expert = executableById[id];
    if (expert == null) {
      throw StateError('Unknown canonical expert ID in chat policy: $id');
    }
    resolved.add(expert);
  }
  return List<ExecutableExpert>.unmodifiable(resolved);
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

/// The one reserved output key, bound to [OutputValueType.answerText].
const expertAnswerField = 'Answer';

const _maximumAnswerCharacters = 1200;

bool _isValidAnswerText(Object? value) {
  if (value is! String) return false;
  final text = value.trim();
  if (text.isEmpty || value.length > _maximumAnswerCharacters) return false;
  for (final rune in value.runes) {
    // Newlines are the only control character a chat reply needs. Bidi
    // overrides, zero-width joiners and format characters are display-layer
    // spoofing tools, not content.
    if (rune == 0x0A) continue;
    if (rune < 0x20 || (rune >= 0x7F && rune <= 0x9F)) return false;
    if (rune >= 0x200B && rune <= 0x200F) return false;
    if (rune >= 0x202A && rune <= 0x202E) return false;
    if (rune >= 0x2066 && rune <= 0x2069) return false;
    if (rune >= 0xFFF9 && rune <= 0xFFFB) return false;
  }
  return true;
}

Map<String, OutputValueType> _validatedOutputFields(
  Map<String, OutputValueType> fields,
) {
  if (fields.isEmpty) throw ArgumentError('Output fields must not be empty.');
  for (final entry in fields.entries) {
    // One reserved name, both directions: no other key may carry free text
    // through the projection boundary, and `Answer` may not be anything else.
    if ((entry.key == expertAnswerField) !=
        (entry.value == OutputValueType.answerText)) {
      throw ArgumentError(
        "Field '$expertAnswerField' must be answerText and answerText must be "
        "'$expertAnswerField'.",
      );
    }
  }
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

bool _isValidVerificationEnvelope(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) return false;
  const expectedKeys = {
    'claimType',
    'tense',
    'verified',
    'source',
    'proposedActions',
    'executedFacts',
  };
  final keys = value.keys.toSet();
  if (!keys.containsAll(expectedKeys) ||
      keys.difference(expectedKeys).isNotEmpty) {
    return false;
  }
  final claimType = value['claimType'];
  final tense = value['tense'];
  final verified = value['verified'];
  final source = value['source'];
  final proposedActions = value['proposedActions'];
  final executedFacts = value['executedFacts'];
  if (verified is! bool ||
      source is! String ||
      source.trim().isEmpty ||
      !_isValidProposedActionList(proposedActions) ||
      executedFacts is! List ||
      executedFacts.any((item) => item is! String || item.trim().isEmpty)) {
    return false;
  }
  if (claimType == 'advice' && tense == 'proposed') {
    return !verified &&
        source == 'none' &&
        (proposedActions as List).isNotEmpty &&
        executedFacts.isEmpty;
  }
  if (claimType == 'execution' && tense == 'completed') {
    return verified &&
        source != 'none' &&
        (proposedActions as List).isEmpty &&
        executedFacts.isNotEmpty;
  }
  return false;
}

const _proposedActionVerbs = {
  'analyze',
  'compare',
  'document',
  'implement',
  'measure',
  'plan',
  'query',
  'review',
  'test',
  'train',
  'verify',
};

bool _isValidProposedActionList(Object? value) =>
    value is List &&
    value.every((item) {
      if (item is! Map || item.keys.any((key) => key is! String)) return false;
      const expectedKeys = {'verb', 'target', 'conditions'};
      final keys = item.keys.toSet();
      if (!keys.containsAll(expectedKeys) ||
          keys.difference(expectedKeys).isNotEmpty) {
        return false;
      }
      final verb = item['verb'];
      final target = item['target'];
      final conditions = item['conditions'];
      return verb is String &&
          _proposedActionVerbs.contains(verb) &&
          target is String &&
          _identifierPattern.hasMatch(target) &&
          conditions is List &&
          conditions.every(
            (condition) =>
                condition is String && _identifierPattern.hasMatch(condition),
          );
    });

String _renderProposedAction(Object? raw) {
  final action = raw as Map;
  final verb = action['verb'] as String;
  final target = action['target'] as String;
  final conditions = (action['conditions'] as List).cast<String>();
  final conditionClause = conditions.isEmpty
      ? ''
      : ' when ${conditions.join(' and ')}';
  return 'Proposed action: $verb $target$conditionClause.';
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

class _ExpertOutputSnapshot {
  const _ExpertOutputSnapshot._(this.value, this.digest);

  static _ExpertOutputSnapshot? tryParse(Map<String, Object?> raw) {
    try {
      final parsed = _deepSnapshotJson(raw);
      if (parsed is! Map<String, Object?>) return null;
      final canonicalJson = jsonEncode(_canonicalJsonValue(parsed));
      return _ExpertOutputSnapshot._(
        parsed,
        sha256.convert(utf8.encode(canonicalJson)).toString(),
      );
    } on Object {
      return null;
    }
  }

  final Map<String, Object?> value;
  final String digest;
}

Object? _deepSnapshotJson(Object? raw) {
  if (raw == null || raw is String || raw is num || raw is bool) return raw;
  if (raw is EvidenceItem) return _deepSnapshotJson(raw.toJson());
  if (raw is Map) {
    final parsed = <String, Object?>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      if (key is! String || parsed.containsKey(key)) {
        throw const FormatException('Invalid JSON object key.');
      }
      parsed[key] = _deepSnapshotJson(entry.value);
    }
    return Map<String, Object?>.unmodifiable(parsed);
  }
  if (raw is List) {
    return List<Object?>.unmodifiable(raw.map(_deepSnapshotJson));
  }
  throw const FormatException('Unsupported JSON value.');
}

String expertOutputDigestFor(Map<String, Object?> output) {
  final snapshot = _ExpertOutputSnapshot.tryParse(output);
  if (snapshot == null) {
    throw ArgumentError.value(output, 'output', 'Must be canonical JSON.');
  }
  return snapshot.digest;
}

String _verificationBinding({
  required String expertId,
  required String schemaId,
  required int profileVersion,
  required String audience,
  required String outputDigest,
  required String source,
}) => jsonEncode([
  expertId,
  schemaId,
  profileVersion,
  audience,
  outputDigest,
  source,
]);

Object? _canonicalJsonValue(Object? value) {
  if (value is EvidenceItem) return _canonicalJsonValue(value.toJson());
  if (value is Map) {
    final keys =
        value.keys
            .whereType<String>()
            .where((key) => key != 'receiptId' && key != 'receiptToken')
            .toList()
          ..sort();
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
