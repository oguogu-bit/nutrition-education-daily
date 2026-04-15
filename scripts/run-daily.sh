#!/bin/bash
# 栄養教育デイリーノート — 自動生成スクリプト
# 毎朝7時にlaunchdから実行される

set -euo pipefail

# PATHを明示的に設定（launchd環境用）
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# launchd環境ではUSER/LOGNAMEが未設定の場合があるので補完
export USER="${USER:-$(id -un)}"
export LOGNAME="${LOGNAME:-$USER}"
export HOME="${HOME:-/Users/$USER}"

# DATE_OVERRIDE が指定された場合はそちらを使用（バックフィル用）
if [ -n "${DATE_OVERRIDE:-}" ]; then
  TODAY="$DATE_OVERRIDE"
  YEAR="${TODAY:0:4}"
  MONTH="${TODAY:5:2}"
else
  TODAY=$(date +%Y-%m-%d)
  YEAR=$(date +%Y)
  MONTH=$(date +%m)
fi
NOW=$(date '+%Y-%m-%d %H:%M:%S')

# テーマ番号をスクリプト側で計算（1〜30のローテーション）
# macOS: date -j -f で任意の日付の通算日数を取得
DAY_OF_YEAR=$(date -j -f "%Y-%m-%d" "$TODAY" +%j 2>/dev/null | sed 's/^0*//' || date +%-j)
THEME_MOD=$((DAY_OF_YEAR % 30))
THEME_NUM=$((THEME_MOD == 0 ? 30 : THEME_MOD))
THEME_NAMES=("" "タンパク質" "脂質（総論）" "炭水化物" "食物繊維" "カルシウム" "鉄分" "ビタミンC" "ビタミンD" "ビタミンB1" "オメガ3脂肪酸" "ビタミンA/βカロテン" "ビタミンB12・葉酸" "亜鉛" "マグネシウム" "カリウム" "ポリフェノール" "発酵食品・腸内環境" "水溶性ビタミン総論" "脂溶性ビタミン総論" "吸収効率（組み合わせの科学）" "調理と栄養損失" "食物繊維と腸内細菌" "抗酸化物質" "アミノ酸スコアと食品の組み合わせ" "血糖値と食事" "骨代謝と栄養" "筋肉合成と栄養タイミング" "疲労回復と栄養" "鉄欠乏性貧血の予防" "総合レビュー")
THEME_NAME="${THEME_NAMES[$THEME_NUM]}"

# スクリプト配置場所からリポジトリルートを特定する
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$REPO_DIR/$YEAR/$MONTH"
OUTPUT_FILE="$OUTPUT_DIR/$TODAY.md"
LOG_DIR="$REPO_DIR/logs"

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

# エラー発生時にログを記録する trap
trap 'echo "[ERROR $(date +%Y-%m-%d\ %H:%M:%S)] スクリプトがライン $LINENO で失敗 (exit $?)" >> "$LOG_DIR/error.log"' ERR

echo "[$NOW] 起動確認 USER=$USER HOME=$HOME THEME=${THEME_NUM}「${THEME_NAME}」"

if ! command -v claude >/dev/null 2>&1; then
  echo "claude コマンドが見つかりません。PATHを確認してください。"
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node コマンドが見つかりません。PATHを確認してください。"
  exit 1
fi

# Git認証設定（共通）
setup_git_auth() {
  cd "$REPO_DIR"
  GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
  if [ -n "$GITHUB_TOKEN" ]; then
    git remote set-url origin "https://oguogu-bit:${GITHUB_TOKEN}@github.com/oguogu-bit/nutrition-education-daily.git"
  fi
}

# Claude呼び出し用システムプロンプト（ツール使用を禁止し、テキスト直接出力させる）
CLAUDE_SYSTEM="You are a markdown content generator. Output the requested content directly as markdown text. Do NOT use any tools, do NOT write files, do NOT ask for permissions. Just output the markdown text directly to stdout."

