#!/usr/bin/env bash
# Checa cada serviço de checks.json. Uma falha só conta se repetir 20 s depois (evita alarme por um pico).
# Para cada serviço: abre uma issue "fora do ar" (o GitHub avisa por e-mail) e fecha quando volta.
# Atualiza docs/status.json, que a página de status (docs/index.html) lê.
set -uo pipefail

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
results="[]"

probe() { # url expect contains → "ok|código|tempo"
  local url=$1 expect=$2 contains=$3 body code t
  body=$(mktemp)
  read -r code t < <(curl -s -o "$body" -w "%{http_code} %{time_total}" --max-time 20 -A "tenanci-status" "$url" || echo "000 20")
  local ok=0
  if [ "$code" = "$expect" ]; then
    if [ -z "$contains" ] || grep -q "$contains" "$body"; then ok=1; fi
  fi
  rm -f "$body"
  echo "$ok $code $t"
}

while IFS= read -r row <&3; do
  id=$(jq -r .id <<<"$row"); name=$(jq -r .name <<<"$row"); url=$(jq -r .url <<<"$row")
  expect=$(jq -r .expect <<<"$row"); contains=$(jq -r '.contains // ""' <<<"$row")
  read -r ok code t < <(probe "$url" "$expect" "$contains")
  if [ "$ok" != 1 ]; then
    sleep 20
    read -r ok code t < <(probe "$url" "$expect" "$contains")
  fi
  ms=$(awk -v t="$t" 'BEGIN { printf "%d", t * 1000 }')
  echo "$name: $([ "$ok" = 1 ] && echo ok || echo FALHOU) (HTTP $code, ${ms} ms)"
  results=$(jq --arg id "$id" --arg name "$name" --argjson ok "$([ "$ok" = 1 ] && echo true || echo false)" \
    --arg code "$code" --argjson ms "$ms" '. + [{id: $id, name: $name, ok: $ok, code: $code, ms: $ms}]' <<<"$results")

  # issue por serviço: título fixo, marcador no corpo
  marker="<!-- check:$id -->"
  open=$(gh issue list --state open --search "\"check:$id\" in:body" --json number --jq '.[0].number // empty')
  if [ "$ok" != 1 ] && [ -z "$open" ]; then
    gh issue create --title "🔴 $name fora do ar" \
      --body "$marker
**$name** não respondeu como esperado às $now (HTTP $code, esperado $expect).

Endereço checado: $url

Esta issue fecha sozinha quando o serviço voltar." >/dev/null && echo "  → issue aberta"
  elif [ "$ok" = 1 ] && [ -n "$open" ]; then
    gh issue close "$open" --comment "🟢 Voltou às $now (HTTP $code, ${ms} ms)." >/dev/null && echo "  → issue #$open fechada"
  fi
done 3< <(jq -c '.[]' checks.json)

prev=$(jq -c '[.checks[]? | {id, ok}]' docs/status.json 2>/dev/null || echo '[]')
curr=$(jq -c '[.[] | {id, ok}]' <<<"$results")
jq -n --arg at "$now" --argjson checks "$results" '{updated: $at, checks: $checks}' > docs/status.json

# Commit só quando algum estado mudou ou uma vez por dia (o GitHub desliga agendamentos de repositórios parados há 60 dias).
last_day=$(git log -1 --format=%cs -- docs/status.json 2>/dev/null || echo "")
if [ "$prev" != "$curr" ] || [ "$last_day" != "$(date -u +%Y-%m-%d)" ]; then
  git config user.name "tenanci-status"
  git config user.email "status@users.noreply.github.com"
  git add docs/status.json
  git commit -qm "status: $(jq -r '[.[] | "\(.name) \(if .ok then "ok" else "fora" end)"] | join(", ")' <<<"$results")" && git push -q
fi

# Falha do job quando algo está fora (fica vermelho na aba Actions também).
jq -e 'all(.[]; .ok)' <<<"$results" >/dev/null
