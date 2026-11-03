#!/usr/bin/env bash
# GitHub Actions から 15 分おきに呼ばれる想定の「確認して、必要なら適用を開始する」スクリプト。
#
# GitHub Actions の無料枠 (プライベートリポジトリ 2,000 分/月) を節約するため、
# 適用ジョブの完了を待たずに「開始だけして終わる」設計にしている。
# 次回以降の実行が、前回開始したジョブの状態を確認する。
#
# 出力 (status):
#   success  … 最新の適用ジョブが SUCCEEDED (ワークフロー側で通知 + スケジュール無効化)
#   waiting  … 適用ジョブが実行中。前回分が終わるまで何もしない
#   started  … 新しい適用ジョブを開始した
#   capacity … 前回は容量不足で失敗。今回は新しい適用を開始した (started と同時に出力される場合あり)
#   fatal    … 容量不足以外の失敗。設定ミスの可能性が高いので新規適用は開始しない
#              (修正後、ワークフローを手動実行して force=true にすると再開できる)
#
# 必要な環境変数: OCI_STACK_ID, FORCE (true/false, 任意)

set -euo pipefail

STACK_ID="${OCI_STACK_ID:?OCI_STACK_ID is not set}"
FORCE="${FORCE:-false}"

emit() {
  echo "$1=$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >> "$GITHUB_OUTPUT"
  fi
}

start_apply() {
  local new_id
  new_id=$(oci resource-manager job create-apply-job \
    --stack-id "$STACK_ID" \
    --execution-plan-strategy AUTO_APPROVED \
    --query data.id --raw-output)
  echo "Started new apply job: $new_id"
  emit status started
  emit job_id "$new_id"
}

# 最新の APPLY ジョブを取得 (デフォルトで作成日時の降順)
JOBS_JSON=$(oci resource-manager job list --stack-id "$STACK_ID" --limit 20)
LATEST=$(echo "$JOBS_JSON" | jq -c '[.data[] | select(.operation=="APPLY")] | first // empty' || true)

if [ -z "${LATEST:-}" ] || [ "$LATEST" = "null" ]; then
  echo "No previous apply job found."
  start_apply
  exit 0
fi

STATE=$(echo "$LATEST" | jq -r '."lifecycle-state"')
JOB_ID=$(echo "$LATEST" | jq -r '.id')
echo "Latest apply job: $JOB_ID ($STATE)"

case "$STATE" in
  SUCCEEDED)
    emit status success
    emit job_id "$JOB_ID"
    ;;
  IN_PROGRESS|ACCEPTED|CANCELING)
    emit status waiting
    emit job_id "$JOB_ID"
    ;;
  FAILED|CANCELED)
    # 失敗理由を確認する (ログ全体から容量不足かどうかを判定)
    LOG_TEXT=$(oci resource-manager job get-job-logs --job-id "$JOB_ID" 2>/dev/null || echo "")
    if echo "$LOG_TEXT" | grep -qi "Out of host capacity"; then
      echo "Previous failure: out of host capacity. Retrying."
      emit previous_failure capacity
      start_apply
    elif [ "$FORCE" = "true" ]; then
      echo "Previous failure was not capacity, but force=true. Retrying anyway."
      emit previous_failure other
      start_apply
    else
      echo "Previous failure was NOT capacity-related. Not retrying automatically."
      echo "$LOG_TEXT" | tail -c 1500 > fatal_detail.txt || true
      emit status fatal
      emit job_id "$JOB_ID"
    fi
    ;;
  *)
    echo "Unknown state: $STATE"
    emit status waiting
    ;;
esac