# Claude呼び出し（リトライあり・タイムアウト付き）
# 引数: $1=出力ファイル, $2=プロンプト文字列
CLAUDE_TIMEOUT_SEC=300  # 5分でタイムアウト

run_claude_with_retry() {
  local out_file="$1"
  local prompt="$2"
  local max_attempts=3
  local attempt=1

  while [ $attempt -le $max_attempts ]; do
    echo "[$NOW] Claude呼び出し (試行 ${attempt}/${max_attempts})..." >> "$LOG_DIR/daily.log" 2>&1 || true
    local tmp_out="${out_file}.tmp"
    local tmp_err
    tmp_err=$(mktemp /tmp/claude-err-XXXXX.txt)
    local tmp_timeout_flag
    tmp_timeout_flag=$(mktemp /tmp/claude-timeout-XXXXX.txt)
    rm -f "$tmp_timeout_flag"

    # バックグラウンドでclaudeを起動し、タイムアウト監視を並行実行
    claude -p "$prompt" \
        --output-format text \
        --no-session-persistence \
        --system-prompt "$CLAUDE_SYSTEM" \
        --tools "" \
        > "$tmp_out" 2>"$tmp_err" &
    local claude_pid=$!

    # タイムアウト監視（バックグラウンド）
    (
      sleep "$CLAUDE_TIMEOUT_SEC"
      if kill -0 "$claude_pid" 2>/dev/null; then
        kill "$claude_pid" 2>/dev/null
        touch "$tmp_timeout_flag"
      fi
    ) &
    local timer_pid=$!

    wait "$claude_pid"
    local exit_code=$?
    kill "$timer_pid" 2>/dev/null
    wait "$timer_pid" 2>/dev/null

    if [ -f "$tmp_timeout_flag" ]; then
      echo "[ERROR $(date +%Y-%m-%d\ %H:%M:%S)] 試行${attempt}: claude タイムアウト (${CLAUDE_TIMEOUT_SEC}秒超過)" >> "$LOG_DIR/error.log"
      rm -f "$tmp_out" "$tmp_err" "$tmp_timeout_flag"
    elif [ "$exit_code" -eq 0 ]; then
      rm -f "$tmp_timeout_flag"
      # 出力が空でないか確認
      if [ -s "$tmp_out" ]; then
        mv "$tmp_out" "$out_file"
        rm -f "$tmp_err"
        return 0
      else
        echo "[ERROR $(date +%Y-%m-%d\ %H:%M:%S)] 試行${attempt}: claudeの出力が空でした" >> "$LOG_DIR/error.log"
        rm -f "$tmp_out" "$tmp_err"
      fi
    else
      echo "[ERROR $(date +%Y-%m-%d\ %H:%M:%S)] 試行${attempt}: claude失敗 (exit ${exit_code})" >> "$LOG_DIR/error.log"
      if [ -s "$tmp_err" ]; then
        echo "--- claude stderr ---" >> "$LOG_DIR/error.log"
        cat "$tmp_err" >> "$LOG_DIR/error.log"
        echo "--- end stderr ---" >> "$LOG_DIR/error.log"
      else
        echo "[DEBUG] stderr空 (exit ${exit_code})" >> "$LOG_DIR/error.log"
      fi
      rm -f "$tmp_out" "$tmp_err" "$tmp_timeout_flag"
    fi

    attempt=$((attempt + 1))

    if [ $attempt -le $max_attempts ]; then
      echo "[RETRY $(date +%Y-%m-%d\ %H:%M:%S)] $((attempt-1))回目失敗、60秒後にリトライします..." >> "$LOG_DIR/error.log"
      sleep 60
    fi
  done

  return 1
}

