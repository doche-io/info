apt update
apt install -y make apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable"
add-apt-repository ppa:longsleep/golang-backports
apt update
apt install -y docker-ce docker-ce-cli containerd.io golang build-essential apt-utils
curl -fsSL -o hello-vmlinux.bin https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux.bin
git clone --recurse-submodules https://github.com/firecracker-microvm/firecracker-containerd
  cd firecracker-containerd
  make all
  make firecracker
  make install-firecracker
  make image
  mkdir -p /var/lib/firecracker-containerd/runtime
  cp tools/image-builder/rootfs.img /var/lib/firecracker-containerd/runtime/default-rootfs.img
cd ..
git clone https://github.com/torvalds/linux.git linux.git
cd linux.git
  git checkout v5.10
  make vmlinux
cd ..
cat << EOF > ./config.toml
version = 2
disabled_plugins = ["io.containerd.grpc.v1.cri"]
root = "/var/lib/firecracker-containerd/containerd"
state = "/run/firecracker-containerd"
[grpc]
  address = "/run/firecracker-containerd/containerd.sock"
[plugins]
  [plugins."io.containerd.snapshotter.v1.devmapper"]
    pool_name = "fc-dev-thinpool"
    base_image_size = "10GB"
    root_path = "/var/lib/firecracker-containerd/snapshotter/devmapper"

[debug]
  level = "debug"
EOF
cat << EOF > /etc/containerd/firecracker-runtime.json
{
  "firecracker_binary_path": "/usr/local/bin/firecracker",
  "kernel_image_path": "/var/lib/firecracker-containerd/runtime/microvm-vmlinux.bin",
  "kernel_args": "console=ttyS0 noapic reboot=k panic=1 pci=off nomodules ro systemd.journald.forward_to_console systemd.unit=firecracker.target init=/sbin/overlay-init",
  "root_drive": "/var/lib/firecracker-containerd/runtime/default-rootfs.img",
  "cpu_template": "T2",
  "log_fifo": "fc-logs.fifo",
  "log_levels": ["debug"],
  "metrics_fifo": "fc-metrics.fifo"
}
EOF
set -ex

DIR=/var/lib/firecracker-containerd/snapshotter/devmapper
POOL=fc-dev-thinpool

if [[ ! -f "${DIR}/data" ]]; then
touch "${DIR}/data"
truncate -s 100G "${DIR}/data"
fi

if [[ ! -f "${DIR}/metadata" ]]; then
touch "${DIR}/metadata"
truncate -s 2G "${DIR}/metadata"
fi

DATADEV="$(losetup --output NAME --noheadings --associated ${DIR}/data)"
if [[ -z "${DATADEV}" ]]; then
DATADEV="$(losetup --find --show ${DIR}/data)"
fi

METADEV="$(losetup --output NAME --noheadings --associated ${DIR}/metadata)"
if [[ -z "${METADEV}" ]]; then
METADEV="$(losetup --find --show ${DIR}/metadata)"
fi

SECTORSIZE=512
DATASIZE="$(blockdev --getsize64 -q ${DATADEV})"
LENGTH_SECTORS=$(bc <<< "${DATASIZE}/${SECTORSIZE}")
DATA_BLOCK_SIZE=128 # see https://www.kernel.org/doc/Documentation/device-mapper/thin-provisioning.txt
LOW_WATER_MARK=32768 # picked arbitrarily
THINP_TABLE="0 ${LENGTH_SECTORS} thin-pool ${METADEV} ${DATADEV} ${DATA_BLOCK_SIZE} ${LOW_WATER_MARK} 1 skip_block_zeroing"
echo "${THINP_TABLE}"

if ! $(dmsetup reload "${POOL}" --table "${THINP_TABLE}"); then
dmsetup create "${POOL}" --table "${THINP_TABLE}"
fi
