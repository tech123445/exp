#!/usr/bin/env bash
# Apache Hadoop 3.2.3 single-node (pseudo-distributed) installer
# Supported: Ubuntu 22.04 LTS and Ubuntu 24.04 LTS, x86_64/aarch64
# Run as the normal desktop user: bash install_hadoop_3.2.3_ubuntu.sh
# Do NOT run with sudo. The script requests sudo only when required.

set -Eeuo pipefail

HADOOP_VERSION="3.2.3"
HADOOP_URL="https://repo.huaweicloud.com/apache/hadoop/common/hadoop-3.2.3/hadoop-3.2.3.tar.gz"
TEMURIN_API_BASE="https://api.adoptium.net/v3/binary/latest/8/ga/linux"
INSTALL_DIR="/opt/hadoop-${HADOOP_VERSION}"
HADOOP_LINK="/opt/hadoop"
JAVA_DIR="/opt/temurin8"
DATA_DIR="${HOME}/hadoop-data-${HADOOP_VERSION}"

log()  { printf '\n[HADOOP-INSTALL] %s\n' "$*"; }
warn() { printf '\n[WARNING] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

on_error() {
    local rc=$?
    printf '\n[ERROR] Installation stopped at line %s (exit code %s).\n' "${BASH_LINENO[0]:-unknown}" "$rc" >&2
    if [[ -n "${HADOOP_HOME:-}" && -d "${HADOOP_HOME}/logs" ]]; then
        printf '\nRecent Hadoop logs, when available:\n' >&2
        find "${HADOOP_HOME}/logs" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null \
          | sort -nr | head -n 3 | cut -d' ' -f2- \
          | while IFS= read -r f; do echo "--- $f" >&2; tail -n 35 "$f" >&2 || true; done
    fi
    exit "$rc"
}
trap on_error ERR

# If launched through sudo, restart as the invoking desktop user. Hadoop daemons
# should not be run as root.
if [[ "${EUID}" -eq 0 ]]; then
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        REAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
        [[ -n "$REAL_HOME" && -d "$REAL_HOME" ]] || die "Could not determine the home directory for ${SUDO_USER}."
        exec sudo -u "$SUDO_USER" -H bash "$0" "$@"
    fi
    die "Run this script as your normal Ubuntu user, not as root: bash $0"
fi

[[ -r /etc/os-release ]] || die "Cannot identify the operating system."
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This installer supports Ubuntu 22.04 and 24.04 only. Detected: ${PRETTY_NAME:-unknown}."
case "${VERSION_ID:-}" in
    22.04|24.04) ;;
    *) die "Supported Ubuntu versions are 22.04 and 24.04. Detected: ${VERSION_ID:-unknown}." ;;
esac

[[ "${HOME}" != *" "* ]] || die "Your home path contains a space. Hadoop file URLs may fail; use a home path without spaces."
command -v sudo >/dev/null 2>&1 || die "sudo is required. Install it or use an administrator-enabled Ubuntu account."
sudo -v || die "Could not obtain sudo permission."

case "$(uname -m)" in
    x86_64) JAVA_ARCH="x64" ;;
    aarch64|arm64) JAVA_ARCH="aarch64" ;;
    *) die "Unsupported CPU architecture: $(uname -m). Use x86_64 or aarch64 Ubuntu." ;;
esac

# Check free space before changing anything. Hadoop + JDK + extracted files need room.
for target in /opt "$HOME"; do
    available_kb="$(df -Pk "$target" | awk 'NR==2 {print $4}')"
    [[ "${available_kb:-0}" =~ ^[0-9]+$ ]] || die "Could not check free disk space on $target."
    (( available_kb >= 1500000 )) || die "Less than 1.5 GB free on the filesystem containing $target. Free disk space and run again."
done

BACKUP_STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${HOME}/hadoop-install-backup-${BACKUP_STAMP}"
TMP_DIR="$(mktemp -d -t hadoop323-install.XXXXXX)"
tmp_available_kb="$(df -Pk "$TMP_DIR" | awk 'NR==2 {print $4}')"
[[ "${tmp_available_kb:-0}" =~ ^[0-9]+$ ]] || die "Could not check free space in the temporary download location."
(( tmp_available_kb >= 1000000 )) || die "Less than 1 GB free in the temporary download location ($TMP_DIR). Free disk space and run again."
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mkdir -p "$BACKUP_DIR"

