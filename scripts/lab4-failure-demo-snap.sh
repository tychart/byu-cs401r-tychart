#!/usr/bin/env bash
# Snapshot the four things the Lab 4 failure demo has to compare: which build
# ran on which commit and where it stopped, what the Model Registry holds, what
# the build-failure alarm is doing, and whether the alarm has a confirmed
# subscriber.
#
# This is the handout's `snap` shell function, moved into a script for one
# reason: the demo spans three separate pushes several minutes apart, and a
# function defined in one interactive shell is not available in the next one.
# The output format is unchanged -- the TA reads `docs/lab4-failure-demo.txt`
# and expects the labelled sections.
#
# Usage:  bash scripts/lab4-failure-demo-snap.sh "BEFORE"
#
# Appends (never truncates). Delete the file first if you want a clean rerun:
#   rm -f docs/lab4-failure-demo.txt

set -uo pipefail

LABEL="${1:?usage: $0 <LABEL>   e.g. \"BEFORE\" | \"AFTER FAILED RUN\" | \"AFTER REVERT\"}"
OUT="docs/lab4-failure-demo.txt"
STACK="northstar-cicd"
CI_PROJECT="northstar-ci"
PIPELINE="northstar-pipeline"
SM_PIPELINE="northstar-churn-pipeline"
GROUP="northstar-churn-models"
ALARM="northstar-ci-build-failure"

if [ ! -d docs ]; then
  echo "Run this from the repository root (docs/ not found)." >&2
  exit 1
fi

TOPIC=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ModelApprovalTopicArn'].OutputValue" --output text)

# A failed AWS call must leave a visible marker, not a blank line that reads as
# "nothing to report". Every block below is wrapped so an error is recorded as an
# error.
run() { "$@" 2>&1 || echo "    <ERROR: $* failed>"; }

{
  echo
  echo "===== $LABEL  ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ====="

  echo "--- newest CodeBuild build: id, commit, status, then phases"
  B=$(aws codebuild list-builds-for-project --project-name "$CI_PROJECT" --query 'ids[0]' --output text 2>/dev/null)
  if [ -n "$B" ]; then
    run aws codebuild batch-get-builds --ids "$B" \
      --query 'builds[0].[id,resolvedSourceVersion,buildStatus]' --output text
    run aws codebuild batch-get-builds --ids "$B" \
      --query 'builds[0].phases[].[phaseType,phaseStatus]' --output text
  else
    echo "    <ERROR: could not list builds for $CI_PROJECT>"
  fi

  echo "--- newest 3 model packages"
  run aws sagemaker list-model-packages --model-package-group-name "$GROUP" \
    --sort-by CreationTime --sort-order Descending --max-results 3 \
    --query 'ModelPackageSummaryList[].[ModelPackageVersion,ModelApprovalStatus,CreationTime]' --output text

  echo "--- alarm state"
  run aws cloudwatch describe-alarms --alarm-names "$ALARM" \
    --query 'MetricAlarms[0].[StateValue,StateUpdatedTimestamp]' --output text

  echo "--- alarm action history"
  run aws cloudwatch describe-alarm-history --alarm-name "$ALARM" \
    --history-item-type Action --max-records 5 \
    --query 'AlarmHistoryItems[].[Timestamp,HistorySummary]' --output text

  echo "--- SNS subscriptions (an ARN, not PendingConfirmation)"
  if [ -n "$TOPIC" ] && [ "$TOPIC" != "None" ]; then
    run aws sns list-subscriptions-by-topic --topic-arn "$TOPIC" \
      --query 'Subscriptions[].[Protocol,SubscriptionArn]' --output text
  else
    echo "    <ERROR: ModelApprovalTopicArn output not found on stack $STACK>"
  fi

  echo "--- pipeline executions (newest 3)"
  run aws codepipeline list-pipeline-executions --pipeline-name "$PIPELINE" --max-results 3 \
    --query 'pipelineExecutionSummaries[].[status,sourceRevisions[0].revisionId,pipelineExecutionId]' --output text

  echo "--- SageMaker pipeline executions (newest 3)"
  run aws sagemaker list-pipeline-executions --pipeline-name "$SM_PIPELINE" --max-results 3 \
    --query 'PipelineExecutionSummaries[].[StartTime,PipelineExecutionStatus,PipelineExecutionDisplayName]' --output text
} | tee -a "$OUT"
