#!/bin/bash
# Consulta instantanea no Prometheus.  Uso: promq.sh '<PromQL>'
q="${1:?uso: promq.sh '<PromQL>'}"
resp="$(curl -s -m 5 -G http://prometheus:9090/api/v1/query --data-urlencode "query=$q")" || { echo "prometheus inacessivel"; exit 1; }
echo "$resp" | jq -r 'if .status != "success" then "ERRO: \(.error // .)" 
  elif (.data.result | length) == 0 then "(sem dados)"
  else .data.result[] | "\(.metric | to_entries | map("\(.key)=\(.value)") | join(" ")) => \(.value[1])" end'
