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
#   fatal    … 明らかに設定・上限の問題で失敗した。自動リトライを止める
#              (修正後、ワークフローを手動実行して force=true にすると再開できる)
#   rate_limited … ジョブ作成が OCI のレート制限 (429) のため見送り。今回の実行は
#              正常終了とし、次回の実行で再挑戦する (v3 で追加)
#
# 失敗理由の判定について (v2 での修正点):
#   初版は get-job-logs の先頭ページだけを見ていたため、ログ末尾にある
#   "Out of host capacity" を見落として fatal と誤判定していた。
#   v2 では get-job-logs-content (生ログ全文、最大 100,000 件) で判定する。
#   また、容量不足でも設定ミスでもない「判定できない失敗」は、
#   容量狙いの用途を優先してリトライを続ける (誤って止まる方が痛いため)。
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
  local attempt out new_id
  for attempt in 1 2 3; do
    if out=$(oci resource-manager job create-apply-job \
      --stack-id "$STACK_ID" \
      --execution-plan-strategy AUTO_APPROVED \
      --query data.id --raw-output 2>&1); then
      new_id="$out"
      echo "Started new apply job: $new_id"
      emit status started
      emit job_id "$new_id"
      return 0
    fi
    echo "create-apply-job attempt $attempt failed:"
    echo "$out"
    if echo "$out" | grep -qiE "TooManyRequests|status.: 429"; then
      if [ "$attempt" -lt 3 ]; then
        echo "Rate limited by OCI (429). Waiting 60s and retrying inside this run..."
        sleep 60
        continue
      fi
      echo "Still rate limited after all retries. Ending this run quietly; the next run will try again."
      emit status rate_limited
      return 0
    fi
    # 429 以外のエラーは従来どおり失敗として扱う
    return 1
  done
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
    # 失敗理由を「生ログ全文」で判定する (先頭ページだけでは末尾のエラーを見落とす)
    LOG_TEXT=$(oci resource-manager job get-job-logs-content --job-id "$JOB_ID" 2>/dev/null || true)
    if [ -z "${LOG_TEXT:-}" ]; then
      LOG_TEXT=$(oci resource-manager job get-job-logs --job-id "$JOB_ID" --all 2>/dev/null || true)
    fi
    echo "Fetched job log: ${#LOG_TEXT} chars"

    if echo "$LOG_TEXT" | grep -qi "out of host capacity"; then
      echo "Previous failure: out of host capacity. Retrying."
      emit previous_failure capacity
      start_apply
    elif echo "$LOG_TEXT" | grep -qiE "LimitExceeded|InvalidParameter|InvalidArgument|MissingParameter"; then
      if [ "$FORCE" = "true" ]; then
        echo "Previous failure looks like a config/limit problem, but force=true. Retrying anyway."
        emit previous_failure fatal_but_forced
        start_apply
      else
        echo "Previous failure looks like a config/limit problem. Not retrying automatically."
        echo "$LOG_TEXT" | tail -c 1500 > fatal_detail.txt || true
        emit status fatal
        emit job_id "$JOB_ID"
      fi
    elif [ "$FORCE" = "true" ]; then
      echo "Previous failure could not be classified, and force=true. Retrying."
      emit previous_failure unknown
      start_apply
    else
      echo "Previous failure could not be classified. Retrying anyway (capacity hunting takes priority)."
      emit previous_failure unknown
      start_apply
    fi
    ;;
  *)
    echo "Unknown state: $STATE"
    emit status waiting
    ;;
esac