backup_item() {
    local source_path="$1"
    [[ -e "$source_path" || -L "$source_path" ]] || return 0
    # Never move this installer's own backup directory.
    [[ "$source_path" == "$BACKUP_DIR" ]] && return 0
    local relative_path="${source_path#/}"
    local destination_path="${BACKUP_DIR}/${relative_path}"
    sudo mkdir -p "$(dirname "$destination_path")"
    sudo mv -- "$source_path" "$destination_path"
    sudo chown -R "$(id -un):$(id -gn)" "$BACKUP_DIR"
    log "Moved previous/conflicting item: $source_path -> $destination_path"
}

stop_old_hadoop_daemons() {
    log "Checking for running Hadoop daemons from previous attempts..."
    if [[ -n "${HADOOP_HOME:-}" ]]; then
        for stop_script in "${HADOOP_HOME}/sbin/stop-yarn.sh" "${HADOOP_HOME}/sbin/stop-dfs.sh"; do
            [[ -x "$stop_script" ]] && "$stop_script" >/dev/null 2>&1 || true
        done
    fi
    local jps_bin=""
    if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/jps" ]]; then
        jps_bin="${JAVA_HOME}/bin/jps"
    elif command -v jps >/dev/null 2>&1; then
        jps_bin="$(command -v jps)"
    fi
    if [[ -n "$jps_bin" ]]; then
        while read -r pid class_name; do
            [[ "${pid:-}" =~ ^[0-9]+ ]] || continue
            case "${class_name:-}" in
                org.apache.hadoop.hdfs.server.namenode.NameNode|\
                org.apache.hadoop.hdfs.server.datanode.DataNode|\
                org.apache.hadoop.hdfs.server.namenode.SecondaryNameNode|\
                org.apache.hadoop.yarn.server.resourcemanager.ResourceManager|\
                org.apache.hadoop.yarn.server.nodemanager.NodeManager|\
                org.apache.hadoop.mapreduce.v2.hs.JobHistoryServer)
                    kill -TERM "$pid" 2>/dev/null || true
                    ;;
            esac
        done < <("$jps_bin" -l 2>/dev/null || true)
        sleep 2
    fi
}

log "Repairing any interrupted Ubuntu package configuration and installing prerequisites..."
sudo dpkg --configure -a
sudo apt-get -o DPkg::Lock::Timeout=180 -f install -y
sudo apt-get -o DPkg::Lock::Timeout=180 update
sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y \
    ca-certificates curl wget tar gzip openssh-client openssh-server rsync procps iproute2 libsnappy1v5

# Fetch and validate both archives BEFORE moving any existing Hadoop installation.
# If the network or mirror is unavailable, the existing installation remains in place.
log "Downloading Eclipse Temurin Java 8 (required by Hadoop 3.2.x)..."
JAVA_URL="${TEMURIN_API_BASE}/${JAVA_ARCH}/jdk/hotspot/normal/eclipse"
curl --fail --location --retry 4 --retry-delay 3 --connect-timeout 30 \
    "$JAVA_URL" -o "$TMP_DIR/temurin8.tar.gz"
tar -tzf "$TMP_DIR/temurin8.tar.gz" >/dev/null

log "Downloading Apache Hadoop ${HADOOP_VERSION} from the Huawei mirror you supplied..."
curl --fail --location --retry 4 --retry-delay 3 --connect-timeout 30 \
    "$HADOOP_URL" -o "$TMP_DIR/hadoop-${HADOOP_VERSION}.tar.gz"
tar -tzf "$TMP_DIR/hadoop-${HADOOP_VERSION}.tar.gz" >/dev/null

stop_old_hadoop_daemons

# Detect port conflicts before moving old files or formatting a new HDFS namespace.
for port in 9000 9870 9864 9866 9867 9868 8088 8040 8041 8042 8030 8031 8032 8033; do
    if ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .; then
        warn "TCP port ${port} is already in use. The installer will not kill an unrelated process."
        sudo ss -ltnp "sport = :${port}" || true
        die "Resolve the port ${port} conflict (or stop the old Hadoop daemon) and run the script again."
    fi
done

# Back up common previous Hadoop locations/configuration. Nothing is permanently deleted.
log "Backing up known previous Hadoop installations, data folders, and configuration..."
if [[ -n "${HADOOP_HOME:-}" ]]; then backup_item "$HADOOP_HOME"; fi
for candidate in \
    "$HADOOP_LINK" "$INSTALL_DIR" "$JAVA_DIR" \
    /usr/local/hadoop /usr/local/hadoop-3.2.3 /etc/hadoop /etc/profile.d/hadoop.sh \
    /usr/local/bin/hadoop /usr/local/bin/hdfs /usr/local/bin/yarn /usr/local/bin/mapred \
    "$HOME/hadoop" "$HOME/hadoop_data" "$HOME/hadoop-data" "$HOME/hadoop_tmp" "$HOME/hadoop-tmp" \
    "$HOME/hdfs" "$HOME/.hadoop" "$HOME/hadoop-3.2.3-data" "$DATA_DIR"; do
    backup_item "$candidate"
