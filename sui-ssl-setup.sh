
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# S-UI HTTPS setup: panel + subscription
# Existing certificate reuse, ACME issuance, renewal deployment hook.

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
die()  { echo -e "${RED}[X]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请使用 root 运行。"

for cmd in openssl curl find awk grep sed date; do
    command -v "$cmd" >/dev/null 2>&1 ||
        die "缺少命令：$cmd"
done

echo "========================================"
echo "       S-UI 一键 HTTPS 配置工具"
echo "========================================"
read -r -p "请输入面板域名（只填域名）: " DOMAIN
DOMAIN="${DOMAIN,,}"
DOMAIN="${DOMAIN%.}"

[[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] ||
    die "域名格式错误。"
[[ "$DOMAIN" == *.* ]] || die "请填写完整域名。"

# Do not install or change an unknown S-UI instance.
if ! command -v s-ui >/dev/null 2>&1 &&
   ! systemctl list-unit-files 2>/dev/null |
       grep -q '^s-ui\.service'; then
    die "没有发现已安装的 S-UI。"
fi

# Install required tools using the detected package manager.
install_pkg() {
    local p="$1"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$p"
    elif command -v apk >/dev/null 2>&1; then
        apk add "$p"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$p"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$p"
    else
        die "无法识别软件包管理器，请手动安装：$p"
    fi
}

# Package names differ by distribution: Debian/Ubuntu use sqlite3;
# Alpine and some RPM-based distributions package the CLI as sqlite.
if ! command -v sqlite3 >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        install_pkg sqlite3
    elif command -v apk >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        install_pkg sqlite
    else
        die "无法识别软件包管理器，请手动安装提供 sqlite3 命令的软件包。"
    fi
fi
command -v socat >/dev/null 2>&1 || install_pkg socat
command -v crontab >/dev/null 2>&1 || {
    if command -v apt-get >/dev/null 2>&1; then
        install_pkg cron
    elif command -v apk >/dev/null 2>&1; then
        install_pkg dcron
    else
        warn "未发现 crontab；acme.sh 的自动续期仍需确认调度器已运行。"
    fi
}

# Locate the real S-UI SQLite database.
DB=""
declare -a ROOTS=(
    /usr/local/s-ui
    /etc/s-ui
    /opt/s-ui
    /root
)

for root in "${ROOTS[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' f; do
        if sqlite3 "$f" \
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='settings';" \
            2>/dev/null | grep -qx 1; then
            # Require key/value columns; do not guess other schemas.
            cols="$(sqlite3 "$f" 'PRAGMA table_info(settings);' 2>/dev/null)"
            if echo "$cols" | grep -q '|key|' &&
               echo "$cols" | grep -q '|value|'; then
                DB="$f"
                break
            fi
        fi
    done < <(
        find "$root" -maxdepth 5 -type f \
          \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) \
          -print0 2>/dev/null
    )
    [[ -n "$DB" ]] && break
done

[[ -n "$DB" ]] || die \
    "未找到结构兼容的 S-UI settings 数据库，未修改配置。"

log "数据库：$DB"

# Verify expected settings before touching anything.
for key in webDomain webCertFile webKeyFile subDomain subCertFile subKeyFile; do
    count="$(sqlite3 "$DB" \
        "SELECT count(*) FROM settings WHERE key='$key';")"
    [[ "$count" == 1 ]] ||
        die "设置项 $key 不存在或不唯一。请先备份并检查此版本数据库。"
done

# Require domain DNS to resolve. This does not prove that it resolves
# to this VPS; the user must verify the address before ACME issuance.
if ! getent ahosts "$DOMAIN" >/dev/null 2>&1; then
    die "$DOMAIN 无法解析。请先配置 DNS A 记录。"
fi

ACME="$HOME/.acme.sh/acme.sh"
if [[ ! -x "$ACME" ]]; then
    log "安装 acme.sh……"
    curl -fsSL https://get.acme.sh | sh -s email=admin@"$DOMAIN"
    ACME="$HOME/.acme.sh/acme.sh"
fi
[[ -x "$ACME" ]] || die "acme.sh 安装失败。"

DEST="/etc/s-ui/certs/$DOMAIN"
install -d -m 700 "$DEST"
CERT="$DEST/fullchain.pem"
KEY="$DEST/privkey.pem"

# Reuse an existing matching certificate if found.
FOUND_CERT=""
FOUND_KEY=""

while IFS= read -r -d '' c; do
    openssl x509 -in "$c" -noout >/dev/null 2>&1 || continue
    openssl x509 -in "$c" -checkhost "$DOMAIN" >/dev/null 2>&1 ||
        continue
    openssl x509 -in "$c" -checkend 86400 >/dev/null 2>&1 ||
        continue

    d="$(dirname "$c")"
    for k in "$d/$DOMAIN.key" "$d/$(basename "$d" _ecc).key" \
             "$d/privkey.pem"; do
        [[ -r "$k" ]] || continue
        openssl pkey -in "$k" -noout >/dev/null 2>&1 || continue

        cp_pub="$(openssl x509 -in "$c" -pubkey -noout |
            openssl pkey -pubin -outform DER 2>/dev/null |
            openssl dgst -sha256)"
        kp_pub="$(openssl pkey -in "$k" -pubout -outform DER 2>/dev/null |
            openssl dgst -sha256)"

        if [[ "$cp_pub" == "$kp_pub" ]]; then
            FOUND_CERT="$c"
            FOUND_KEY="$k"
            break 2
        fi
    done
done < <(
    find "$HOME/.acme.sh" -type f \
      \( -name 'fullchain.cer' -o -name '*.cer' -o -name '*.pem' \) \
      -print0 2>/dev/null
)

