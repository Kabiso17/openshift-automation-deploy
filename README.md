# OCP Automation UI — 部署指南

透過兩個 Docker container 啟動 OCP Automation UI，所有操作只需一支 `docker compose` 指令。

```
使用者瀏覽器
    ↓ :80
[frontend: nginx]
    ├── /api/* → proxy → [backend: FastAPI :8000]
    └── /*     → React SPA
```

---

## 前置需求

| 項目 | 版本需求 | 說明 |
|------|---------|------|
| Docker Engine | 24.0+ | 或 Podman 4.0+ |
| Docker Compose | v2.0+ | `docker compose`（非 `docker-compose`）|
| mirror-registry | 最新版 | 見下方安裝步驟 |
| Pull Secret | — | 從 [Red Hat Console](https://console.redhat.com/openshift/install/pull-secret) 下載 |

---

## 一、安裝 mirror-registry

使用 `scripts/install-mirror-registry.sh` 自動完成下載、安裝、CA 憑證信任：

```bash
# Clone 此 repo
git clone https://github.com/Kabiso17/openshift-automation-deploy.git
cd openshift-automation-deploy

# 執行安裝腳本（以 root 執行，INIT_PASSWORD 自訂）
INIT_PASSWORD=<自訂密碼> bash scripts/install-mirror-registry.sh
```

安裝完成後腳本會輸出 GitHub Secrets 所需的值：

```
REGISTRY_HOST     = <bastion-hostname>:8443
REGISTRY_USERNAME = init
REGISTRY_PASSWORD = <你設定的密碼>
```

> **可選參數：**
> ```bash
> QUAY_ROOT=/mirror-registry \   # 資料目錄（預設）
> QUAY_PORT=8443 \               # 監聽 port（預設）
> INIT_PASSWORD=<密碼> \
> bash scripts/install-mirror-registry.sh
> ```

---

## 二、設定 GitHub Secrets 與 Runner

參考 [`docs/setup-runner.md`](docs/setup-runner.md)，依序完成：

1. 在 GitHub 設定三個 Secrets（`REGISTRY_HOST`、`REGISTRY_USERNAME`、`REGISTRY_PASSWORD`）
2. 在 bastion 安裝 self-hosted runner
3. 將 runner 設為系統服務

---

## 三、建置並推送 Docker Images

GitHub Actions workflow 會在 push 到 `main` 時自動 build 並 push image。
第一次需要手動觸發（或 push 一個 commit）：

```bash
# 以 backend repo 為例
git clone https://github.com/Kabiso17/ocp-automation-backend.git
cd ocp-automation-backend
git commit --allow-empty -m "ci: trigger first build"
git push
```

Frontend repo 同上。

確認 GitHub Actions 頁面 workflow 執行成功，image 已 push 到 mirror-registry。

---

## 四、設定並啟動服務

```bash
cd openshift-automation-deploy

# 複製設定範本
cp .env.example .env
cp vars/site.yml.example vars/site.yml

# 建立 logs 目錄
mkdir -p logs
```

編輯 `.env`：

```bash
vi .env
```

```dotenv
REGISTRY=<bastion-hostname>:8443/ocp-automation
IMAGE_TAG=latest
UI_PORT=80
PULL_SECRET_PATH=/root/pull-secret
```

編輯 `vars/site.yml`（依叢集環境填入，欄位說明參考 [OpenShift-Automation README](https://github.com/CCChou/OpenShift-Automation/blob/main/README.md)）：

```bash
vi vars/site.yml
```

啟動服務：

```bash
docker compose pull
docker compose up -d
docker compose ps
```

成功後開啟瀏覽器：`http://<bastion-ip>`

---

## 五、首次使用

1. 進入 **Config** 頁面，確認/補齊叢集設定
2. 進入 **Tools** 頁面，下載對應 OCP 版本的工具（`oc`、`oc-mirror`、`openshift-install`）
3. 進入 **ImageSet** 頁面設定要 mirror 的 operator
4. 依序執行各 Phase

> 下載的工具持久化在 Docker named volume `tools_bin`，重啟 container 後不需要重新下載。

---

## 六、常用操作

### 更新到新版本

```bash
docker compose pull
docker compose up -d
```

### 查看 log

```bash
docker compose logs -f backend
tail -f logs/install.log
```

### 重啟 / 停止

```bash
docker compose restart
docker compose down   # vars/、logs/、tools_bin volume 都保留
```

### 清除 OCP 工具（換版本時）

```bash
docker compose down
docker volume rm openshift-automation-deploy_tools_bin
docker compose up -d
# 再從 UI Tools 頁面重新下載新版本
```

### 備份設定

```bash
cp vars/site.yml vars/site.yml.backup.$(date +%Y%m%d)
```

---

## 疑難排解

### Backend 啟動失敗

```bash
docker compose logs backend
```

常見原因：
- `vars/site.yml` 不存在 → 從 `vars/site.yml.example` 複製並填入
- pull-secret 路徑不對 → 確認 `.env` 的 `PULL_SECRET_PATH`

### Frontend 顯示 502 Bad Gateway

backend 仍在初始化（預熱 operator cache 需要 15–30 秒），重新整理即可。
也可手動確認：

```bash
curl http://localhost:8000/api/health
# 預期：{"status":"ok","service":"ocp-automation-api"}
```

### oc-mirror 找不到指令

進入 UI → Tools → 選擇版本 → Download。

### Ansible playbook 找不到 role

```bash
docker compose exec backend ls /root/OpenShift-Automation/roles
```

若不存在，表示 image build 時 git clone 失敗，需要重新 build image。

---

## 七、CI/CD 自動化部署

| Repo | Workflow | 觸發 |
|------|---------|------|
| `ocp-automation-backend` | `docker.yml` | push main / tag → build + push image |
| `ocp-automation-frontend` | `docker.yml` | push main / tag → tsc check + build + push image |
| `openshift-automation-deploy` | `deploy.yml` | push main → docker compose pull + up |

手動部署指定版本：

```
GitHub → openshift-automation-deploy → Actions → Deploy → Run workflow → 填入 image_tag
```

設定步驟：參考 [`docs/setup-runner.md`](docs/setup-runner.md)

---

## 目錄結構

```
openshift-automation-deploy/
├── docker-compose.yml           # 主要部署設定
├── .env.example                 # 設定範本（填完後複製為 .env）
├── .env                         # 本地設定（不進版控）
├── .gitignore
├── .github/
│   └── workflows/
│       └── deploy.yml           # 自動部署 workflow
├── scripts/
│   └── install-mirror-registry.sh  # mirror-registry 自動安裝腳本
├── docs/
│   └── setup-runner.md          # Self-hosted runner 設定指南
├── vars/
│   ├── site.yml.example         # 叢集設定範本
│   └── site.yml                 # 實際設定（不進版控）
└── logs/                        # 執行 log（自動建立，不進版控）
```
