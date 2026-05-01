#!/bin/bash
#
# Talos VM 생성 스크립트 (Proxmox)
#
# 사전 요구사항:
#   - 01-gen-talos-config.sh 가 먼저 한 번 실행되어 snippets/에 역할별
#     base 템플릿(_talos-cp-base.yaml, _talos-wk-base.yaml)이 있어야 함
#   - Proxmox 호스트에서 root로 실행
#
# 동작:
#   - <VM_NAME>-user.yaml 이 이미 있으면 그대로 사용 (수동 패치 보존)
#   - 없으면 ROLE에 맞는 base 템플릿을 복사해 새로 생성
#
# 사용법:
#   bash 02-create-talos-vm.sh <VMID> <VM_NAME> <NODE_IP> [ROLE]
#
# 인자:
#   VMID      Proxmox VM ID (정수, 예: 106)
#   VM_NAME   VM 이름 (snippets 파일명과 일치해야 함, 예: talos-cp-01)
#   NODE_IP   노드 IP (예: 192.168.2.106)
#   ROLE      cp | worker (기본값: cp, 메모리/코어 차등 적용)
#
# 예시:
#   bash 02-create-talos-vm.sh 106 talos-cp-01 192.168.2.106 cp
#   bash 02-create-talos-vm.sh 107 talos-cp-02 192.168.2.107 cp
#   bash 02-create-talos-vm.sh 111 talos-wk-01  192.168.2.111 worker
#

set -e

# ==== 인자 파싱 ====

usage() {
  cat <<EOF
Usage: $0 <VMID> <VM_NAME> <NODE_IP> [ROLE]

  VMID      Proxmox VM ID (예: 106)
  VM_NAME   VM 이름, snippets 파일명과 일치 (예: talos-cp-01)
  NODE_IP   노드 IP (예: 192.168.2.106)
  ROLE      cp | worker (기본값: cp)

Examples:
  $0 106 talos-cp-01 192.168.2.106 cp
  $0 111 talos-wk-01  192.168.2.111 worker

EOF
  exit 1
}