done
shopt -s nullglob
for candidate in /opt/hadoop-3.* /usr/local/hadoop-3.* "$HOME"/hadoop-3.*; do
    backup_item "$candidate"
done
shopt -u nullglob

# Preserve the original shell configuration before replacing stale Hadoop exports.
if [[ -f "$HOME/.bashrc" ]]; then
    cp -p "$HOME/.bashrc" "$BACKUP_DIR/bashrc.before-install"
    awk '
        /# >>> HADOOP 3.2.3 MANAGED >>>/ {skip=1; next}
        /# <<< HADOOP 3.2.3 MANAGED <<</ {skip=0; next}
        !skip && $0 !~ /^[[:space:]]*export[[:space:]]+HADOOP_HOME=/ \
               && $0 !~ /^[[:space:]]*export[[:space:]]+HADOOP_CONF_DIR=/ \
               && $0 !~ /^[[:space:]]*export[[:space:]]+HADOOP_(COMMON|HDFS|MAPRED|YARN)_HOME=/ {print}
    ' "$HOME/.bashrc" > "$TMP_DIR/bashrc.cleaned"
    cat "$TMP_DIR/bashrc.cleaned" > "$HOME/.bashrc"
fi

log "Extracting the validated Eclipse Temurin Java 8 archive..."
mkdir "$TMP_DIR/java-extract"
tar -xzf "$TMP_DIR/temurin8.tar.gz" -C "$TMP_DIR/java-extract"
JAVA_EXTRACTED="$(find "$TMP_DIR/java-extract" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$JAVA_EXTRACTED" && -x "$JAVA_EXTRACTED/bin/java" && -x "$JAVA_EXTRACTED/bin/jps" ]] \
    || die "The Java 8 archive did not contain a usable JDK."
sudo mv "$JAVA_EXTRACTED" "$JAVA_DIR"
sudo chown -R "$(id -un):$(id -gn)" "$JAVA_DIR"
export JAVA_HOME="$JAVA_DIR"
export PATH="$JAVA_HOME/bin:$PATH"
java -version

log "Extracting the validated Apache Hadoop ${HADOOP_VERSION} archive..."
mkdir "$TMP_DIR/hadoop-extract"
tar -xzf "$TMP_DIR/hadoop-${HADOOP_VERSION}.tar.gz" -C "$TMP_DIR/hadoop-extract"
[[ -d "$TMP_DIR/hadoop-extract/hadoop-${HADOOP_VERSION}" ]] || die "The downloaded archive did not contain hadoop-${HADOOP_VERSION}."
sudo mv "$TMP_DIR/hadoop-extract/hadoop-${HADOOP_VERSION}" "$INSTALL_DIR"
sudo chown -R "$(id -un):$(id -gn)" "$INSTALL_DIR"
sudo ln -sfn "$INSTALL_DIR" "$HADOOP_LINK"

export HADOOP_HOME="$INSTALL_DIR"
export HADOOP_CONF_DIR="$HADOOP_HOME/etc/hadoop"
export HADOOP_COMMON_HOME="$HADOOP_HOME"
export HADOOP_HDFS_HOME="$HADOOP_HOME"
export HADOOP_MAPRED_HOME="$HADOOP_HOME"
export HADOOP_YARN_HOME="$HADOOP_HOME"
export HADOOP_COMMON_LIB_NATIVE_DIR="$HADOOP_HOME/lib/native"
export PATH="$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$JAVA_HOME/bin:$PATH"

log "Writing a clean single-node HDFS + YARN configuration..."
mkdir -p "$DATA_DIR"/{tmp,hdfs/namenode,hdfs/datanode}
mkdir -p "$HADOOP_CONF_DIR"

cat > "$HADOOP_CONF_DIR/core-site.xml" <<XML
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property>
    <name>fs.defaultFS</name>
    <value>hdfs://localhost:9000</value>
  </property>
  <property>
    <name>hadoop.tmp.dir</name>
    <value>file://${DATA_DIR}/tmp</value>
  </property>
</configuration>
XML

cat > "$HADOOP_CONF_DIR/hdfs-site.xml" <<XML
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property>
    <name>dfs.replication</name>
    <value>1</value>
  </property>
  <property>
    <name>dfs.namenode.name.dir</name>
    <value>file://${DATA_DIR}/hdfs/namenode</value>
  </property>
  <property>
    <name>dfs.datanode.data.dir</name>
    <value>file://${DATA_DIR}/hdfs/datanode</value>
  </property>