if [[ -n "$FOUND_CERT" ]]; then
    log "发现现有有效证书，复用：$FOUND_CERT"
    install -m 644 "$FOUND_CERT" "$CERT"
    install -m 600 "$FOUND_KEY" "$KEY"
else
    log "没有找到匹配的现有证书，尝试申请新证书。"
    log "请确保域名指向本机，公网 TCP 80 可访问且未被占用。"

    "$ACME" --set-default-ca --server letsencrypt
    "$ACME" --issue --standalone -d "$DOMAIN" --keylength ec

    "$ACME" --install-cert -d "$DOMAIN" --ecc \
        --key-file "$KEY" \
        --fullchain-file "$CERT" \
        --reloadcmd "/usr/local/sbin/sui-ssl-reload"

    # Verify that issuance/install produced usable files.
    [[ -s "$CERT" && -s "$KEY" ]] ||
        die "证书签发或安装失败。"
fi

# Check hostname, expiration and key pair.
openssl x509 -in "$CERT" -checkhost "$DOMAIN" -noout ||
    die "证书不匹配域名。"
openssl x509 -in "$CERT" -checkend 86400 -noout ||
    die "证书已过期或即将过期。"

cert_pub="$(openssl x509 -in "$CERT" -pubkey -noout |
    openssl pkey -pubin -outform DER 2>/dev/null |
    openssl dgst -sha256)"
key_pub="$(openssl pkey -in "$KEY" -pubout -outform DER 2>/dev/null |
    openssl dgst -sha256)"
[[ "$cert_pub" == "$key_pub" ]] || die "证书和私钥不匹配。"

# Create the renewal deployment hook. acme.sh will call it after renewal.
cat >/usr/local/sbin/sui-ssl-reload <<'HOOK'
#!/usr/bin/env bash
set -e
# Do not modify the database during renewal; the configured paths are stable.
if command -v systemctl >/dev/null 2>&1 &&
   systemctl cat s-ui.service >/dev/null 2>&1; then
    systemctl restart s-ui
elif command -v s-ui >/dev/null 2>&1; then
    s-ui restart
else
    logger -t sui-ssl "Cannot restart S-UI after certificate renewal"
    exit 1
fi
HOOK
chmod 700 /usr/local/sbin/sui-ssl-reload

# Register deployment hook for reused certificates too.
if [[ -n "$FOUND_CERT" ]]; then
    if [[ "$FOUND_CERT" == *"_ecc/"* ]]; then
        "$ACME" --install-cert -d "$DOMAIN" --ecc \
            --key-file "$KEY" --fullchain-file "$CERT" \
            --reloadcmd "/usr/local/sbin/sui-ssl-reload"
    else
        "$ACME" --install-cert -d "$DOMAIN" \
            --key-file "$KEY" --fullchain-file "$CERT" \
            --reloadcmd "/usr/local/sbin/sui-ssl-reload"
    fi
fi

chmod 700 "$DEST"
chmod 600 "$KEY"
chmod 644 "$CERT"

# Back up the database before changing settings.
BACKUP="${DB}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$DB" "$BACKUP"
log "数据库备份：$BACKUP"

sqlq() { printf "%s" "$1" | sed "s/'/''/g"; }
D="$(sqlq "$DOMAIN")"
C="$(sqlq "$CERT")"
K="$(sqlq "$KEY")"

# The official settings reference defines these keys as strings.
sqlite3 "$DB" <<SQL
.bail on
BEGIN IMMEDIATE;
UPDATE settings SET value='$D' WHERE key='webDomain';
UPDATE settings SET value='$C' WHERE key='webCertFile';
UPDATE settings SET value='$K' WHERE key='webKeyFile';
UPDATE settings SET value='$D' WHERE key='subDomain';
UPDATE settings SET value='$C' WHERE key='subCertFile';
UPDATE settings SET value='$K' WHERE key='subKeyFile';
COMMIT;
SQL

log "已配置面板与订阅服务的域名和证书路径。"

if command -v systemctl >/dev/null 2>&1 &&
   systemctl cat s-ui.service >/dev/null 2>&1; then
    systemctl restart s-ui
    sleep 3
    systemctl is-active --quiet s-ui ||
        die "S-UI 未正常启动。请查看 journalctl -u s-ui。数据库备份：$BACKUP"
elif command -v s-ui >/dev/null 2>&1; then
    s-ui restart
else
    die "配置已写入，但无法识别重启方式。数据库备份：$BACKUP"
fi

# Read the actual port/path from the database.
WEBPORT="$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='webPort';")"
WEBPATH="$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='webPath';")"
SUBPORT="$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='subPort';")"
SUBPATH="$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='subPath';")"

WEBPORT="${WEBPORT:-2095}"
WEBPATH="${WEBPATH:-/app/}"
SUBPORT="${SUBPORT:-2096}"
SUBPATH="${SUBPATH:-/sub/}"

[[ "$WEBPATH" == /* ]] || WEBPATH="/$WEBPATH"
[[ "$WEBPATH" == */ ]] || WEBPATH="$WEBPATH/"
[[ "$SUBPATH" == /* ]] || SUBPATH="/$SUBPATH"
[[ "$SUBPATH" == */ ]] || SUBPATH="$SUBPATH/"

echo
echo "========================================"
echo "             配置完成"
echo "========================================"
echo "面板地址: https://$DOMAIN:$WEBPORT$WEBPATH"
echo "订阅地址: https://$DOMAIN:$SUBPORT$SUBPATH"
echo "证书路径: $CERT"
echo "私钥路径: $KEY"
echo "数据库备份: $BACKUP"
echo
echo "请确认防火墙已开放面板端口 $WEBPORT 和订阅端口 $SUBPORT。"
echo "如申请新证书，请确保续期调度器正常运行。"
echo "Reality 入站配置未主动修改。"
