#!/bin/bash
# ============================================================
# install-mirror-registry.sh
# 自動下載並安裝 Red Hat mirror-registry 到 bastion
#
# 使用方式：
#   INIT_PASSWORD=<自訂密碼> bash install-mirror-registry.sh
#
# 可選環境變數：
#   QUAY_ROOT      mirror-registry 資料目錄（預設 /mirror-registry）
#   QUAY_PORT      監聽 port（預設 8443）
#   WORK_DIR       安裝暫存目錄（預設 /root/mirror-registry-install）
# ============================================================
set -e

GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
step() { echo -e "${BLUE}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── 參數 ──
QUAY_ROOT="${QUAY_ROOT:-/mirror-registry}"
QUAY_PORT="${QUAY_PORT:-8443}"
WORK_DIR="${WORK_DIR:-/root/mirror-registry-install}"
DOWNLOAD_URL="https://mirror.openshift.com/pub/cgw/mirror-registry/latest/mirror-registry-amd64.tar.gz"

# ── 前置檢查 ──
[ "$(id -u)" = "0" ] || err "請以 root 執行此腳本"
[ -n "$INIT_PASSWORD" ]  || err "未設定 INIT_PASSWORD，請執行：INIT_PASSWORD=<密碼> bash $0"

HOSTNAME_FQDN=$(hostname -f)
REGISTRY_HOST="${HOSTNAME_FQDN}:${QUAY_PORT}"

echo ""
echo "============================================"
echo "  mirror-registry 安裝"
echo "  目標：${REGISTRY_HOST}"
echo "  資料目錄：${QUAY_ROOT}"
echo "============================================"
echo ""

# ── Step 1: 下載 ──
step "下載 mirror-registry..."
mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

if [ -f mirror-registry-amd64.tar.gz ]; then
    # 確認不是錯誤的 HTML 頁面
    if file mirror-registry-amd64.tar.gz | grep -q "gzip"; then
        log "已存在有效的安裝檔，跳過下載"
    else
        warn "現有檔案格式不正確，重新下載..."
        rm -f mirror-registry-amd64.tar.gz
        curl -L -O "$DOWNLOAD_URL"
    fi
else
    curl -L -O "$DOWNLOAD_URL"
fi

file mirror-registry-amd64.tar.gz | grep -q "gzip" || \
    err "下載失敗（檔案格式不正確）。請手動下載：\n  $DOWNLOAD_URL"

# ── Step 2: 解壓縮 ──
step "解壓縮..."
tar xzf mirror-registry-amd64.tar.gz
log "解壓縮完成"

# ── Step 3: 安裝 ──
step "安裝 mirror-registry（需要幾分鐘）..."
./mirror-registry install \
    --quayHostname "${REGISTRY_HOST}" \
    --quayRoot     "${QUAY_ROOT}" \
    --initPassword "${INIT_PASSWORD}"
log "安裝完成"

# ── Step 4: 信任 CA 憑證 ──
step "設定 CA 憑證信任..."
CA_CERT="${QUAY_ROOT}/quay-rootCA/rootCA.pem"
[ -f "$CA_CERT" ] || err "CA 憑證不存在：${CA_CERT}"

# 系統層級
cp "$CA_CERT" /etc/pki/ca-trust/source/anchors/mirror-registry-ca.pem
update-ca-trust extract

# Docker 層級（供 GitHub Actions runner 用）
mkdir -p "/etc/docker/certs.d/${REGISTRY_HOST}"
cp "$CA_CERT" "/etc/docker/certs.d/${REGISTRY_HOST}/ca.crt"

# Docker 重啟
if systemctl is-active --quiet docker 2>/dev/null; then
    systemctl restart docker
    log "Docker daemon 已重啟"
fi

log "CA 憑證設定完成"

# ── Step 5: 驗證 ──
step "等待服務就緒..."
for i in $(seq 1 12); do
    if curl -sf "https://${REGISTRY_HOST}/health" > /dev/null 2>&1; then
        log "mirror-registry 健康檢查通過"
        break
    fi
    echo "  等待中... ($i/12)"
    sleep 5
    [ "$i" = "12" ] && warn "健康檢查超時，服務可能仍在啟動，請稍後手動確認"
done

step "測試登入..."
podman login "${REGISTRY_HOST}" \
    --username init \
    --password "${INIT_PASSWORD}" \
    --tls-verify=true && log "登入成功"

# ── 完成 ──
echo ""
echo "============================================"
log "mirror-registry 安裝完成！"
echo ""
echo "  Registry 位址 ：${REGISTRY_HOST}"
echo "  帳號           ：init"
echo "  CA 憑證         ：${CA_CERT}"
echo ""
echo "  請將以下值填入 GitHub Secrets："
echo "    REGISTRY_HOST     = ${REGISTRY_HOST}"
echo "    REGISTRY_USERNAME = init"
echo "    REGISTRY_PASSWORD = ${INIT_PASSWORD}"
echo "============================================"
echo ""
