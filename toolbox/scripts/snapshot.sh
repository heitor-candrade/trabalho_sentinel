#!/bin/bash
# Retrato rapido do sistema (usado por scripts/status.sh).
# Cada bloco falha de forma isolada: se um componente nao responde, o resto aparece.
agora() { date -u +%Y-%m-%dT%H:%M:%SZ; }
echo "instante (UTC): $(agora)"

echo; echo "WATCHDOG  (estado | falhas consecutivas | idade da ultima sondagem | ultimo motivo)"
if st="$(curl -s -m 2 http://watchdog:9100/state)" && [ -n "$st" ]; then
  echo "$st" | jq -r '.alvos | to_entries[] | [.key, .value.state, (.value.falhas_consecutivas|tostring), ((.value.idade_ultima_sondagem_s // -1)|tostring), .value.ultimo_motivo, ((.value.ultima_duracao_s*1000)|floor|tostring)] | @tsv' \
   | awk -F'\t' '{ printf "  %-8s %-5s falhas=%-2s idade=%-6ss ultimo=%s (%sms)\n", $1,toupper($2),$3,$4,$5,$6 }'
else
  echo "  watchdog nao responde em :9100/state"
fi

echo; echo "NOS RUST  (visao interna de cada no)"
for n in rust-a rust-b; do
  r="$(curl -s -m 2 http://$n:8080/admin/status)" && [ -n "$r" ] && echo "  $r" || echo "  $n: sem resposta em :8080"
done

echo; echo "PROMETHEUS  (coleta e alertas)"
if t="$(curl -s -m 2 http://prometheus:9090/api/v1/targets)" && [ -n "$t" ]; then
  echo "$t" | jq -r '.data.activeTargets[] | select(.labels.job != "prometheus") | "  coleta \(.labels.job)/\(.labels.instance): \(.health)\(if .lastError != "" then " (" + .lastError + ")" else "" end)"'
  a="$(curl -s -m 2 http://prometheus:9090/api/v1/alerts)"
  n="$(echo "$a" | jq '[.data.alerts[] | select(.state=="firing" or .state=="pending")] | length')"
  if [ "${n:-0}" -eq 0 ]; then echo "  alertas: nenhum ativo"; else
    echo "$a" | jq -r '.data.alerts[] | select(.state=="firing" or .state=="pending") | "  ALERTA \(.state|ascii_upcase) \(.labels.alertname) \(.labels.target // "")  [\(.labels.severity // "-")]"'
  fi
else
  echo "  prometheus nao responde"
fi

echo; echo "NGINX  (stub_status)"
if ns="$(curl -s -m 2 http://nginx:8081/stub_status)" && [ -n "$ns" ]; then echo "$ns" | sed 's/^/  /'; else echo "  nginx sem resposta em :8081"; fi
