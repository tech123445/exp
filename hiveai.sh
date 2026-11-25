#!/usr/bin/env bash
# Apache Hive 3.1.2 installer for Ubuntu 22.04 and 24.04.
# Automatically discovers Java 8 and Hadoop 3.2.3, backs up old Hive files,
# normalizes stale HIVE_HOME paths, configures Derby, and starts Hive services.
#
# Run as the normal desktop user (NOT with sudo).
# Hadoop 3.2.3 must already be installed and all five Hadoop daemons must be running.

set -Eeuo pipefail

readonly HIVE_VERSION="3.1.2"
readonly HADOOP_VERSION="3.2.3"
readonly HIVE_URL="https://mirrors.huaweicloud.com/repository/apache/hive/hive-3.1.2/apache-hive-3.1.2-bin.tar.gz"
readonly INSTALL_DIR="/opt/apache-hive-${HIVE_VERSION}-bin"
readonly HIVE_HOME_FIXED="/opt/hive"
readonly LEGACY_HIVE_LINK="/usr/local/hive"
readonly DATA_DIR="${HOME}/hive-data-${HIVE_VERSION}"
readonly LOG_DIR="${HOME}/hive-logs-${HIVE_VERSION}"

log()  { printf '\n[HIVE-INSTALL] %s\n' "$*"; }
warn() { printf '\n[WARNING] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

TMP_DIR=""
BACKUP_DIR=""
JAVA_HOME_FOUND=""
HADOOP_HOME_FOUND=""
HADOOP_CONF_FOUND=""

print_logs() {
    local f
    for f in "$LOG_DIR"/metastore.log "$LOG_DIR"/hiveserver2.log; do
        if [[ -f "$f" ]]; then
            printf '\n--- Recent log: %s ---\n' "$f" >&2
            tail -n 80 "$f" >&2 || true
        fi
    done
}

on_error() {
    local rc=$?
    printf '\n[ERROR] Installer stopped at line %s (exit code %s).\n' "${BASH_LINENO[0]:-unknown}" "$rc" >&2
    print_logs
    exit "$rc"
}
cleanup() {
    [[ -z "$TMP_DIR" || ! -d "$TMP_DIR" ]] || rm -rf "$TMP_DIR"
}
trap on_error ERR
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Basic platform and permission checks
# ---------------------------------------------------------------------------
if [[ "${EUID}" -eq 0 ]]; then
    die "Do not run this script with sudo. Run it as your normal Ubuntu user."
fi

[[ -r /etc/os-release ]] || die "Cannot identify this operating system."
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This installer supports Ubuntu 22.04 / 24.04 only. Detected: ${PRETTY_NAME:-unknown}."
case "${VERSION_ID:-}" in
    22.04|24.04) ;;
    *) die "Supported Ubuntu versions are 22.04 and 24.04. Detected: ${VERSION_ID:-unknown}." ;;
esac

command -v sudo >/dev/null 2>&1 || die "sudo is required."
command -v awk >/dev/null 2>&1 || die "awk is required."
command -v find >/dev/null 2>&1 || die "find is required."
sudo -v || die "Could not obtain sudo permission."

USER_NAME="$(id -un)"
USER_GROUP="$(id -gn)"
USER_UID="$(id -u)"

TMP_DIR="$(mktemp -d -t hive312-install.XXXXXX)"
BACKUP_STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${HOME}/hive-install-backup-${BACKUP_STAMP}"
mkdir -p "$BACKUP_DIR"

# ---------------------------------------------------------------------------
# 2. Discover a working Java 8 installation rather than assuming one path
# ---------------------------------------------------------------------------
log "Discovering Java 8..."

JAVA_CANDIDATES=()
[[ -n "${JAVA_HOME:-}" ]] && JAVA_CANDIDATES+=("$JAVA_HOME")
JAVA_CANDIDATES+=(
    /opt/temurin8
    /opt/java8
    /usr/lib/jvm/temurin-8-jdk-amd64
    /usr/lib/jvm/temurin-8-jdk
    /usr/lib/jvm/adoptium-8-jdk-amd64
    /usr/lib/jvm/java-8-openjdk-amd64
    /usr/lib/jvm/java-8-openjdk
)

