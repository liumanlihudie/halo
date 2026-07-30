import 'expert_prompt_package.dart';

class ExpertEvaluationAssertions {
  const ExpertEvaluationAssertions({
    this.expectedRoutingOutcome,
    this.expectedOutputAccepted,
    this.requiredGuards = const {},
    this.expectedToolDecisions = const {},
  });

  final RoutingOutcome? expectedRoutingOutcome;
  final bool? expectedOutputAccepted;
  final Set<PromptGuard> requiredGuards;
  final Map<String, ToolDecision> expectedToolDecisions;

  bool get hasAssertions =>
      expectedRoutingOutcome != null ||
      expectedOutputAccepted != null ||
      requiredGuards.isNotEmpty ||
      expectedToolDecisions.isNotEmpty;
}

class ExpertEvaluationScenario {
  const ExpertEvaluationScenario({
    required this.id,
    required this.expertId,
    required this.input,
    required this.assertions,
    this.candidateOutput,
    this.validationContext,
  });

  final String id;
  final String expertId;
  final String input;
  final Map<String, Object?>? candidateOutput;
  final ExpertValidationContext? validationContext;
  final ExpertEvaluationAssertions assertions;
}

class ExpertEvaluationTarget {
  ExpertEvaluationTarget.fromProfile(ExpertProfile profile)
    : id = profile.id,
      promptPackage = profile.promptPackage,
      routingCard = profile.routingCard,
      toolPolicy = profile.toolPolicy,
      outputSchema = profile.outputSchema,
      validationPolicy = profile.validationPolicy;

  final String id;
  final PromptPackage promptPackage;
  final RoutingCard routingCard;
  final ToolPolicy toolPolicy;
  final OutputSchema outputSchema;
  final ExpertValidationPolicy validationPolicy;
}

class ExpertCatalogEvaluationObservation {
  ExpertCatalogEvaluationObservation({
    required this.routingOutcome,
    required this.rawResponse,
    required Set<String> trace,
  }) : trace = Set<String>.unmodifiable(trace);

  final RoutingOutcome routingOutcome;
  final String rawResponse;
  final Set<String> trace;
}

abstract interface class ExpertCatalogEvaluationDriver {
  ExpertCatalogEvaluationObservation execute(
    ExpertEvaluationTarget target, {
    required String scenarioId,
    required String input,
  });
}

abstract interface class ExpertCatalogEvaluationScorer {
  bool expectedBehaviorSatisfied({
    required ExpertProfile profile,
    required EvaluationCase evaluationCase,
    required ExpertCatalogEvaluationObservation observation,
    required String behavior,
  });

  bool forbiddenBehaviorObserved({
    required ExpertProfile profile,
    required EvaluationCase evaluationCase,
    required ExpertCatalogEvaluationObservation observation,
    required String behavior,
  });
}

class ExpertEvaluationReport {
  ExpertEvaluationReport({
    required this.scenarioCount,
    required List<String> failures,
    required Set<String> evaluatedExpertIds,
    this.behaviorAssertionCount = 0,
  }) : failures = List<String>.unmodifiable(failures),
       evaluatedExpertIds = Set<String>.unmodifiable(evaluatedExpertIds);

  final int scenarioCount;
  final List<String> failures;
  final Set<String> evaluatedExpertIds;
  final int behaviorAssertionCount;

  bool get passed => failures.isEmpty;
}

/// Executes deterministic expert contract assertions without invoking a model.
class ExpertEvaluationRunner {
  const ExpertEvaluationRunner({
    required this.registry,
    this.catalogDriver,
    this.catalogScorer = const OfflineExpertContractScorer(),
  });

  final ExecutableExpertRegistry registry;
  final ExpertCatalogEvaluationDriver? catalogDriver;
  final ExpertCatalogEvaluationScorer catalogScorer;

