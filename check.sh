#!/usr/bin/env bash
# Checa cada serviço de checks.json. Uma falha só conta se repetir 20 s depois (evita alarme por um pico).
# Para cada serviço: abre uma issue "fora do ar" (o GitHub avisa por e-mail) e fecha quando volta.
# Atualiza docs/status.json (estado atual) e docs/history.json (cada mudança de estado, para o uptime), que a página
# de status (docs/index.html) lê.
set -uo pipefail

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
results="[]"
# Histórico: por serviço, a lista de mudanças {at, ok}. O uptime sai daí (o estado vale até a mudança seguinte).
hist_before=$(cat docs/history.json 2>/dev/null || echo '{"since":null,"events":{}}')
hist=$(jq --arg at "$now" '.since //= $at | .events //= {}' <<<"$hist_before")

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
  okb=$([ "$ok" = 1 ] && echo true || echo false)
  results=$(jq --arg id "$id" --arg name "$name" --argjson ok "$okb" \
    --arg code "$code" --argjson ms "$ms" '. + [{id: $id, name: $name, ok: $ok, code: $code, ms: $ms}]' <<<"$results")
  hist=$(jq --arg id "$id" --arg at "$now" --argjson ok "$okb" \
    '.events[$id] //= [] | if (.events[$id] | length) == 0 or .events[$id][-1].ok != $ok then .events[$id] += [{at: $at, ok: $ok}] else . end' <<<"$hist")

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

# Guarda 100 dias de mudanças (mais a última anterior, que diz o estado no começo da janela).
cutoff=$(date -u -d "-100 days" +%Y-%m-%dT%H:%M:%SZ)
hist=$(jq --arg c "$cutoff" '.events |= with_entries(.value = ((.value | map(select(.at < $c)) | last) as $l | (if $l then [$l] else [] end) + (.value | map(select(.at >= $c)))))' <<<"$hist")
jq . <<<"$hist" > docs/history.json
hist_changed=$([ "$(jq -c . <<<"$hist_before" 2>/dev/null)" != "$(jq -c . <<<"$hist")" ] && echo 1 || echo 0)

# Commit só quando algum estado mudou ou uma vez por dia (o GitHub desliga agendamentos de repositórios parados há 60 dias).
last_day=$(git log -1 --format=%cs -- docs/status.json 2>/dev/null || echo "")
if [ "$prev" != "$curr" ] || [ "$hist_changed" = 1 ] || [ "$last_day" != "$(date -u +%Y-%m-%d)" ]; then
  git config user.name "tenanci-status"
  git config user.email "status@users.noreply.github.com"
  git add docs/status.json docs/history.json
  git commit -qm "status: $(jq -r '[.[] | "\(.name) \(if .ok then "ok" else "fora" end)"] | join(", ")' <<<"$results")" && git push -q
fi

# Falha do job quando algo está fora (fica vermelho na aba Actions também).
jq -e 'all(.[]; .ok)' <<<"$results" >/dev/null