if [ $# -lt 3 ]; then
  usage
fi

VMID="$1"
VM_NAME="$2"
NODE_IP="$3"
ROLE="${4:-cp}"

# 인자 검증
if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
  echo "ERROR: VMID must be a number, got: $VMID"
  exit 1
fi

if ! [[ "$NODE_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: NODE_IP must be a valid IPv4, got: $NODE_IP"
  exit 1
fi

if [[ "$ROLE" != "cp" && "$ROLE" != "worker" ]]; then
  echo "ERROR: ROLE must be 'cp' or 'worker', got: $ROLE"
  exit 1
fi

# ==== 환경 변수 (필요시 수정) ====

STORAGE=local
TALOS_VERSION="v1.13.0"
SCHEMATIC_ID="ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"

# 네트워크 (홈 라우터가 192.168.0.0/16 단일 서브넷으로 운영)
NODE_CIDR="16"
GATEWAY="192.168.1.1"
DNS_SERVERS="1.214.68.2 1.1.1.1"
SEARCH_DOMAIN="local"

# 역할별 리소스
if [ "$ROLE" = "cp" ]; then
  MEMORY=4096
  CORES=2
  DISK_SIZE=32G
else
  MEMORY=4096
  CORES=4
  DISK_SIZE=64G
fi

# 경로
SNIPPETS_DIR="/var/lib/vz/snippets"
SNIPPET_PATH="${SNIPPETS_DIR}/${VM_NAME}-user.yaml"
CP_BASE_SNIPPET="${SNIPPETS_DIR}/_talos-cp-base.yaml"
WK_BASE_SNIPPET="${SNIPPETS_DIR}/_talos-wk-base.yaml"
RAW_FILE="/var/lib/vz/template/iso/nocloud-amd64.raw"
IMAGE_URL="https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/nocloud-amd64.raw.xz"

# ==== 0. 사전 체크 ====

echo "==========================================================="
echo "Creating Talos VM"
echo "  VMID:    ${VMID}"
echo "  Name:    ${VM_NAME}"
echo "  Role:    ${ROLE}"
echo "  IP:      ${NODE_IP}/${NODE_CIDR}"
echo "  Gateway: ${GATEWAY}"
echo "  Memory:  ${MEMORY} MiB"
echo "  Cores:   ${CORES}"
echo "  Disk:    ${DISK_SIZE}"
echo "==========================================================="
echo ""

# 머신 컨피그 스닙셋 준비:
#   - 이미 있으면 그대로 사용 (수동 패치 보존)
#   - 없으면 ROLE에 맞는 base 템플릿을 복사해 생성
if [ -f "$SNIPPET_PATH" ]; then
  echo "✓ Reusing existing snippet: $SNIPPET_PATH"
else
  if [ "$ROLE" = "cp" ]; then
    BASE_SNIPPET="$CP_BASE_SNIPPET"
  else
    BASE_SNIPPET="$WK_BASE_SNIPPET"
  fi

  if [ ! -f "$BASE_SNIPPET" ]; then
    echo "ERROR: base template not found at $BASE_SNIPPET"
    echo "Run 01-gen-talos-config.sh once on this host to generate the base templates."
    exit 1
  fi

  cp "$BASE_SNIPPET" "$SNIPPET_PATH"
  echo "✓ Created snippet from base: $SNIPPET_PATH (← $(basename "$BASE_SNIPPET"))"
fi

# Snippets content 활성화
if ! grep -A 5 "^dir: ${STORAGE}$" /etc/pve/storage.cfg | grep -q snippets; then
  echo "ERROR: 'snippets' content type not enabled on storage '${STORAGE}'"
  echo "Fix with: pvesm set ${STORAGE} --content iso,vztmpl,backup,snippets"
  exit 1
fi

# CP 역할인 경우 머신 컨피그 endpoint와 NODE_IP 일치 권장
# (worker는 endpoint가 CP IP라 NODE_IP와 다른 게 정상)
if [ "$ROLE" = "cp" ] && ! grep -q "${NODE_IP}" "$SNIPPET_PATH"; then
  echo "WARNING: NODE_IP '${NODE_IP}' not found in $SNIPPET_PATH"
  echo "         The cluster endpoint may differ from this CP node's IP."
  echo "         (For non-first CPs or HA setups with VIP, this is expected.)"
  echo "         Continue anyway? (y/N)"
  read -r ans
  [ "$ans" != "y" ] && exit 1
fi

echo "✓ Pre-flight checks passed."

# ==== 기존 VM 정리 ====

if qm status "$VMID" &>/dev/null; then
  echo "Removing existing VM ${VMID}..."
  qm stop "$VMID" --skiplock 1 2>/dev/null || true
  sleep 2
  qm destroy "$VMID" --purge 1 --skiplock 1
fi

# ==== 1. Talos 이미지 준비 ====

cd /var/lib/vz/template/iso/

if [ ! -f "$RAW_FILE" ]; then
  echo "Downloading Talos nocloud image..."
  wget -c "$IMAGE_URL"
  
  if ! xz -t nocloud-amd64.raw.xz; then
    echo "ERROR: corrupted xz file, removing for retry"
    rm -f nocloud-amd64.raw.xz
    exit 1
  fi
  
  echo "Decompressing..."
  xz -d nocloud-amd64.raw.xz
fi

echo "✓ Image ready: $RAW_FILE"

# ==== 2. VM 생성 ====

echo "Creating VM ${VMID} (${VM_NAME})..."
qm create "$VMID" \
  --name "$VM_NAME" \
  --onboot 1 \
  --ostype l26 \
  --bios ovmf \
  --machine q35 \
  --scsihw virtio-scsi-single \
  --sockets 1 \
  --cores "$CORES" \
  --cpu host \
  --memory "$MEMORY" \
  --balloon 0 \
  --net0 virtio,bridge=vmbr0,firewall=0 \
  --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1,format=qcow2" \
  --agent enabled=1 \
  --serial0 socket

# ==== 3. 디스크 import & attach ====

echo "Importing Talos disk image..."
qm importdisk "$VMID" "$RAW_FILE" "$STORAGE" --format qcow2

DISK=$(qm config "$VMID" | grep -oP '^unused0:\s*\K\S+')
if [ -z "$DISK" ]; then
  echo "ERROR: imported disk not found in VM config"
  exit 1
fi
echo "✓ Imported disk: $DISK"

qm set "$VMID" --scsi0 "${DISK},ssd=1,discard=on"
qm resize "$VMID" scsi0 "$DISK_SIZE"

# ==== 4. cloud-init 설정 ====

echo "Configuring cloud-init..."
qm set "$VMID" \
  --ide2 "${STORAGE}:cloudinit" \
  --cicustom "user=${STORAGE}:snippets/${VM_NAME}-user.yaml" \
  --ipconfig0 "ip=${NODE_IP}/${NODE_CIDR},gw=${GATEWAY}" \
  --nameserver "$DNS_SERVERS" \
  --searchdomain "$SEARCH_DOMAIN"

# ==== 5. 부팅 ====

qm set "$VMID" --boot order=scsi0
qm start "$VMID"

# ==== 6. 안내 ====

cat <<EOF

==========================================================
✓ VM ${VMID} (${VM_NAME}) created and started.

Network:
  IP:       ${NODE_IP}/${NODE_CIDR}
  Gateway:  ${GATEWAY}
  DNS:      ${DNS_SERVERS}

Next steps:
  1. Wait ~1-2 min for Talos to apply config and reboot
  2. Verify connectivity:
       ping ${NODE_IP}

EOF

if [ "$ROLE" = "cp" ]; then
  cat <<EOF
  3. Set talosconfig (only needed once on the management host):
       export TALOSCONFIG=~/talos-cluster/_out/talosconfig
       talosctl config endpoint ${NODE_IP}
       talosctl config node ${NODE_IP}

  4. Bootstrap etcd (run ONLY on the FIRST control plane node):
       talosctl bootstrap

  5. Health check & kubeconfig:
       talosctl health
       talosctl kubeconfig .
       export KUBECONFIG=\$(pwd)/kubeconfig
       kubectl get nodes

EOF
else
  cat <<EOF
  3. The worker will auto-join the cluster once the control plane is bootstrapped.
     Verify with:
       kubectl get nodes

EOF
fi

echo "==========================================================="