  ExpertEvaluationReport runAll(Iterable<ExpertEvaluationScenario> scenarios) {
    final suite = scenarios.toList(growable: false);
    if (suite.isEmpty) {
      throw ArgumentError('Evaluation suite must not be empty.');
    }
    final scenarioIds = <String>{};
    for (final scenario in suite) {
      if (!_scenarioIdPattern.hasMatch(scenario.id)) {
        throw ArgumentError.value(scenario.id, 'scenario.id');
      }
      if (!_expertIdPattern.hasMatch(scenario.expertId)) {
        throw ArgumentError.value(scenario.expertId, 'scenario.expertId');
      }
      if (!scenarioIds.add(scenario.id)) {
        throw ArgumentError('Duplicate evaluation scenario ID: ${scenario.id}');
      }
      if (!scenario.assertions.hasAssertions) {
        throw ArgumentError(
          '${scenario.id}: at least one assertion is required.',
        );
      }
      final hasCandidate = scenario.candidateOutput != null;
      final hasExpectedAcceptance =
          scenario.assertions.expectedOutputAccepted != null;
      if (hasCandidate != hasExpectedAcceptance) {
        throw ArgumentError(
          '${scenario.id}: candidateOutput and expectedOutputAccepted '
          'must be provided together.',
        );
      }
    }

    final failures = <String>[];
    final evaluatedExpertIds = <String>{};
    for (final scenario in suite) {
      final profile = registry.catalogById(scenario.expertId);
      if (profile == null) {
        failures.add('${scenario.id}: unknown expert ${scenario.expertId}');
        continue;
      }
      evaluatedExpertIds.add(profile.id);
      final assertions = scenario.assertions;
      final expectedRoute = assertions.expectedRoutingOutcome;
      if (expectedRoute != null) {
        final actual = profile.routingCard.evaluate(scenario.input);
        if (actual != expectedRoute) {
          failures.add(
            '${scenario.id}: routing was ${actual.name}, '
            'expected ${expectedRoute.name}',
          );
        }
      }
      if (!profile.promptPackage.guards.containsAll(
        assertions.requiredGuards,
      )) {
        failures.add('${scenario.id}: required prompt guards are missing');
      }
      for (final entry in assertions.expectedToolDecisions.entries) {
        final actual = profile.toolPolicy.decisionFor(entry.key);
        if (actual != entry.value) {
          failures.add(
            '${scenario.id}: ${entry.key} was ${actual.name}, '
            'expected ${entry.value.name}',
          );
        }
      }
      final expectedAccepted = assertions.expectedOutputAccepted;
      if (expectedAccepted != null) {
        final output = scenario.candidateOutput;
        if (output == null) {
          failures.add('${scenario.id}: candidate output is required');
        } else {
          final executable =
              registry.singleChatById(profile.id) ??
              registry.groupChatById(profile.id);
          final actual = executable?.preflightOutput(output) ?? false;
          if (actual != expectedAccepted) {
            failures.add(
              '${scenario.id}: output acceptance was $actual, '
              'expected $expectedAccepted',
            );
          }
        }
      }
    }
    return ExpertEvaluationReport(
      scenarioCount: suite.length,
      failures: failures,
      evaluatedExpertIds: evaluatedExpertIds,
    );
  }