# ── バックフィル: 過去7日の欠損ファイルを自動補完 ──────────
# DATE_OVERRIDEなしの通常実行時のみ実行（再帰呼び出し防止）
if [ -z "${DATE_OVERRIDE:-}" ]; then
  for i in 7 6 5 4 3 2 1; do
    past_date=$(date -v-${i}d +%Y-%m-%d)
    past_year="${past_date:0:4}"
    past_month="${past_date:5:2}"
    past_file="$REPO_DIR/$past_year/$past_month/$past_date.md"
    if [ ! -f "$past_file" ]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [BACKFILL] $past_date の欠損を検出 — 自動生成開始" | tee -a "$LOG_DIR/daily.log"
      DATE_OVERRIDE="$past_date" bash "$SCRIPT_DIR/run-daily.sh" >> "$LOG_DIR/daily.log" 2>> "$LOG_DIR/error.log" \
        || echo "[$(date '+%Y-%m-%d %H:%M:%S')] [BACKFILL ERROR] $past_date の自動バックフィル失敗" >> "$LOG_DIR/error.log"
    fi
  done
fi

# ── 日次コンテンツ生成 ──────────────────────────────────

if [ -f "$OUTPUT_FILE" ]; then
  echo "[$TODAY] 日次コンテンツは既に存在します: $OUTPUT_FILE"
else
  echo "[$NOW] 日次コンテンツ生成を開始... (テーマ${THEME_NUM}「${THEME_NAME}」)"

  # レシピデータを最新の状態にエクスポート
  echo "[$NOW] レシピデータをエクスポート中..." >> "$LOG_DIR/daily.log" 2>&1 || true
  node "$SCRIPT_DIR/export-recipe-data.mjs" >> "$LOG_DIR/daily.log" 2>&1 || {
    echo "[ERROR $NOW] レシピデータのエクスポートに失敗しました" >> "$LOG_DIR/error.log"
    exit 1
  }

  # 本日のレシピを選択（DAY_OF_YEAR % レシピ数）
  RECIPE_JSON=$(node -e "
    const data = require('$REPO_DIR/data/recipes-snapshot.json');
    const idx = $DAY_OF_YEAR % data.length;
    console.log(JSON.stringify(data[idx], null, 2));
  " 2>/dev/null) || {
    echo "[ERROR $NOW] レシピの選択に失敗しました" >> "$LOG_DIR/error.log"
    exit 1
  }

  SKILL_CONTENT=$(cat "$HOME/.claude/commands/nutrition-education.md")
  SKILL_PROMPT="【本日の指定情報】
- 今日の日付：$TODAY
- 使用するテーマ番号：テーマ${THEME_NUM}「${THEME_NAME}」
- ※ 上記テーマを必ず使用してください。他のテーマは選ばないでください。
- 本日のレシピデータ（必ずこのデータを使用してください）：
\`\`\`json
$RECIPE_JSON
\`\`\`

$SKILL_CONTENT"

  if ! run_claude_with_retry "$OUTPUT_FILE" "$SKILL_PROMPT"; then
    echo "[ERROR $NOW] $TODAY の生成が3回全て失敗しました。明日再試行されます。" >> "$LOG_DIR/error.log"
    rm -f "$OUTPUT_FILE"
    exit 1
  fi

  echo "[$NOW] 日次コンテンツ生成完了 → $OUTPUT_FILE"

  setup_git_auth
  cd "$REPO_DIR"

  if ! git remote get-url origin >/dev/null 2>&1; then
    echo "origin リモートが未設定のため、pushをスキップします。"
  else
    git add "$OUTPUT_FILE"
    if git diff --cached --quiet; then
      echo "追加された差分がないため、commit/pushをスキップします。"
    else
      git commit -m "🥦 Daily nutrition: $TODAY テーマ${THEME_NUM}「${THEME_NAME}」"
      git pull --rebase origin main 2>>"$LOG_DIR/error.log" || true
      git push origin main
      echo "[$NOW] 日次コンテンツをGitHubにpushしました"
    fi
  fi
fi

echo "[$NOW] すべての処理が完了しました"
