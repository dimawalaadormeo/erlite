#!/bin/sh
set -eu

engine=${ERLITE_CONTAINER_ENGINE:-docker}
compose_file=$(dirname "$0")/compose.yml

mkdir -p "$(dirname "$0")/results"
"$engine" compose -f "$compose_file" up -d --build node-a node-b node-c
"$engine" compose -f "$compose_file" run --rm benchmark

echo "Raw report: $(dirname "$0")/results/read-benchmark.term"
echo "Stop the cluster with: $engine compose -f $compose_file down"
