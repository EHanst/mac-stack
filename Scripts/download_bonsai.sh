#!/usr/bin/env bash
# Build-time helper: download Ternary-Bonsai-2-27B to the Kokoro models directory.
# This script is NEVER bundled in the app — it is a developer/user setup tool only.
# Run once before launching Kokoro with the local model picker.

set -euo pipefail

DEST="${HOME}/Library/Application Support/VibeCockpit/Models/Bonsai-27B"
REPO="prism-ml/Ternary-Bonsai-2-27B-mlx-2bit"

echo "Destination: ${DEST}"
echo "Repository:  ${REPO}"
echo ""

mkdir -p "${DEST}"

if ! command -v python3 &>/dev/null; then
    echo "Error: python3 not found. Install Python 3 to run this download script." >&2
    exit 1
fi

VENV_DIR="$(mktemp -d)/hf_venv"
python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install -q huggingface_hub

"${VENV_DIR}/bin/python" - <<PYEOF
from huggingface_hub import snapshot_download
dest = "${DEST}"
repo = "${REPO}"
print(f"Downloading {repo} (~8.6 GB)...")
snapshot_download(repo_id=repo, local_dir=dest, ignore_patterns=["*.py"])
print(f"\nDone: {dest}")
PYEOF

rm -rf "${VENV_DIR}"
