# Talos OS를 Proxmox에 cloud-init으로 배포하기

이 문서는 Proxmox VE에서 cloud-init(`nocloud`) 방식으로 Talos Linux 클러스터를 구성하는 표준 절차를 정리한 가이드입니다. ISO 부팅 후 `talosctl apply-config`로 적용하는 일반 방식 대신, **VM이 부팅하자마자 머신 컨피그가 자동 적용**되는 워크플로우입니다.

## 적용 환경

이 가이드는 다음 환경을 전제로 작성되었습니다.

- **Proxmox VE** 8.x 이상, 단일 호스트 (`pve-main`)
- **스토리지**: `local` (디렉토리 기반, qcow2)
- **네트워크**: 홈 라우터가 `192.168.0.0/16` 단일 서브넷으로 운영
  - 게이트웨이: `192.168.1.1`
  - 노드 IP 할당 대역: `192.168.2.x`
  - 마스크는 `/16`
- **Talos 버전**: v1.13.0
- **OS 익스텐션**: `siderolabs/qemu-guest-agent` 포함

다른 환경에서 사용할 때는 스크립트의 `NODE_CIDR`, `GATEWAY`, `STORAGE`, `SCHEMATIC_ID` 변수를 환경에 맞게 조정하시면 됩니다.

## 설계 결정 요약

| 항목 | 선택 | 이유 |
|---|---|---|
| 부팅 방식 | cloud-init (nocloud) | VM 시작 즉시 머신 컨피그 자동 적용, 템플릿화/대량 배포 용이 |
| Talos 이미지 | `nocloud-amd64.raw` | nocloud platform용 디스크 이미지 (ISO 아님) |
| BIOS | OVMF (UEFI) + EFI Disk | 최신 부팅 표준 |
| Machine | q35 | PCIe 지원, 권장 머신 타입 |
| SCSI Controller | virtio-scsi-single | 디스크별 컨트롤러 분리로 I/O 성능 향상 |
| CPU | host | 호스트 CPU 기능 그대로 노출 |
| 디스크 | qcow2, ssd=1, discard=on | thin provisioning + TRIM 지원 |
| 메모리 | balloon=0 | Kubernetes 환경에서 ballooning 비활성 권장 |
| Image Factory 옵션 | `qemu-guest-agent` 익스텐션 | Proxmox Guest Agent 통합 |

## 사전 준비

### 1. Proxmox 호스트 설정

```bash
# Snippets content type 활성화 (한 번만)
pvesm set local --content iso,vztmpl,backup,snippets

# Snippets 디렉토리 생성
mkdir -p /var/lib/vz/snippets
```

### 2. talosctl 설치

```bash
TALOS_VERSION="v1.13.0"
curl -Lo /usr/local/bin/talosctl \
  "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-amd64"
chmod +x /usr/local/bin/talosctl
talosctl version --client
```

`01-gen-talos-config.sh`를 사용하면 이 단계가 자동으로 처리됩니다.

### 3. Image Factory에서 Schematic 생성