</configuration>
XML

cat > "$HADOOP_CONF_DIR/mapred-site.xml" <<XML
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property>
    <name>mapreduce.framework.name</name>
    <value>yarn</value>
  </property>
</configuration>
XML

cat > "$HADOOP_CONF_DIR/yarn-site.xml" <<XML
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property>
    <name>yarn.resourcemanager.hostname</name>
    <value>localhost</value>
  </property>
  <property>
    <name>yarn.nodemanager.aux-services</name>
    <value>mapreduce_shuffle</value>
  </property>
  <property>
    <name>yarn.nodemanager.aux-services.mapreduce_shuffle.class</name>
    <value>org.apache.hadoop.mapred.ShuffleHandler</value>
  </property>
  <property>
    <name>yarn.nodemanager.resource.memory-mb</name>
    <value>1024</value>
  </property>
  <property>
    <name>yarn.scheduler.maximum-allocation-mb</name>
    <value>1024</value>
  </property>
  <property>
    <name>yarn.scheduler.minimum-allocation-mb</name>
    <value>256</value>
  </property>
  <property>
    <name>yarn.nodemanager.resource.cpu-vcores</name>
    <value>2</value>
  </property>
</configuration>
XML

printf 'localhost\n' > "$HADOOP_CONF_DIR/workers"

# Make Hadoop use the exact Java 8 JDK irrespective of the system default Java.
if ! grep -q '^export JAVA_HOME=' "$HADOOP_CONF_DIR/hadoop-env.sh"; then
    printf '\n' >> "$HADOOP_CONF_DIR/hadoop-env.sh"
fi
sed -i '/^[[:space:]]*export JAVA_HOME=/d' "$HADOOP_CONF_DIR/hadoop-env.sh"
printf '\n# Java 8 configured by the Hadoop 3.2.3 installer\nexport JAVA_HOME="%s"\n' "$JAVA_HOME" >> "$HADOOP_CONF_DIR/hadoop-env.sh"

# Set up SSH localhost authentication required by Hadoop's start-dfs/start-yarn scripts.
log "Configuring passwordless SSH to localhost for the current user..."
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
sudo mkdir -p /run/sshd
sudo chmod 755 /run/sshd
sudo systemctl enable --now ssh 2>/dev/null || sudo service ssh start
if [[ ! -s "$HOME/.ssh/id_rsa" || ! -s "$HOME/.ssh/id_rsa.pub" ]]; then
    mkdir -p "$BACKUP_DIR/ssh"
    [[ -e "$HOME/.ssh/id_rsa" ]] && cp -p "$HOME/.ssh/id_rsa" "$BACKUP_DIR/ssh/id_rsa.partial" || true
    [[ -e "$HOME/.ssh/id_rsa.pub" ]] && cp -p "$HOME/.ssh/id_rsa.pub" "$BACKUP_DIR/ssh/id_rsa.pub.partial" || true
    rm -f "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_rsa.pub"
    ssh-keygen -t rsa -b 3072 -N '' -f "$HOME/.ssh/id_rsa" -q
fi
chmod 600 "$HOME/.ssh/id_rsa"
chmod 644 "$HOME/.ssh/id_rsa.pub"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
if ! grep -qxF "$(cat "$HOME/.ssh/id_rsa.pub")" "$HOME/.ssh/authorized_keys"; then
    cat "$HOME/.ssh/id_rsa.pub" >> "$HOME/.ssh/authorized_keys"
fi
ssh-keyscan -H localhost 127.0.0.1 >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
chmod 600 "$HOME/.ssh/known_hosts" 2>/dev/null || true

# Avoid interactive host-key/password prompts from Hadoop's SSH fan-out scripts.
if [[ -f "$HOME/.ssh/config" ]]; then
    cp -p "$HOME/.ssh/config" "$BACKUP_DIR/ssh-config.before-install"
fi
cat > "$TMP_DIR/ssh-config.new" <<'SSHCONF'
# >>> HADOOP LOCALHOST SSH MANAGED >>>
Host localhost 127.0.0.1
    StrictHostKeyChecking accept-new
    BatchMode yes
    ConnectTimeout 10
# <<< HADOOP LOCALHOST SSH MANAGED <<<
SSHCONF
if [[ -f "$HOME/.ssh/config" ]]; then
    awk '
        /# >>> HADOOP LOCALHOST SSH MANAGED >>>/ {skip=1; next}
        /# <<< HADOOP LOCALHOST SSH MANAGED <<</ {skip=0; next}
        !skip {print}
    ' "$HOME/.ssh/config" >> "$TMP_DIR/ssh-config.new"
