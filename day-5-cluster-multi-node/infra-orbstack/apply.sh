#!/usr/bin/env bash
# Aplica o provisionamento nas maquinas OrbStack JA existentes.
# Uso: ./apply.sh controlplane worker1 worker2
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NODES=("$@")
if [ "${#NODES[@]}" -eq 0 ]; then
  echo "Uso: $0 <node1> <node2> ..." >&2
  echo "Exemplo: $0 controlplane worker1 worker2" >&2
  exit 1
fi

for node in "${NODES[@]}"; do
  echo "==> Provisionando $node"
  # orb push copia para o home do usuario Linux (destino relativo a ~/)
  orb push -m "$node" "$SCRIPT_DIR/provision-node.sh" provision-node.sh
  orb -m "$node" bash -c "sudo bash ~/provision-node.sh"
done

echo "==> Todos os nos provisionados."
orb list