if command -v java >/dev/null 2>&1; then
    JAVA_BIN_REAL="$(readlink -f "$(command -v java)" 2>/dev/null || true)"
    [[ -z "$JAVA_BIN_REAL" ]] || JAVA_CANDIDATES+=("${JAVA_BIN_REAL%/bin/java}")
fi

for root in /usr/lib/jvm /opt; do
    [[ -d "$root" ]] || continue
    while IFS= read -r java_bin; do
        JAVA_CANDIDATES+=("${java_bin%/bin/java}")
    done < <(find "$root" -maxdepth 5 \( -type f -o -type l \) -path '*/bin/java' -executable 2>/dev/null || true)
done

declare -A JAVA_SEEN=()
for candidate in "${JAVA_CANDIDATES[@]}"; do
    [[ -n "$candidate" && -x "$candidate/bin/java" ]] || continue
    [[ -n "${JAVA_SEEN[$candidate]:-}" ]] && continue
    JAVA_SEEN["$candidate"]=1
    version_output="$("$candidate/bin/java" -version 2>&1 || true)"
    if grep -Eq 'version "1\.8\.' <<< "$version_output"; then
        JAVA_HOME_FOUND="$candidate"
        break
    fi
done

[[ -n "$JAVA_HOME_FOUND" ]] || die "Java 8 was not found. Install Java 8 first (the companion Hadoop installer installs Temurin 8), then rerun."
[[ -x "$JAVA_HOME_FOUND/bin/java" ]] || die "The discovered Java 8 path is invalid: $JAVA_HOME_FOUND"

# ---------------------------------------------------------------------------
# 3. Discover Hadoop 3.2.3 and its configuration directory
# ---------------------------------------------------------------------------
log "Discovering Hadoop 3.2.3..."

HADOOP_CANDIDATES=()
[[ -n "${HADOOP_HOME:-}" ]] && HADOOP_CANDIDATES+=("$HADOOP_HOME")
HADOOP_CANDIDATES+=(
    /opt/hadoop-3.2.3
    /opt/hadoop
    /usr/local/hadoop-3.2.3
    /usr/local/hadoop
    "${HOME}/hadoop-3.2.3"
    "${HOME}/hadoop"
)

if command -v hadoop >/dev/null 2>&1; then
    HADOOP_BIN_REAL="$(readlink -f "$(command -v hadoop)" 2>/dev/null || true)"
    [[ -z "$HADOOP_BIN_REAL" ]] || HADOOP_CANDIDATES+=("$(dirname "$(dirname "$HADOOP_BIN_REAL")")")
fi

declare -A HADOOP_SEEN=()
for candidate in "${HADOOP_CANDIDATES[@]}"; do
    [[ -n "$candidate" && -x "$candidate/bin/hadoop" && -x "$candidate/bin/hdfs" ]] || continue
    candidate_real="$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")"
    [[ -n "${HADOOP_SEEN[$candidate_real]:-}" ]] && continue
    HADOOP_SEEN["$candidate_real"]=1

    conf_candidate=""
    if [[ -n "${HADOOP_CONF_DIR:-}" && -f "${HADOOP_CONF_DIR}/core-site.xml" ]]; then
        conf_candidate="$HADOOP_CONF_DIR"
    elif [[ -f "$candidate_real/etc/hadoop/core-site.xml" ]]; then
        conf_candidate="$candidate_real/etc/hadoop"
    fi
    [[ -n "$conf_candidate" ]] || continue

    version_output="$(env JAVA_HOME="$JAVA_HOME_FOUND" HADOOP_HOME="$candidate_real" HADOOP_CONF_DIR="$conf_candidate" \
        "$candidate_real/bin/hadoop" version 2>&1 || true)"
    if grep -Fq "Hadoop ${HADOOP_VERSION}" <<< "$version_output"; then
        HADOOP_HOME_FOUND="$candidate_real"
        HADOOP_CONF_FOUND="$conf_candidate"
        break
    fi
done

