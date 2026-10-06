#!/usr/bin/env bash
# Heroku 構成バックアップスクリプト
#   使い方: ./heroku-backup.sh [TEAM名]
#   前提  : heroku CLI ログイン済み, jq, curl
#   環境変数: SKIP_PG=1 で Postgres のダンプ取得をスキップ
heroku() { heroku.cmd "$@"; }
set -uo pipefail

TEAM="${1:-}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="heroku-backup-${TEAM:-all}-${TS}"
mkdir -p "$OUT"/{team,spaces,apps,pipelines}
TEAM_OPT=(); [[ -n "$TEAM" ]] && TEAM_OPT=(--team "$TEAM")

# 失敗しても止めずに記録する
run() {
  local f="$1"; shift
  if "$@" > "$f" 2> "$f.err"; then rm -f "$f.err"
  else echo "WARN: failed -> $*" | tee -a "$OUT/warnings.log" >&2; fi
}

echo "== Team / 全体 =="
heroku version                                  > "$OUT/heroku-cli-version.txt"
run "$OUT/team/teams.json"     heroku teams --json
run "$OUT/team/spaces.json"    heroku spaces --json "${TEAM_OPT[@]}"
run "$OUT/team/apps.json"      heroku apps --json "${TEAM_OPT[@]}"
run "$OUT/team/pipelines.json" heroku pipelines --json
[[ -n "$TEAM" ]] && run "$OUT/team/members.json" heroku members --team "$TEAM" --json

echo "== Pipelines =="
for p in $(jq -r '.[].name' "$OUT/team/pipelines.json" 2>/dev/null | tr -d '\r'); do
  run "$OUT/pipelines/${p}.json" heroku pipelines:info "$p" --json
done

echo "== Private Spaces =="
for s in $(jq -r '.[].name' "$OUT/team/spaces.json" 2>/dev/null | tr -d '\r'); do
  d="$OUT/spaces/$s"; mkdir -p "$d"
  run "$d/info.json"            heroku spaces:info --space "$s" --json
  run "$d/topology.json"        heroku spaces:topology --space "$s" --json
  run "$d/trusted-ips.json"     heroku spaces:trusted-ips --space "$s" --json
  run "$d/peering-info.json"    heroku spaces:peering:info --space "$s" --json
  run "$d/peerings.json"        heroku spaces:peerings --space "$s" --json
  run "$d/vpn-connections.json" heroku spaces:vpn:connections --space "$s" --json
  run "$d/drains.txt"           heroku spaces:drains:get --space "$s"
done

echo "== Apps =="
for a in $(jq -r '.[].name' "$OUT/team/apps.json" | tr -d '\r'); do
  echo "-- $a"
  d="$OUT/apps/$a"; mkdir -p "$d"
  run "$d/info.json"        heroku apps:info -a "$a" --json
  run "$d/config.json"      heroku config -a "$a" --json      # ※機密情報を含む
  run "$d/buildpacks.txt"   heroku buildpacks -a "$a"
  run "$d/formation.json"   heroku ps -a "$a" --json
  run "$d/ps-type.txt"      heroku ps:type -a "$a"
  run "$d/autoscale.txt"    heroku ps:autoscale -a "$a"
  run "$d/domains.json"     heroku domains -a "$a" --json
  run "$d/certs.json"       heroku certs -a "$a" --json
  run "$d/addons.json"      heroku addons -a "$a" --json
  run "$d/features.json"    heroku features -a "$a" --json
  run "$d/labs.json"        heroku labs -a "$a" --json
  run "$d/access.json"      heroku access -a "$a" --json
  run "$d/drains.json"      heroku drains -a "$a" --json
  run "$d/webhooks.txt"     heroku webhooks -a "$a"
  run "$d/releases.json"    heroku releases -a "$a" -n 100 --json
  run "$d/stack.txt"        heroku stack -a "$a"

  # アドオンごとの詳細
  for ad in $(jq -r '.[].name' "$d/addons.json" 2>/dev/null | tr -d '\r'); do
    run "$d/addon-${ad}.txt" heroku addons:info "$ad" -a "$a"
  done

  # Postgres: バックアップ取得 → ダウンロード（アプリ/アドオン削除でHeroku側のバックアップも消える）
  if [[ "${SKIP_PG:-0}" != "1" ]]; then
    for db in $(jq -r '.[] | select(.addon_service.name=="heroku-postgresql") | .name' "$d/addons.json" 2>/dev/null | tr -d '\r'); do
      echo "   pg backup: $db"
      run "$d/pg-info-${db}.txt"        heroku pg:info "$db" -a "$a"
      run "$d/pg-credentials-${db}.txt" heroku pg:credentials "$db" -a "$a"
      if heroku pg:backups:capture "$db" -a "$a"; then
        url="$(heroku pg:backups:url -a "$a" | tr -d '\r')"
        curl -fsSL -o "$d/${db}.dump" "$url" || echo "WARN: download failed $a/$db" | tee -a "$OUT/warnings.log"
        command -v pg_restore >/dev/null && pg_restore --list "$d/${db}.dump" > "$d/${db}.dump.list" 2>&1
      else
        echo "WARN: capture failed $a/$db" | tee -a "$OUT/warnings.log"
      fi
    done
  fi
done

tar czf "${OUT}.tar.gz" "$OUT"
echo
echo "完了: ${OUT}.tar.gz"
echo "※ config vars と DB ダンプを含むため、暗号化して保管してください（例: age / gpg / KMS 暗号化 S3）"
[[ -f "$OUT/warnings.log" ]] && echo "※ 警告あり: $OUT/warnings.log を確認してください"
