#!/usr/bin/env bash
# Mailgun 設定・サプレッションのバックアップ
#   使い方: ./mailgun-backup.sh <Herokuアプリ名> [ドメイン]
#     ドメイン省略時はアカウント内の全ドメインを対象にする
#   環境変数: MG_API (既定 https://api.mailgun.net / EUなら https://api.eu.mailgun.net)
#   前提: heroku CLI, curl, jq
set -uo pipefail

APP="${1:?usage: $0 <heroku-app> [domain]}"
ONLY_DOMAIN="${2:-}"
API="${MG_API:-https://api.mailgun.net}"
OUT="mailgun-backup-${APP}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
WARN="$OUT/warnings.log"

KEY="$(heroku config:get MAILGUN_API_KEY -a "$APP" | tr -d '\r')"
[[ -z "$KEY" ]] && { echo "MAILGUN_API_KEY が取得できません" >&2; exit 1; }

# 1回だけ取得
get() {  # get <path or url> <outfile>
  local url="$1"; [[ "$url" == http* ]] || url="$API$1"
  if ! curl -sSf --user "api:$KEY" "$url" -o "$2" 2>> "$WARN"; then
    echo "WARN: failed $url" | tee -a "$WARN" >&2; return 1
  fi
}

# paging.next をたどって items を全件取得し、1つの配列に結合
get_all() {  # get_all <path> <outfile>
  local url="$API$1" tmp="$OUT/.page.json" acc="$OUT/.acc.jsonl" n
  : > "$acc"
  while :; do
    get "$url" "$tmp" || break
    n="$(jq '.items | length' "$tmp" | tr -d '\r')"
    [[ "$n" == "0" || -z "$n" ]] && break
    jq -c '.items[]' "$tmp" >> "$acc"
    url="$(jq -r '.paging.next // empty' "$tmp" | tr -d '\r')"
    [[ -z "$url" ]] && break
  done
  jq -s '.' "$acc" > "$2"
  rm -f "$tmp" "$acc"
}

echo "== account =="
get "/v3/domains?limit=1000" "$OUT/domains.json"
get "/v3/routes?limit=1000"  "$OUT/routes.json"

echo "== mailing lists =="
get_all "/v3/lists/pages?limit=100" "$OUT/lists.json"
mkdir -p "$OUT/lists"
for l in $(jq -r '.[].address' "$OUT/lists.json" 2>/dev/null | tr -d '\r'); do
  get_all "/v3/lists/$l/members/pages?limit=100" "$OUT/lists/$l-members.json"
done

if [[ -n "$ONLY_DOMAIN" ]]; then DOMAINS="$ONLY_DOMAIN"
else DOMAINS="$(jq -r '.items[].name' "$OUT/domains.json" 2>/dev/null | tr -d '\r')"; fi

for D in $DOMAINS; do
  echo "== domain: $D =="
  d="$OUT/domains/$D"; mkdir -p "$d/templates"
  get "/v3/domains/$D"          "$d/domain.json"      # SPF/DKIM等のDNSレコード含む
  get "/v3/domains/$D/tracking" "$d/tracking.json"
  get "/v3/domains/$D/webhooks" "$d/webhooks.json"
  for t in bounces unsubscribes complaints; do
    get_all "/v3/$D/$t?limit=1000" "$d/$t.json"
    echo "   $t: $(jq length "$d/$t.json" | tr -d '\r') 件"
  done
  get_all "/v3/$D/templates?limit=100" "$d/templates.json"
  for t in $(jq -r '.[].name' "$d/templates.json" 2>/dev/null | tr -d '\r'); do
    get "/v3/$D/templates/$t?active=yes" "$d/templates/$t.json"   # 本文(アクティブ版)
  done
done

tar czf "${OUT}.tar.gz" "$OUT"
echo
echo "完了: ${OUT}.tar.gz"
[[ -s "$WARN" ]] && echo "※ 警告あり: $WARN を確認してください"
