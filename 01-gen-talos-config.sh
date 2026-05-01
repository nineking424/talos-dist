#!/bin/bash
#
# Talos 클러스터 머신 컨피그 생성 스크립트
#
# - talosctl이 없으면 자동 설치
# - controlplane/worker/talosconfig 생성
# - controlplane.yaml을 Proxmox snippets 디렉토리로 복사
# - local 스토리지의 snippets content type 활성화 확인
#
# 사용법: bash 01-gen-talos-config.sh
#

set -e

# ==== 변수 ====
CLUSTER_NAME="talos-homelab"
CONTROL_PLANE_IP="192.168.2.106"           # 첫 번째 CP 노드 IP (cluster endpoint)
TALOS_VERSION="v1.13.0"
WORK_DIR="${HOME}/talos-cluster"
SNIPPETS_DIR="/var/lib/vz/snippets"
STORAGE="local"

# CP 노드별 snippet 파일명 (필요한 만큼 추가/수정)
CP_NODES=(
  "talos-cp-01"
  # "talos-cp-02"
  # "talos-cp-03"
)

# Worker 노드별 snippet 파일명
WORKER_NODES=(
  # "talos-w-01"
  # "talos-w-02"
)

# ==== 0. 사전 체크 & 준비 ====

# Snippets 디렉토리 생성
mkdir -p "$SNIPPETS_DIR"

# Snippets content type 활성화 확인
if ! grep -A 5 "^dir: ${STORAGE}$" /etc/pve/storage.cfg | grep -q snippets; then
  echo "Enabling 'snippets' content type on storage '${STORAGE}'..."
  pvesm set "$STORAGE" --content iso,vztmpl,backup,snippets
fi

# talosctl 설치 확인
if ! command -v talosctl &>/dev/null; then
  echo "Installing talosctl ${TALOS_VERSION}..."
  curl -Lo /usr/local/bin/talosctl \
    "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-amd64"
  chmod +x /usr/local/bin/talosctl
fi
echo "talosctl: $(talosctl version --client --short 2>/dev/null || talosctl version --client)"

# ==== 1. 클러스터 컨피그 생성 ====

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 기존 컨피그가 있으면 백업
if [ -d "_out" ]; then
  BACKUP_DIR="_out.backup.$(date +%Y%m%d_%H%M%S)"
  echo "Existing _out/ found, backing up to ${BACKUP_DIR}"
  mv _out "$BACKUP_DIR"
fi

echo "Generating cluster config: ${CLUSTER_NAME} → https://${CONTROL_PLANE_IP}:6443"
talosctl gen config "$CLUSTER_NAME" "https://${CONTROL_PLANE_IP}:6443" \
  --output-dir ./_out

ls -la _out/

# ==== 2. snippets 디렉토리로 복사 ====

echo ""
echo "Copying machine configs to ${SNIPPETS_DIR}..."

for node in "${CP_NODES[@]}"; do
  cp _out/controlplane.yaml "${SNIPPETS_DIR}/${node}-user.yaml"
  echo "  ✓ ${SNIPPETS_DIR}/${node}-user.yaml (controlplane)"
done

for node in "${WORKER_NODES[@]}"; do
  cp _out/worker.yaml "${SNIPPETS_DIR}/${node}-user.yaml"
  echo "  ✓ ${SNIPPETS_DIR}/${node}-user.yaml (worker)"
done

# ==== 3. 검증 ====

echo ""
echo "Verifying snippets..."
pvesm list "$STORAGE" --content snippets | grep -E "talos-(cp|w)-" || true

echo ""
echo "Endpoint configured in machine config:"
grep -A 0 "endpoint:" "${SNIPPETS_DIR}/${CP_NODES[0]}-user.yaml" | head -3

# ==== 4. 안내 ====

cat <<EOF

==========================================================
✓ Talos cluster config generated.

Files:
  Cluster configs:    ${WORK_DIR}/_out/
  Snippets:           ${SNIPPETS_DIR}/
  talosconfig:        ${WORK_DIR}/_out/talosconfig

Save talosconfig path:
  export TALOSCONFIG=${WORK_DIR}/_out/talosconfig

  # Optional: persist to shell profile
  echo 'export TALOSCONFIG=${WORK_DIR}/_out/talosconfig' >> ~/.bashrc

Next: run VM creation script
  bash 02-create-talos-vm.sh

==========================================================
EOF