[[ -n "$HADOOP_HOME_FOUND" ]] || die "Hadoop 3.2.3 was not found. Install Hadoop 3.2.3 first. Searched common paths and the current HADOOP_HOME/PATH."
[[ -f "$HADOOP_CONF_FOUND/core-site.xml" && -f "$HADOOP_CONF_FOUND/hdfs-site.xml" ]] || die "Hadoop configuration is incomplete in $HADOOP_CONF_FOUND."
[[ -f "$HADOOP_CONF_FOUND/yarn-site.xml" && -f "$HADOOP_CONF_FOUND/mapred-site.xml" ]] || warn "One or both YARN/MapReduce configuration files are missing; Hive may not be able to submit MapReduce jobs."

export JAVA_HOME="$JAVA_HOME_FOUND"
export HADOOP_HOME="$HADOOP_HOME_FOUND"
export HADOOP_CONF_DIR="$HADOOP_CONF_FOUND"
export HIVE_HOME="$HIVE_HOME_FIXED"
export HIVE_CONF_DIR="$HIVE_HOME/conf"
export PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$HIVE_HOME/bin:$PATH"

log "Using Java: $JAVA_HOME"
log "Using Hadoop: $HADOOP_HOME"
log "Using Hadoop configuration: $HADOOP_CONF_DIR"

# Require the daemons expected by the single-node Hadoop setup.
JPS_OUTPUT="$("$JAVA_HOME/bin/jps" -l 2>/dev/null || true)"
REQUIRED_HADOOP_CLASSES=(
    org.apache.hadoop.hdfs.server.namenode.NameNode
    org.apache.hadoop.hdfs.server.datanode.DataNode
    org.apache.hadoop.hdfs.server.namenode.SecondaryNameNode
    org.apache.hadoop.yarn.server.resourcemanager.ResourceManager
    org.apache.hadoop.yarn.server.nodemanager.NodeManager
)
for class_name in "${REQUIRED_HADOOP_CLASSES[@]}"; do
    if ! grep -Fq "$class_name" <<< "$JPS_OUTPUT"; then
        die "Hadoop daemon is missing: $class_name. Start Hadoop HDFS and YARN first, then rerun this Hive installer."
    fi
done

# Confirm HDFS is actually reachable; a JPS process alone does not prove that HDFS works.
if ! env JAVA_HOME="$JAVA_HOME" HADOOP_HOME="$HADOOP_HOME" HADOOP_CONF_DIR="$HADOOP_CONF_DIR" \
    "$HADOOP_HOME/bin/hdfs" dfs -ls / >/dev/null 2>&1; then
    die "HDFS processes exist but HDFS is not reachable. Check Hadoop before installing Hive."
fi

# ---------------------------------------------------------------------------
# 4. Install tools only if required
# ---------------------------------------------------------------------------
log "Checking required system utilities..."
MISSING_TOOLS=()
for tool in curl tar gzip ss nc pgrep pkill; do
    command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS+=("$tool")
done

