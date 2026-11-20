#!/usr/bin/env bash
# Copy server/config.template.json to a local path for you to fill in.
# Refuses to overwrite an existing file.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: init-config.sh --out PATH

Copy the sanitized sing-box template to PATH (for example server/config.json).
The command refuses to overwrite PATH if it already exists.

This only copies the template. The result still contains <PLACEHOLDER> values,
is not a working config, and must not be deployed until you fill every
placeholder and pass `sing-box check`.
USAGE
}

OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      [[ $# -ge 2 ]] || { echo "error: --out requires a path" >&2; exit 2; }
      OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$OUT" ]]; then
  echo "error: --out is required" >&2
  usage >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)/server/config.template.json"
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
echo "Fill every <PLACEHOLDER> (ports must be JSON numbers), then run:"
echo "  ./scripts/deploy.sh --config $OUT"
echo "JSON that only parses is not enough; unfilled templates are not deployable."
