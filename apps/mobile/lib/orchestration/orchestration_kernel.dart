import 'package:halo_mobile/orchestration/orchestration_models.dart';

abstract interface class OrchestrationKernel {
  Future<RunHandle> startRun(StartConversationRunCommand command);

  Stream<OrchestrationEvent> watchRun(String runId, {int afterSeq = 0});

  Future<void> requestStop(String runId);

  Future<ResumeResult> resumeRun(String runId);

  Future<RunSnapshot> getRun(String runId);
}
