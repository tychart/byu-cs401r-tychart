#!/usr/bin/env bash
# run_sagemaker_pipeline.sh
#
# Start the NorthStar SageMaker Pipeline and wait for it, trying an ordered
# ladder of training instance types.
#
# WHY THIS EXISTS (2026-10-30)
# The handout assumes `ml.m5.large` on managed spot has a default quota of 4.
# On this account the APPLIED quota for every CPU training type is 0 while the
# AWS default is 4 (verified: L-29688C85 applied=0, default=4), and the quota
# increase is a support case with an unknown turnaround. A build that starts
# the pipeline once with ml.m5.large therefore fails with ResourceLimitExceeded
# and never trains — which would block the whole lab on an AWS ticket.
#
# The GPU types are the only families with non-zero spot training quota on this
# account (ml.g5/g6/g7 *.xlarge = 1 each). They also vary in whether spot
# capacity is available at any given moment: g5.xlarge, g6.xlarge and
# g5.2xlarge all returned "Insufficient capacity ... retrying" on 2026-10-30,
# while g6.2xlarge launched immediately.
#
# So: try the handout's type first (it becomes the cheapest option the moment
# the quota case is approved), then fall through when the failure is a quota or
# capacity failure. A genuine training error (AlgorithmError, a failed gate)
# is NOT retried — retrying it would only hide the real failure.
#
# Inputs (environment, all optional except COMMIT_SHA):
#   PIPELINE_NAME            default northstar-churn-pipeline
#   COMMIT_SHA               the commit being built
#   TRAINING_INSTANCE_TYPES  comma-separated ladder, tried in order
#   MAX_WAIT                 seconds per attempt, default 2700 (buildspec's 45m)
#   POLL_INTERVAL            seconds between polls, default 20
#   STALL_SECONDS            how long a job may sit in "Insufficient capacity"
#                            before we stop it and try the next type, default 300
#
# Outputs (paths the buildspec already reads):
#   /tmp/pipeline_execution_arn.txt  ARN of the successful execution
#   /tmp/model_package_arn.txt       ARN of the package it registered
#
# Exit: 0 when an execution succeeds, 1 when every type failed.
set -uo pipefail

PIPELINE_NAME="${PIPELINE_NAME:-northstar-churn-pipeline}"
COMMIT_SHA="${COMMIT_SHA:-unknown}"
TRAINING_INSTANCE_TYPES="${TRAINING_INSTANCE_TYPES:-ml.m5.large,ml.g6.2xlarge,ml.g5.2xlarge,ml.g6.xlarge,ml.g5.xlarge}"
MAX_WAIT="${MAX_WAIT:-2700}"
POLL_INTERVAL="${POLL_INTERVAL:-20}"
STALL_SECONDS="${STALL_SECONDS:-300}"
REGION="${AWS_REGION:-us-east-1}"

log() { echo "[pipeline] $*"; }

training_job_name() {  # $1 = execution arn
  aws sagemaker list-pipeline-execution-steps \
    --pipeline-execution-arn "$1" --region "$REGION" \
    --query "PipelineExecutionSteps[?StepName=='TrainChurnModel'].Metadata.TrainingJob.Arn" \
    --output text 2>/dev/null | awk -F/ 'NF{print $NF}' | grep -v '^None$' | head -1
}

execution_status() {  # $1 = execution arn
  aws sagemaker describe-pipeline-execution \
    --pipeline-execution-arn "$1" --region "$REGION" \
    --query PipelineExecutionStatus --output text 2>/dev/null
}

failure_text() {  # $1 = execution arn; concatenates pipeline/step/job reasons
  local tj reason
  {
    aws sagemaker describe-pipeline-execution --pipeline-execution-arn "$1" \
      --region "$REGION" --query FailureReason --output text 2>/dev/null || true
    aws sagemaker list-pipeline-execution-steps --pipeline-execution-arn "$1" \
      --region "$REGION" \
      --query 'PipelineExecutionSteps[?StepStatus==`Failed`].FailureReason' \
      --output text 2>/dev/null || true
  }
  # A quota failure happens inside CreateTrainingJob, so NO training job is
  # created (measured 2026-10-30) and the reason exists only on the step.
  tj=$(training_job_name "$1")
  if [ -n "$tj" ]; then
    reason=$(aws sagemaker describe-training-job --training-job-name "$tj" \
      --region "$REGION" --query FailureReason --output text 2>/dev/null || true)
    echo "$reason"
  fi
}

# A failure is retryable only when the job never got an instance: quota 0 or no
# spot capacity. Anything else is the model's problem and must fail loudly.
is_retryable_failure() {  # $1 = execution arn
  local text
  text=$(failure_text "$1")
  log "failure: $(echo "$text" | tr '\n' ' ' | cut -c1-400)"
  if echo "$text" | grep -qiE 'service limit|ResourceLimitExceeded|Insufficient capacity|capacity error'; then
    return 0
  fi
  return 1
}

