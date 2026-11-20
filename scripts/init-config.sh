#!/usr/bin/env bash
# Initialize configs either from a declarative topology (--topology)
# or by copying server/config.template.json to --out with 0600 permissions.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  1) Recommended (Topology-driven server + client generation):
     init-config.sh --topology PATH [--out-dir DIR] [--generate-secrets]

  2) Manual single-file server template copy (refuses overwrite, sets 0600):
     init-config.sh --out PATH
USAGE
}

OUT=""
TOPOLOGY=""
OUT_DIR=""
GEN_SECRETS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      [[ $# -ge 2 ]] || { echo "error: --out requires a path" >&2; exit 2; }
      OUT="$2"; shift 2 ;;
    --topology)
      [[ $# -ge 2 ]] || { echo "error: --topology requires a path" >&2; exit 2; }
      TOPOLOGY="$2"; shift 2 ;;
    --out-dir)
      [[ $# -ge 2 ]] || { echo "error: --out-dir requires a directory" >&2; exit 2; }
      OUT_DIR="$2"; shift 2 ;;
    --generate-secrets)
      GEN_SECRETS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -n "$TOPOLOGY" ]]; then
  cmd=(python3 "$SCRIPT_DIR/render-topology.py" --topology "$TOPOLOGY")
  if [[ -n "$OUT_DIR" ]]; then cmd+=(--out-dir "$OUT_DIR"); fi
  if [[ "$GEN_SECRETS" -eq 1 ]]; then cmd+=(--generate-secrets); fi
  exec "${cmd[@]}"
fi

if [[ -z "$OUT" ]]; then
  echo "error: --out or --topology is required" >&2
  usage >&2
  exit 2
fi

SRC="$REPO_ROOT/server/config.template.json"
if [[ ! -f "$SRC" ]]; then
  echo "error: template not found: $SRC" >&2
  exit 1
fi
if [[ -e "$OUT" ]]; then
  echo "error: refusing to overwrite existing file: $OUT" >&2
  exit 1
fi

umask 077
mkdir -p "$(dirname "$OUT")"
cp -- "$SRC" "$OUT"
chmod 600 "$OUT"
echo "wrote $OUT"
echo "Fill every <PLACEHOLDER> (ports must be JSON numbers), or prefer scripts/render-topology.py."