fi
cat "$TMP_DIR/ssh-config.new" > "$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"
ssh -o BatchMode=yes -o PreferredAuthentications=publickey localhost 'echo SSH_LOCALHOST_OK' \
    || die "Passwordless SSH to localhost failed. Check that ssh service is running and port 22 is available."

# Save a managed environment block. The original .bashrc is backed up above.
cat >> "$HOME/.bashrc" <<ENVBLOCK

# >>> HADOOP 3.2.3 MANAGED >>>
export JAVA_HOME="${JAVA_DIR}"
export HADOOP_HOME="${HADOOP_LINK}"
export HADOOP_CONF_DIR="\$HADOOP_HOME/etc/hadoop"
export HADOOP_COMMON_HOME="\$HADOOP_HOME"
export HADOOP_HDFS_HOME="\$HADOOP_HOME"
export HADOOP_MAPRED_HOME="\$HADOOP_HOME"
export HADOOP_YARN_HOME="\$HADOOP_HOME"
export HADOOP_COMMON_LIB_NATIVE_DIR="\$HADOOP_HOME/lib/native"
export PATH="\$JAVA_HOME/bin:\$HADOOP_HOME/bin:\$HADOOP_HOME/sbin:\$PATH"
# <<< HADOOP 3.2.3 MANAGED <<<
ENVBLOCK

# Use explicit paths for this run; also ensure executable scripts are present.
[[ -x "$HADOOP_HOME/bin/hdfs" && -x "$HADOOP_HOME/bin/yarn" && -x "$HADOOP_HOME/bin/hadoop" ]] \
    || die "Hadoop command files are missing after extraction."

log "Checking Hadoop and Java versions before formatting HDFS..."
java -version
hadoop version

log "Formatting the NEW NameNode metadata directory..."
# The old data directory was moved to the dated backup above; this is a fresh HDFS namespace.
hdfs namenode -format -force -nonInteractive

log "Starting HDFS services (NameNode, DataNode, SecondaryNameNode)..."
start-dfs.sh
sleep 4
log "Starting YARN services (ResourceManager, NodeManager)..."
start-yarn.sh

log "Waiting for all five core Hadoop daemons..."
EXPECTED_CLASSES=(
    org.apache.hadoop.hdfs.server.namenode.NameNode
    org.apache.hadoop.hdfs.server.datanode.DataNode
    org.apache.hadoop.hdfs.server.namenode.SecondaryNameNode
    org.apache.hadoop.yarn.server.resourcemanager.ResourceManager
    org.apache.hadoop.yarn.server.nodemanager.NodeManager
)
missing=()
for attempt in $(seq 1 30); do
    current_list="$(jps -l 2>/dev/null || true)"
    missing=()
    for class_name in "${EXPECTED_CLASSES[@]}"; do
        grep -Fq "$class_name" <<< "$current_list" || missing+=("$class_name")
    done
    [[ "${#missing[@]}" -eq 0 ]] && break
    sleep 2
done

printf '\n==================== JPS OUTPUT ====================\n'
jps -l || true
printf '====================================================\n'

if [[ "${#missing[@]}" -ne 0 ]]; then
    printf '\n[ERROR] These core daemons did not start:\n' >&2
    printf '  - %s\n' "${missing[@]}" >&2
    printf '\nCheck logs in: %s/logs\n' "$HADOOP_HOME" >&2
    printf 'Backup of previous files: %s\n' "$BACKUP_DIR" >&2
    exit 1
fi

log "Checking HDFS status and creating the current user's HDFS home directory..."
hdfs dfsadmin -report > "$TMP_DIR/hdfs-report.txt"
head -n 25 "$TMP_DIR/hdfs-report.txt"
hdfs dfs -mkdir -p "/user/$(id -un)"
hdfs dfs -chown "$(id -un):$(id -gn)" "/user/$(id -un)"

printf '\n============================================================\n'
printf ' Hadoop %s installation and startup completed.\n' "$HADOOP_VERSION"
printf ' Java:       %s\n' "$JAVA_HOME"
printf ' Hadoop:     %s\n' "$HADOOP_HOME"
printf ' HDFS data:  %s\n' "$DATA_DIR"
printf ' Old files:  %s\n' "$BACKUP_DIR"
printf '\nOpen a NEW terminal, or run: source ~/.bashrc\n'
printf 'Then verify with: jps\n'
printf 'HDFS web UI:  http://localhost:9870\n'
printf 'YARN web UI:  http://localhost:8088\n'
printf '============================================================\n'