try_instance_type() {  # $1 = instance type; prints outcome: success|retry|fatal
  local it="$1" exec_arn status elapsed=0 ice_since=0 now tj status_line
  log "starting execution with TrainingInstanceType=${it}"
  exec_arn=$(aws sagemaker start-pipeline-execution \
      --pipeline-name "$PIPELINE_NAME" \
      --pipeline-execution-display-name "codebuild-${COMMIT_SHA}-${it##*.}-$(date -u +%H%M%S)" \
      --pipeline-parameters "Name=CommitSha,Value=${COMMIT_SHA}" \
                           "Name=TrainingInstanceType,Value=${it}" \
      --region "$REGION" --query PipelineExecutionArn --output text 2>&1)
  if [ $? -ne 0 ] || [ -z "$exec_arn" ]; then
    log "start-pipeline-execution failed: ${exec_arn}"
    return 2   # fatal: this is a definition/IAM problem, not capacity
  fi
  log "execution: ${exec_arn}"
  echo "$exec_arn" > /tmp/pipeline_execution_arn.txt

  while true; do
    status=$(execution_status "$exec_arn")
    log "[${elapsed}s] ${it}: pipeline ${status:-<unknown>}"

    case "$status" in
      Succeeded)
        return 0
        ;;
      Failed|Stopped)
        if is_retryable_failure "$exec_arn"; then
          return 1
        fi
        log "execution ${status} for a non-capacity reason; not retrying"
        return 2
        ;;
    esac

    # Still running: detect a job stuck waiting for spot capacity. SageMaker
    # retries such a job for up to max_wait (3600s), which would consume the
    # whole build. We would rather move to another instance type after
    # STALL_SECONDS than sit here.
    tj=$(training_job_name "$exec_arn")
    if [ -n "$tj" ]; then
      status_line=$(aws sagemaker describe-training-job --training-job-name "$tj" \
        --region "$REGION" \
        --query '[TrainingJobStatus,SecondaryStatus,TrainingStartTime]' --output text 2>/dev/null)
      tj_status=$(echo "$status_line" | awk '{print $1}')
      tj_secondary=$(echo "$status_line" | awk '{print $2}')
      tj_start=$(echo "$status_line" | awk '{print $3}')
      if [ "$tj_status" = "InProgress" ] && [ "$tj_start" = "None" ] \
         && [ "$tj_secondary" = "Starting" ] \
         && aws sagemaker describe-training-job --training-job-name "$tj" \
              --region "$REGION" \
              --query 'SecondaryStatusTransitions[-1].StatusMessage' --output text 2>/dev/null \
              | grep -qi "insufficient capacity"; then
        if [ "$ice_since" = "0" ]; then ice_since=$elapsed; fi
        if [ $((elapsed - ice_since)) -ge "$STALL_SECONDS" ]; then
          log "${it}: stuck waiting for spot capacity for $((elapsed - ice_since))s; trying next type"
          aws sagemaker stop-pipeline-execution --pipeline-execution-arn "$exec_arn" \
            --region "$REGION" >/dev/null 2>&1 || true
          return 1
        fi
      else
        ice_since=0
      fi
    fi

    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
      log "${it}: timed out after ${MAX_WAIT}s"
      aws sagemaker stop-pipeline-execution --pipeline-execution-arn "$exec_arn" \
        --region "$REGION" >/dev/null 2>&1 || true
      return 2
    fi

    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
}

main() {
  local it outcome tried=""
  IFS=',' read -r -a TYPES <<< "$TRAINING_INSTANCE_TYPES"

  for it in "${TYPES[@]}"; do
    it=$(echo "$it" | tr -d ' ')
    [ -z "$it" ] && continue
    tried="${tried}${tried:+, }${it}"
    try_instance_type "$it"
    outcome=$?
    case "$outcome" in
      0)
        log "succeeded with ${it}"
        break
        ;;
      1)
        log "${it}: retryable (quota or spot capacity); falling through"
        continue
        ;;
      *)
        log "${it}: fatal failure; aborting rather than masking it"
        exit 1
        ;;
    esac
  done

  if [ "${outcome:-2}" -ne 0 ]; then
    log "every instance type failed: ${tried}"
    log "check the latest training job under /aws/sagemaker/TrainingJobs"
    exit 1
  fi

  # Record the package this run registered. post_build rejects it if anything
  # after this point fails.
  local exec_arn
  exec_arn=$(cat /tmp/pipeline_execution_arn.txt)
  aws sagemaker list-pipeline-execution-steps \
    --pipeline-execution-arn "$exec_arn" --region "$REGION" \
    --query "PipelineExecutionSteps[?starts_with(StepName,'RegisterChurnModel')].Metadata.RegisterModel.Arn" \
    --output text > /tmp/model_package_arn.txt
  log "registered: $(cat /tmp/model_package_arn.txt)"
}

main "$@"