  ExpertEvaluationReport runCatalogEvaluationCases() {
    final driver = catalogDriver;
    if (driver == null) {
      throw StateError(
        'A catalog evaluation driver is required to execute behaviors.',
      );
    }
    final failures = <String>[];
    final evaluatedExpertIds = <String>{};
    var scenarioCount = 0;
    var behaviorAssertionCount = 0;
    for (final profile in registry.all) {
      final target = ExpertEvaluationTarget.fromProfile(profile);
      evaluatedExpertIds.add(profile.id);
      for (final evaluationCase in profile.evaluationCases) {
        scenarioCount++;
        final scenarioId = '${profile.id}.${evaluationCase.id}';
        final observation = driver.execute(
          target,
          scenarioId: scenarioId,
          input: evaluationCase.input,
        );
        final expectedRoute = evaluationCase.shouldRoute
            ? RoutingOutcome.match
            : RoutingOutcome.noMatch;
        if (observation.routingOutcome != expectedRoute) {
          failures.add(
            '$scenarioId: routing was ${observation.routingOutcome.name}, '
            'expected ${expectedRoute.name}',
          );
        }
        for (final behavior in evaluationCase.expectedBehaviors) {
          behaviorAssertionCount++;
          if (!catalogScorer.expectedBehaviorSatisfied(
            profile: profile,
            evaluationCase: evaluationCase,
            observation: observation,
            behavior: behavior,
          )) {
            failures.add('$scenarioId: missing expected behavior: $behavior');
          }
        }
        for (final behavior in evaluationCase.forbiddenBehaviors) {
          behaviorAssertionCount++;
          if (catalogScorer.forbiddenBehaviorObserved(
            profile: profile,
            evaluationCase: evaluationCase,
            observation: observation,
            behavior: behavior,
          )) {
            failures.add('$scenarioId: observed forbidden behavior: $behavior');
          }
        }
      }
    }
    return ExpertEvaluationReport(
      scenarioCount: scenarioCount,
      failures: failures,
      evaluatedExpertIds: evaluatedExpertIds,
      behaviorAssertionCount: behaviorAssertionCount,
    );
  }
}

/// Deterministic offline scorer for routing, prompt, policy, and projection
/// contracts. It deliberately does not claim to measure live model quality.
class OfflineExpertContractScorer implements ExpertCatalogEvaluationScorer {
  const OfflineExpertContractScorer();

  @override
  bool expectedBehaviorSatisfied({
    required ExpertProfile profile,
    required EvaluationCase evaluationCase,
    required ExpertCatalogEvaluationObservation observation,
    required String behavior,
  }) {
    if (!evaluationCase.shouldRoute) {
      return observation.routingOutcome == RoutingOutcome.noMatch;
    }
    if (observation.routingOutcome != RoutingOutcome.match ||
        observation.rawResponse.trim().isEmpty ||
        !observation.trace.contains('prompt.loaded')) {
      return false;
    }
    if (observation.trace.contains('projection.required') &&
        !observation.trace.contains('projection.accepted')) {
      return false;
    }
    final normalized = behavior.toLowerCase();
    if (_mentionsEvidenceBoundary(normalized) &&
        !observation.trace.contains('guard.evidenceBoundaries')) {
      return false;
    }
    if (_mentionsFabrication(normalized) &&
        !observation.trace.contains('guard.noFabrication')) {
      return false;
    }
    return observation.trace.contains('guard.roleIntegrity');
  }

  @override
  bool forbiddenBehaviorObserved({
    required ExpertProfile profile,
    required EvaluationCase evaluationCase,
    required ExpertCatalogEvaluationObservation observation,
    required String behavior,
  }) {
    if (observation.rawResponse.contains(behavior)) return true;
    final normalized = behavior.toLowerCase();
    if (_mentionsFabrication(normalized)) {
      return !observation.trace.contains('guard.noFabrication');
    }
    if (_mentionsExternalExecution(normalized)) {
      return !observation.trace.contains('tool.production.write.denied') ||
          !observation.trace.contains('tool.shell.execute.denied');
    }
    return !observation.trace.contains('guard.roleIntegrity');
  }
}

bool _mentionsEvidenceBoundary(String value) =>
    value.contains('evidence') ||
    value.contains('source') ||
    value.contains('verification') ||
    value.contains('observed') ||
    value.contains('measured');

bool _mentionsFabrication(String value) =>
    value.contains('invent') ||
    value.contains('fabricat') ||
    value.contains('unsupported') ||
    value.contains('unobserved');

bool _mentionsExternalExecution(String value) =>
    value.contains('execute') ||
    value.contains('deploy') ||
    value.contains('production') ||
    value.contains('credentials') ||
    value.contains('generate implementation code');

final _scenarioIdPattern = RegExp(r'^[a-z][a-z0-9._-]{2,127}$');
final _expertIdPattern = RegExp(r'^[a-z][a-z0-9._-]{2,63}$');