[factory.talos.dev](https://factory.talos.dev/)에서 다음 옵션으로 schematic을 만들고 ID를 받습니다.

- Hardware Type: **Cloud Server** → Platform: **nocloud**
- Architecture: **amd64**
- System Extensions: **siderolabs/qemu-guest-agent**

발급받은 schematic ID(예: `ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515`)는 `02-create-talos-vm.sh`의 `SCHEMATIC_ID` 변수에 넣습니다.

## 배포 워크플로우

전체 작업은 두 단계로 나뉩니다.

```
[01-gen-talos-config.sh] → snippets/에 역할별 base 템플릿 배치 (1회)
            ↓
[02-create-talos-vm.sh]  → 노드별 스닙셋 자동 생성 + VM 생성/부팅 (노드마다 반복)
            ↓
[talosctl bootstrap]     → 첫 CP에서 한 번만
            ↓
[kubectl get nodes]      → 클러스터 확인
```

### 1단계: 클러스터 컨피그 생성

`01-gen-talos-config.sh`에서 클러스터 이름과 cluster endpoint(첫 CP IP)를 정의합니다. 노드 목록을 미리 등록할 필요는 없습니다.

```bash
CLUSTER_NAME="talos-homelab"
CONTROL_PLANE_IP="192.168.2.106"   # 첫 번째 CP 노드 IP
```

실행:

```bash
bash 01-gen-talos-config.sh
```

이 단계가 끝나면 `~/talos-cluster/_out/`에 다음 파일들이 생성되고, **역할별 base 템플릿**만 snippets 디렉토리로 복사됩니다. 노드별 스닙셋은 2단계에서 자동으로 만들어집니다.

```
~/talos-cluster/_out/
├── controlplane.yaml   # → snippets/_talos-cp-base.yaml
├── worker.yaml         # → snippets/_talos-wk-base.yaml
└── talosconfig         # talosctl 클라이언트 인증 (반드시 안전하게 보관)
```

`talosconfig`는 클러스터 관리 전체 권한을 가진 인증 파일이라 분실/유출되면 클러스터 접근을 잃거나 탈취될 수 있습니다. Git에 커밋하지 말고 별도 보관소(1Password, Vault, 백업 디스크 등)에 두세요.

### 2단계: VM 생성

`02-create-talos-vm.sh`는 인자 기반으로 동작합니다.

```bash
Usage: 02-create-talos-vm.sh <VMID> <VM_NAME> <NODE_IP> [ROLE]
```

CP 3대 + Worker 2대를 만드는 예시:

```bash
# Control Plane
bash 02-create-talos-vm.sh 106 talos-cp-01 192.168.2.106 cp
bash 02-create-talos-vm.sh 107 talos-cp-02 192.168.2.107 cp
bash 02-create-talos-vm.sh 108 talos-cp-03 192.168.2.108 cp

# Worker
bash 02-create-talos-vm.sh 111 talos-wk-01 192.168.2.111 worker
bash 02-create-talos-vm.sh 112 talos-wk-02 192.168.2.112 worker
```

`ROLE`에 따라 리소스 사양이 다르게 적용됩니다.

| Role | Memory | Cores | Disk |
|---|---|---|---|
| cp | 4096 MiB | 2 | 32 GB |
| worker | 4096 MiB | 4 | 64 GB |

운영 환경에 맞게 스크립트의 역할별 분기 로직을 조정할 수 있습니다.

`02-create-talos-vm.sh`는 호출 시 다음과 같이 동작합니다.

- `<VM_NAME>-user.yaml` 스닙셋이 이미 있으면 그대로 사용 (수동으로 패치한 컨피그가 보존됩니다).
- 없으면 `ROLE`에 맞는 base 템플릿(`_talos-cp-base.yaml` 또는 `_talos-wk-base.yaml`)을 복사해 새로 생성.

따라서 새 노드를 추가할 때 01을 다시 돌릴 필요 없이 02만 호출하면 됩니다. 노드별로 컨피그를 다르게 가져가고 싶다면, 02 실행 후 생성된 `<VM_NAME>-user.yaml`을 직접 수정한 뒤 `talosctl apply-config`로 반영하세요.

### 3단계: etcd 부트스트랩

VM이 모두 부팅된 후 (약 1~2분), 첫 번째 CP 노드에서 **한 번만** etcd를 부트스트랩합니다.

```bash
# 관리 호스트 (Proxmox 호스트나 로컬 머신)
export TALOSCONFIG=~/talos-cluster/_out/talosconfig

talosctl config endpoint 192.168.2.106 192.168.2.107 192.168.2.108
talosctl config node 192.168.2.106

talosctl bootstrap
```

**중요**: `bootstrap`은 절대 두 번 이상 실행하지 마세요. etcd 데이터가 깨지고 클러스터를 복구하기 매우 어려워집니다.

### 4단계: kubeconfig 추출 및 검증

```bash
talosctl kubeconfig .
export KUBECONFIG=$(pwd)/kubeconfig

kubectl get nodes -o wide
kubectl get pods -A
```

모든 노드가 `Ready`이고 시스템 파드가 `Running`이면 클러스터가 정상 동작 중입니다. CNI 부트스트랩에 1~2분 더 걸릴 수 있습니다.

## 트러블슈팅

### `volume 'local:snippets/...' does not exist`

snippets 파일이 없거나 content type이 활성화되지 않은 경우. 다음을 확인:

```bash
# 1. content 활성화 확인
grep -A 5 "^dir: local$" /etc/pve/storage.cfg | grep snippets

# 2. 파일 존재 확인
ls -la /var/lib/vz/snippets/

# 3. Proxmox가 인식하는지 확인
pvesm list local --content snippets
```

### VM 부팅 직후 PXE Boot로 빠짐

이전 시도의 잔재로 ISO가 마운트되어 있거나, 디스크 import가 실패해 부팅 디스크가 없는 상태입니다.

```bash
# VM 설정 확인
qm config <VMID>
```

`scsi0`에 import된 디스크가 attach되어 있고 `boot: order=scsi0`인지 확인하세요. nocloud 이미지는 ISO가 아닌 `.raw`/`.qcow2` 디스크로 import되어야 합니다.

### 외부 통신 안 됨 (이미지 pull 실패 등)

게이트웨이 서브넷 불일치가 가장 흔한 원인입니다.

```bash
# 노드 IP 대역과 게이트웨이가 같은 L2에 있어야 함
# 라우터 DHCP 풀이 192.168.0.0/16이라면 노드도 /16 마스크 사용

qm config <VMID> | grep ipconfig0
# → ipconfig0: ip=192.168.2.106/16,gw=192.168.1.1  ← /24가 아닌 /16
```

라우터의 DHCP 풀과 LAN 인터페이스 마스크를 확인해 동일한 마스크로 맞추세요.

### 머신 컨피그 endpoint와 노드 IP 불일치

`talosctl gen config` 시점에 박힌 `cluster.controlPlane.endpoint`가 실제 노드 IP와 다르면 부트스트랩 후 클러스터 endpoint 접근이 꼬입니다.

```bash
# base 템플릿 endpoint 확인
grep -A 1 "endpoint:" /var/lib/vz/snippets/_talos-cp-base.yaml | head -3

# 일치하지 않으면 base 재생성 (01 재실행 — 인증서/시크릿이 새로 발급되니
# 기존 클러스터가 있다면 노드별 user.yaml은 백업 후 진행)
bash 01-gen-talos-config.sh

# 노드별 스닙셋이 이미 있다면 base와 동기화하려면 삭제 후 02 재실행
rm /var/lib/vz/snippets/talos-cp-01-user.yaml
bash 02-create-talos-vm.sh 106 talos-cp-01 192.168.2.106 cp
```

### `qm destroy` 실패

VM이 실행 중이거나 락이 걸려 있을 때. 스크립트는 `--skiplock 1`로 처리하지만 수동으로 강제 정리하려면:

```bash
qm stop <VMID> --skiplock 1
qm unlock <VMID>
qm destroy <VMID> --purge 1 --skiplock 1
```

### 디스크 import는 성공했는데 unused0가 안 보임

`qm config`의 출력 파싱 문제일 수 있습니다. 직접 확인:

```bash
qm config <VMID> | grep -i unused
```

EFI Disk가 `disk-0`을 차지하므로 import된 Talos 디스크는 보통 `vm-XXX-disk-1.qcow2`로 잡힙니다.

## 일상 운영

### 노드 재시작 / 종료

```bash
talosctl --nodes 192.168.2.106 reboot
talosctl --nodes 192.168.2.106 shutdown
```

### 머신 컨피그 변경

snippets 파일을 수정한 뒤 `apply-config`로 반영합니다. cloud-init은 최초 부팅 때만 동작하므로, 이후 변경은 talosctl로 직접 적용해야 합니다.

```bash
# snippets 수정
vim /var/lib/vz/snippets/talos-cp-01-user.yaml

# 노드에 적용
talosctl apply-config \
  --nodes 192.168.2.106 \
  --file /var/lib/vz/snippets/talos-cp-01-user.yaml
```

변경 항목에 따라 자동 재부팅이 일어날 수 있습니다.

### Talos 업그레이드

```bash
talosctl upgrade \
  --nodes 192.168.2.111 \
  --image ghcr.io/siderolabs/installer:v1.13.1
```

Control plane은 한 번에 한 대씩 순차 업그레이드해 etcd 쿼럼을 유지하세요.

### Kubernetes 업그레이드

```bash
talosctl upgrade-k8s --nodes 192.168.2.106 --to 1.31.0
```

### etcd 백업

```bash
mkdir -p ~/talos-backups
talosctl etcd snapshot ~/talos-backups/etcd-$(date +%Y%m%d-%H%M%S).db \
  --nodes 192.168.2.106
```

## 추가 작업 아이디어

이 환경 위에 얹기 좋은 것들입니다.

- **Cilium CNI**: kube-proxy 대체, eBPF 기반 네트워킹/관측성. 머신 컨피그에 `cluster.network.cni: { name: none }` 설정 후 Helm으로 설치.
- **Longhorn / Rook-Ceph**: 분산 블록 스토리지. 워커 노드에 별도 디스크를 추가해 사용.
- **kube-vip**: control plane HA. CP 노드들이 공유하는 VIP를 머신 컨피그로 선언.
- **Flux / ArgoCD**: GitOps. 머신 컨피그와 클러스터 manifest를 모두 Git으로 관리.
- **OpenTelemetry Collector + Elasticsearch**: 노드/k8s 메트릭과 로그 수집. 기존 관측성 스택과 연동.

## 파일 구조 요약

```
프로젝트 루트/
├── 01-gen-talos-config.sh      # 컨피그 생성 + snippets 배치
├── 02-create-talos-vm.sh       # VM 생성 (인자 기반, 노드마다 실행)
└── README.md                   # 이 문서

~/talos-cluster/                # 1단계 결과물
└── _out/
    ├── controlplane.yaml
    ├── worker.yaml
    └── talosconfig             # 안전하게 보관 필수

/var/lib/vz/snippets/           # cloud-init user-data
├── _talos-cp-base.yaml         # 01이 배치하는 controlplane base 템플릿
├── _talos-wk-base.yaml         # 01이 배치하는 worker base 템플릿
├── talos-cp-01-user.yaml       # 02가 base에서 생성 (노드별)
├── talos-cp-02-user.yaml
├── talos-cp-03-user.yaml
├── talos-wk-01-user.yaml
└── talos-wk-02-user.yaml

/var/lib/vz/template/iso/
└── nocloud-amd64.raw           # Talos 디스크 이미지
```

## 참고 자료

- [Talos Linux 공식 문서](https://www.talos.dev/latest/)
- [Image Factory](https://factory.talos.dev/)
- [talosctl CLI 레퍼런스](https://www.talos.dev/latest/reference/cli/)
- [Proxmox VE Cloud-Init 문서](https://pve.proxmox.com/wiki/Cloud-Init_Support)