if ((${#MISSING_TOOLS[@]} > 0)); then
    log "Installing missing utilities..."
    sudo apt-get -o DPkg::Lock::Timeout=180 update
    sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y \
        ca-certificates curl tar gzip iproute2 netcat-openbsd procps
fi

# Check free space before downloading/extracting. Hive archive is about 266 MB.
for target in /opt "$HOME"; do
    available_kb="$(df -Pk "$target" | awk 'NR==2 {print $4}')"
    [[ "${available_kb:-}" =~ ^[0-9]+$ ]] || die "Could not check free disk space on $target."
    (( available_kb >= 1200000 )) || die "Less than 1.2 GB free on $target. Free disk space and retry."
done

# ---------------------------------------------------------------------------
# 5. Download and fully inspect the archive BEFORE changing existing files
# ---------------------------------------------------------------------------
ARCHIVE="$TMP_DIR/apache-hive-${HIVE_VERSION}-bin.tar.gz"
ARCHIVE_LIST="$TMP_DIR/hive-archive-list.txt"

log "Downloading Hive ${HIVE_VERSION} from the supplied Huawei mirror..."
curl --fail --location --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 30 \
    "$HIVE_URL" -o "$ARCHIVE"

log "Validating the downloaded archive..."
gzip -t "$ARCHIVE"
tar -tzf "$ARCHIVE" > "$ARCHIVE_LIST"

for required_entry in \
    "apache-hive-${HIVE_VERSION}-bin/bin/hive" \
    "apache-hive-${HIVE_VERSION}-bin/bin/hiveserver2" \
    "apache-hive-${HIVE_VERSION}-bin/bin/schematool" \
    "apache-hive-${HIVE_VERSION}-bin/lib/hive-exec-${HIVE_VERSION}.jar"; do
    if ! grep -Fxq "$required_entry" "$ARCHIVE_LIST"; then
        die "The Hive archive is missing required file: $required_entry. The previous installation has not been changed."
    fi
done

mkdir "$TMP_DIR/extracted"
tar -xzf "$ARCHIVE" -C "$TMP_DIR/extracted"
EXTRACTED_DIR="$TMP_DIR/extracted/apache-hive-${HIVE_VERSION}-bin"
[[ -x "$EXTRACTED_DIR/bin/hive" ]] || die "Hive CLI is missing from the extracted archive."
[[ -x "$EXTRACTED_DIR/bin/hiveserver2" ]] || die "HiveServer2 launcher is missing from the extracted archive."
[[ -s "$EXTRACTED_DIR/lib/hive-exec-${HIVE_VERSION}.jar" ]] || die "Hive execution JAR is missing from the extracted archive."
[[ -x "$EXTRACTED_DIR/bin/schematool" ]] || die "Hive schematool is missing from the extracted archive."

# ---------------------------------------------------------------------------
# 6. Stop previous Hive services only (never stop Hadoop)
# ---------------------------------------------------------------------------
find_hive_pids() {
    ps -eo pid=,comm=,args= | awk '
        $2 == "java" &&
        ($0 ~ /org\.apache\.hadoop\.hive\.metastore\.HiveMetaStore/ ||
         $0 ~ /org\.apache\.hive\.service\.server\.HiveServer2/) {
            print $1
        }'
}

log "Stopping previous Hive Metastore / HiveServer2 processes, if any..."
OLD_PIDS="$(find_hive_pids || true)"
if [[ -n "$OLD_PIDS" ]]; then
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        owner_uid="$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
        if [[ "$owner_uid" == "$USER_UID" ]]; then
            kill -TERM "$pid" 2>/dev/null || true
        else
            sudo kill -TERM "$pid" 2>/dev/null || true
        fi
    done <<< "$OLD_PIDS"

    for _ in $(seq 1 20); do
        [[ -z "$(find_hive_pids || true)" ]] && break
        sleep 1
    done

    OLD_PIDS="$(find_hive_pids || true)"
    if [[ -n "$OLD_PIDS" ]]; then
        while read -r pid; do
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            owner_uid="$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
            if [[ "$owner_uid" == "$USER_UID" ]]; then
                kill -KILL "$pid" 2>/dev/null || true
            else
                sudo kill -KILL "$pid" 2>/dev/null || true
            fi
        done <<< "$OLD_PIDS"
    fi
fi

# ---------------------------------------------------------------------------
# 7. Handle port conflicts safely
# ---------------------------------------------------------------------------
for port in 9083 10000; do
    listener="$(ss -H -ltnp "sport = :${port}" 2>/dev/null || true)"
    if [[ -n "$listener" ]]; then
        printf '%s\n' "$listener" >&2
        die "Port ${port} is still occupied by a process that is not recognized as this user's Hive service. It was NOT killed. Stop that application or choose another port."
    fi
done

# ---------------------------------------------------------------------------
# 8. Back up old Hive installations/data/configuration
# ---------------------------------------------------------------------------
backup_item() {
    local source_path="$1"
    [[ -e "$source_path" || -L "$source_path" ]] || return 0
    local relative_path="${source_path#/}"
    local destination_path="${BACKUP_DIR}/${relative_path}"
    sudo mkdir -p "$(dirname "$destination_path")"
    sudo mv -- "$source_path" "$destination_path"
    sudo chown -R "${USER_NAME}:${USER_GROUP}" "$BACKUP_DIR"
    log "Backed up: $source_path"
}

log "Backing up old Hive installations, data and logs..."
for candidate in \
    "$HIVE_HOME_FIXED" "$INSTALL_DIR" "$LEGACY_HIVE_LINK" \
    /usr/local/apache-hive-3.1.2-bin /usr/local/apache-hive-3.1.2 \
    "$HOME/hive" "$HOME/apache-hive-3.1.2-bin" \
    "$DATA_DIR" "$LOG_DIR" \
    /etc/profile.d/zzzz-hive-3.1.2.sh; do
    backup_item "$candidate"
done

shopt -s nullglob
for candidate in /opt/apache-hive-3.* /usr/local/apache-hive-3.* "$HOME"/apache-hive-3.*; do
    backup_item "$candidate"
done
shopt -u nullglob

# Backup and sanitize user shell startup files. Remove stale Hive exports/path
# entries only; preserve unrelated settings and all other user customizations.
for rc_file in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.zshrc"; do
    [[ -f "$rc_file" ]] || continue
    cp -p "$rc_file" "$BACKUP_DIR/$(basename "$rc_file").before-hive"
    awk '
      /# >>> HIVE AUTO CONFIG >>>/ {skip=1; next}
      /# <<< HIVE AUTO CONFIG <<</ {skip=0; next}
      /# >>> HIVE 3.1.2 MANAGED >>>/ {skip=1; next}
      /# <<< HIVE 3.1.2 MANAGED <<</ {skip=0; next}
      skip {next}
      /^[[:space:]]*(export[[:space:]]+)?HIVE_HOME=/ {next}
      /^[[:space:]]*(export[[:space:]]+)?HIVE_CONF_DIR=/ {next}
      /^[[:space:]]*(export[[:space:]]+)?HIVE_LOG_DIR=/ {next}
      /^[[:space:]]*export[[:space:]]+PATH=.*(\/usr\/local\/hive|\/opt\/hive)/ {next}
      {print}
    ' "$rc_file" > "$TMP_DIR/$(basename "$rc_file").clean"
    cat "$TMP_DIR/$(basename "$rc_file").clean" > "$rc_file"
done

# Also remove stale system-wide HIVE_HOME assignments from /etc/environment.
if [[ -f /etc/environment ]] && grep -Eq '^[[:space:]]*(HIVE_HOME|HIVE_CONF_DIR|HIVE_LOG_DIR)=' /etc/environment; then
    sudo cp -p /etc/environment "$BACKUP_DIR/etc-environment.before-hive"
    awk '
      !/^[[:space:]]*HIVE_HOME=/ &&
      !/^[[:space:]]*HIVE_CONF_DIR=/ &&
      !/^[[:space:]]*HIVE_LOG_DIR=/ {print}
    ' /etc/environment > "$TMP_DIR/environment.clean"
    sudo install -m 644 "$TMP_DIR/environment.clean" /etc/environment
fi

# ---------------------------------------------------------------------------
# 9. Install Hive and create compatibility paths
# ---------------------------------------------------------------------------
log "Installing Hive ${HIVE_VERSION}..."
sudo mv "$EXTRACTED_DIR" "$INSTALL_DIR"
sudo chown -R "${USER_NAME}:${USER_GROUP}" "$INSTALL_DIR"

# Use Hadoop's Guava JAR to avoid the common Hive/Hadoop Guava classpath clash.
HADOOP_GUAVA="$(find "$HADOOP_HOME/share/hadoop/common/lib" -maxdepth 1 -type f -name 'guava-*.jar' -print -quit)"
[[ -n "$HADOOP_GUAVA" ]] || die "Could not locate Hadoop's Guava JAR in $HADOOP_HOME/share/hadoop/common/lib."
rm -f "$INSTALL_DIR/lib"/guava-*.jar
cp "$HADOOP_GUAVA" "$INSTALL_DIR/lib/"

# Ensure the exact Hive execution JAR is present before making Hive active.
[[ -s "$INSTALL_DIR/lib/hive-exec-${HIVE_VERSION}.jar" ]] || die "Hive execution JAR is not present after extraction."

sudo ln -s "$INSTALL_DIR" "$HIVE_HOME_FIXED"
# Compatibility alias for old launchers/configurations that still refer to /usr/local/hive.
sudo ln -s "$HIVE_HOME_FIXED" "$LEGACY_HIVE_LINK"

export HIVE_HOME="$HIVE_HOME_FIXED"
export HIVE_CONF_DIR="$HIVE_HOME/conf"
export HIVE_LOG_DIR="$LOG_DIR"
export PATH="$HIVE_HOME/bin:$PATH"

# ---------------------------------------------------------------------------
# 10. Create clean Hive data, environment and configuration
# ---------------------------------------------------------------------------
mkdir -p "$DATA_DIR" "$DATA_DIR/scratch" "$DATA_DIR/tmp" "$LOG_DIR"
chmod 700 "$DATA_DIR" "$DATA_DIR/scratch" "$DATA_DIR/tmp" "$LOG_DIR"
DERBY_DB_PATH="${DATA_DIR}/metastore_db"
[[ ! -e "$DERBY_DB_PATH" ]] || die "A Derby database path already exists after backup: $DERBY_DB_PATH."

cat > "$HIVE_CONF_DIR/hive-env.sh" <<ENV
export JAVA_HOME="${JAVA_HOME}"
export HADOOP_HOME="${HADOOP_HOME}"
export HADOOP_CONF_DIR="${HADOOP_CONF_DIR}"
export HIVE_HOME="${HIVE_HOME_FIXED}"
export HIVE_CONF_DIR="${HIVE_HOME_FIXED}/conf"
export HIVE_LOG_DIR="${LOG_DIR}"
ENV

cat > "$HIVE_CONF_DIR/hive-site.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property>
    <name>hive.metastore.warehouse.dir</name>
    <value>/user/hive/warehouse</value>
  </property>
  <property>
    <name>hive.exec.scratchdir</name>
    <value>/tmp/hive</value>
  </property>
  <property>
    <name>hive.metastore.uris</name>
    <value>thrift://127.0.0.1:9083</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionURL</name>
    <value>jdbc:derby:;databaseName=${DERBY_DB_PATH};create=true</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionDriverName</name>
    <value>org.apache.derby.jdbc.EmbeddedDriver</value>
  </property>
  <property>
    <name>hive.metastore.schema.verification</name>
    <value>false</value>
  </property>
  <!-- Single-user lab setup: allow HiveServer2 to query metastore notification events. -->
  <property>
    <name>hive.metastore.event.db.notification.api.auth</name>
    <value>false</value>
  </property>
  <property>
    <name>datanucleus.schema.autoCreateAll</name>
    <value>true</value>
  </property>
  <property>
    <name>hive.execution.engine</name>
    <value>mr</value>
  </property>
  <property>
    <name>hive.server2.thrift.bind.host</name>
    <value>127.0.0.1</value>
  </property>
  <property>
    <name>hive.server2.thrift.port</name>
    <value>10000</value>
  </property>
  <property>
    <name>hive.server2.transport.mode</name>
    <value>binary</value>
  </property>
  <property>
    <name>hive.server2.enable.doAs</name>
    <value>false</value>
  </property>
  <property>
    <name>hive.cli.print.header</name>
    <value>true</value>
  </property>
</configuration>
XML

# Persist discovered paths system-wide so new terminals and other login shells
# do not inherit a stale /usr/local/hive HIVE_HOME from an earlier install.
cat > "$TMP_DIR/zzzz-hive-3.1.2.sh" <<ENV
# Managed by the Apache Hive 3.1.2 installer.
export JAVA_HOME="${JAVA_HOME}"
export HADOOP_HOME="${HADOOP_HOME}"
export HADOOP_CONF_DIR="${HADOOP_CONF_DIR}"
export HIVE_HOME="${HIVE_HOME_FIXED}"
export HIVE_CONF_DIR="\${HIVE_HOME}/conf"
export HIVE_LOG_DIR="${LOG_DIR}"
export PATH="\${HIVE_HOME}/bin:\${HADOOP_HOME}/bin:\${HADOOP_HOME}/sbin:\${JAVA_HOME}/bin:\${PATH}"
ENV
sudo install -m 644 "$TMP_DIR/zzzz-hive-3.1.2.sh" /etc/profile.d/zzzz-hive-3.1.2.sh

cat >> "$HOME/.bashrc" <<'BASHBLOCK'

# >>> HIVE AUTO CONFIG >>>
[ -r /etc/profile.d/zzzz-hive-3.1.2.sh ] && . /etc/profile.d/zzzz-hive-3.1.2.sh
# <<< HIVE AUTO CONFIG <<<
BASHBLOCK

# Ensure this running installer and all child Hive processes use the canonical paths,
# irrespective of stale variables inherited from the terminal that launched it.
export JAVA_HOME HADOOP_HOME HADOOP_CONF_DIR
export HIVE_HOME="$HIVE_HOME_FIXED"
export HIVE_CONF_DIR="$HIVE_HOME/conf"
export HIVE_LOG_DIR="$LOG_DIR"
export PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$HIVE_HOME/bin:$PATH"
unset HIVE_AUX_JARS_PATH

HIVE_ENV=(
    "JAVA_HOME=$JAVA_HOME"
    "HADOOP_HOME=$HADOOP_HOME"
    "HADOOP_CONF_DIR=$HADOOP_CONF_DIR"
    "HIVE_HOME=$HIVE_HOME"
    "HIVE_CONF_DIR=$HIVE_CONF_DIR"
    "HIVE_LOG_DIR=$HIVE_LOG_DIR"
    "PATH=$PATH"
)

# ---------------------------------------------------------------------------
# 11. Prepare HDFS warehouse and initialize embedded Derby
# ---------------------------------------------------------------------------
log "Preparing Hive HDFS warehouse and scratch directories..."
env "${HIVE_ENV[@]}" "$HADOOP_HOME/bin/hdfs" dfs -mkdir -p /tmp /user/hive/warehouse
env "${HIVE_ENV[@]}" "$HADOOP_HOME/bin/hdfs" dfs -chmod 1777 /tmp
env "${HIVE_ENV[@]}" "$HADOOP_HOME/bin/hdfs" dfs -chmod g+w /user/hive/warehouse

log "Initializing the embedded Derby metastore schema..."
[[ ! -e "$DERBY_DB_PATH" ]] || die "Derby database directory unexpectedly exists before initialization."
env "${HIVE_ENV[@]}" "$HIVE_HOME/bin/schematool" -dbType derby -initSchema \
    > "$LOG_DIR/schematool-init.log" 2>&1 || {
        cat "$LOG_DIR/schematool-init.log" >&2 || true
        die "Derby schema initialization failed. Previous files are preserved in $BACKUP_DIR."
    }

log "Verifying Derby schema..."
env "${HIVE_ENV[@]}" "$HIVE_HOME/bin/schematool" -dbType derby -info \
    > "$LOG_DIR/schematool-info.log" 2>&1 || {
        cat "$LOG_DIR/schematool-info.log" >&2 || true
        die "Derby schema verification failed."
    }
cat "$LOG_DIR/schematool-info.log"

# ---------------------------------------------------------------------------
# 12. Start Hive Metastore and HiveServer2; verify ports and a SQL query
# ---------------------------------------------------------------------------
for port in 9083 10000; do
    listener="$(ss -H -ltnp "sport = :${port}" 2>/dev/null || true)"
    [[ -z "$listener" ]] || die "Port ${port} became occupied before Hive startup. Details: $listener"
done

log "Starting Hive Metastore..."
nohup env "${HIVE_ENV[@]}" \
    "$HIVE_HOME/bin/hive" \
    --hiveconf hive.metastore.event.db.notification.api.auth=false \
    --hiveconf hive.root.logger=INFO,console \
    --service metastore \
    >"$LOG_DIR/metastore.log" 2>&1 < /dev/null &
METASTORE_PID=$!
printf '%s\n' "$METASTORE_PID" > "$DATA_DIR/metastore.pid"

wait_for_port() {
    local port="$1"
    local pid="$2"
    local service_name="$3"
    local max_attempts="$4"
    local attempt
    for attempt in $(seq 1 "$max_attempts"); do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            log "$service_name is listening on 127.0.0.1:$port"
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            warn "$service_name process exited before opening port $port."
            tail -n 100 "$LOG_DIR/${service_name,,}.log" >&2 || true
            return 1
        fi
        sleep 2
    done
    warn "$service_name did not open port $port within the startup window."
    tail -n 120 "$LOG_DIR/${service_name,,}.log" >&2 || true
    return 1
}

wait_for_port 9083 "$METASTORE_PID" "Metastore" 60 || die "Hive Metastore startup failed. See $LOG_DIR/metastore.log."

log "Starting HiveServer2 with the canonical HIVE_HOME=$HIVE_HOME ..."
nohup env "${HIVE_ENV[@]}" \
    "$HIVE_HOME/bin/hive" \
    --hiveconf hive.metastore.event.db.notification.api.auth=false \
    --hiveconf hive.root.logger=INFO,console \
    --service hiveserver2 \
    >"$LOG_DIR/hiveserver2.log" 2>&1 < /dev/null &
HS2_PID=$!
printf '%s\n' "$HS2_PID" > "$DATA_DIR/hiveserver2.pid"

wait_for_port 10000 "$HS2_PID" "HiveServer2" 90 || {
    # A failed HS2 startup must not leave a hung Java process behind.
    HS2_PIDS="$(ps -eo pid=,comm=,args= | awk '$2 == "java" && $0 ~ /org\.apache\.hive\.service\.server\.HiveServer2/ {print $1}')"
    if [[ -n "$HS2_PIDS" ]]; then
        while read -r pid; do
            [[ "$pid" =~ ^[0-9]+$ ]] && kill -TERM "$pid" 2>/dev/null || true
        done <<< "$HS2_PIDS"
    fi
    warn "HiveServer2 log: $LOG_DIR/hiveserver2.log"
    warn "Metastore log (check for 'not authorized' / notification API errors): $LOG_DIR/metastore.log"
    tail -n 100 "$LOG_DIR/metastore.log" >&2 || true
    die "HiveServer2 startup failed. Both service logs and previous installations are preserved."
}

log "Testing HiveServer2 with Beeline..."
timeout 120 env "${HIVE_ENV[@]}" \
    "$HIVE_HOME/bin/beeline" -u 'jdbc:hive2://127.0.0.1:10000/default' -n "$USER_NAME" \
    -e 'SHOW DATABASES;' > "$LOG_DIR/beeline-test.log" 2>&1 || {
        cat "$LOG_DIR/beeline-test.log" >&2 || true
        tail -n 120 "$LOG_DIR/hiveserver2.log" >&2 || true
        die "HiveServer2 opened port 10000, but the Beeline SQL test failed."
    }
cat "$LOG_DIR/beeline-test.log"

# ---------------------------------------------------------------------------
# 13. Final verification
# ---------------------------------------------------------------------------
log "Final Java process check..."
"$JAVA_HOME/bin/jps" -l || true

printf '\n============================================================\n'
printf ' Hive %s installation and startup completed successfully.\n' "$HIVE_VERSION"
printf ' Ubuntu:        %s\n' "$VERSION_ID"
printf ' Java:          %s\n' "$JAVA_HOME"
printf ' Hadoop:        %s\n' "$HADOOP_HOME"
printf ' Hadoop conf:   %s\n' "$HADOOP_CONF_DIR"
printf ' Hive:          %s\n' "$HIVE_HOME"
printf ' Compatibility: %s -> %s\n' "$LEGACY_HIVE_LINK" "$HIVE_HOME"
printf ' Derby data:    %s\n' "$DERBY_DB_PATH"
printf ' Hive logs:     %s\n' "$LOG_DIR"
printf ' Backup:        %s\n' "$BACKUP_DIR"
printf ' Metastore:     thrift://127.0.0.1:9083\n'
printf ' HiveServer2:   jdbc:hive2://127.0.0.1:10000\n'
printf '\nOpen a NEW terminal, then run: hive\n'
printf 'Beeline: beeline -u jdbc:hive2://127.0.0.1:10000 -n %s\n' "$USER_NAME"
printf '============================================================\n'
