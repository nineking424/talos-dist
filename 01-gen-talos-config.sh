#!/bin/bash
#
# Talos 클러스터 머신 컨피그 생성 스크립트
#
# - talosctl이 없으면 자동 설치
# - controlplane/worker/talosconfig 생성
# - 역할별 base 템플릿(_talos-cp-base.yaml, _talos-wk-base.yaml)을 snippets 디렉토리로 복사
# - local 스토리지의 snippets content type 활성화 확인
# - per-node 스닙셋은 02-create-talos-vm.sh가 ROLE에 맞춰 동적으로 생성한다
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

# 역할별 base 스닙셋 파일명. 02-create-talos-vm.sh가 ROLE에 맞춰 이 파일을
# <VM_NAME>-user.yaml로 복사해 사용한다. VM-named 스닙셋과 충돌하지 않도록
# '_' prefix로 네임스페이스를 분리한다.
CP_BASE_SNIPPET="_talos-cp-base.yaml"
WK_BASE_SNIPPET="_talos-wk-base.yaml"

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

# ==== 2. snippets 디렉토리로 base 템플릿 배치 ====

echo ""
echo "Placing base templates in ${SNIPPETS_DIR}..."

cp _out/controlplane.yaml "${SNIPPETS_DIR}/${CP_BASE_SNIPPET}"
echo "  ✓ ${SNIPPETS_DIR}/${CP_BASE_SNIPPET} (controlplane base)"

cp _out/worker.yaml "${SNIPPETS_DIR}/${WK_BASE_SNIPPET}"
echo "  ✓ ${SNIPPETS_DIR}/${WK_BASE_SNIPPET} (worker base)"

# ==== 3. 검증 ====

echo ""
echo "Verifying snippets..."
pvesm list "$STORAGE" --content snippets | grep -E "_talos-(cp|wk)-base" || true

echo ""
echo "Endpoint configured in machine config:"
grep -A 0 "endpoint:" "${SNIPPETS_DIR}/${CP_BASE_SNIPPET}" | head -3

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