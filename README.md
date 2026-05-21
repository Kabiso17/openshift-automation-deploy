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

> mirror-registry 安裝是透過 OpenShift-Automation 的 Ansible role 自動完成的，
> 如果你已經跑過 prep phase，可以跳過這步驟。

手動安裝方式請參考：
```
/root/OpenShift-Automation/scripts/configure_and_run.sh
```

mirror-registry 啟動後預設監聽 `<bastion-ip>:8443`，後續步驟會用到此位址。

---

## 二、建置並推送 Docker Images

### 2.1 取得原始碼

```bash
# Backend repo（含 Ansible playbooks，需 GitHub PAT 因為是 private repo）
git clone https://github.com/Kabiso17/ocp-automation-ui-backend.git
cd ocp-automation-ui-backend

# Frontend repo
git clone https://github.com/Kabiso17/ocp-automation-ui-frontend.git
```

### 2.2 登入 mirror-registry

```bash
# 替換為你的 mirror-registry 位址
REGISTRY=bastion.example.com:8443

podman login ${REGISTRY} \
  --username init \
  --password <your-registry-password>

# 或 docker
docker login ${REGISTRY} \
  --username init \
  --password <your-registry-password>
```

### 2.3 建置 Backend Image

ocp-automation（Ansible playbooks）是 private repo，需要 GitHub Personal Access Token：

```bash
cd ocp-automation-ui-backend

# 產生 GitHub PAT：GitHub → Settings → Developer settings → Personal access tokens
# 權限需要：repo（read）

docker build \
  --build-arg GITHUB_TOKEN=<your-github-pat> \
  -t ${REGISTRY}/ocp-automation/ocp-automation-backend:latest \
  .

docker push ${REGISTRY}/ocp-automation/ocp-automation-backend:latest
```

> **安全提示**：`GITHUB_TOKEN` 作為 build arg 會暫時出現在 image history 中。
> 如果有安全顧慮，可改用 Docker BuildKit secret：
> ```bash
> echo "<your-pat>" | docker build \
>   --secret id=github_token,src=/dev/stdin \
>   -t ${REGISTRY}/ocp-automation/ocp-automation-backend:latest .
> ```
> （需要同步修改 Dockerfile 的 RUN 指令使用 `--mount=type=secret`）

### 2.4 建置 Frontend Image

```bash
cd ocp-automation-ui-frontend

docker build \
  -t ${REGISTRY}/ocp-automation/ocp-automation-frontend:latest \
  .

docker push ${REGISTRY}/ocp-automation/ocp-automation-frontend:latest
```

---

## 三、設定部署環境

### 3.1 Clone 此 repo

```bash
git clone https://github.com/Kabiso17/ocp-automation-deploy.git
cd ocp-automation-deploy
```

### 3.2 建立設定檔

```bash
# 複製設定範本
cp .env.example .env
cp vars/site.yml.example vars/site.yml

# 建立 logs 目錄
mkdir -p logs
```

### 3.3 編輯 `.env`

```bash
vi .env
```

```dotenv
# 填入你的 mirror-registry 位址
REGISTRY=bastion.example.com:8443/ocp-automation

IMAGE_TAG=latest
UI_PORT=80
PULL_SECRET_PATH=/root/pull-secret
```

### 3.4 編輯 `vars/site.yml`

```bash
vi vars/site.yml
```

依照你的叢集環境填入設定，欄位說明請參考：
https://github.com/CCChou/OpenShift-Automation/blob/main/README.md

---

## 四、啟動服務

```bash
# 拉取最新 image
docker compose pull

# 背景啟動
docker compose up -d

# 確認狀態
docker compose ps
```

成功後可在瀏覽器開啟：
```
http://<bastion-ip>:80
```

---

## 五、首次使用

1. 開啟瀏覽器進入 UI
2. 進入 **Config** 頁面，確認/補齊叢集設定
3. 進入 **Tools** 頁面，下載對應 OCP 版本的工具：
   - `oc`
   - `oc-mirror`
   - `openshift-install`
4. 進入 **ImageSet** 頁面設定要 mirror 的 operator
5. 依序執行各 Phase

> **關於 OCP 工具版本**：每個 OCP 版本對應特定版本的 oc-mirror，
> 務必在 Tools 頁面選擇與你的 `ocp_version` 相符的版本。
> 下載後的工具會持久化在 Docker named volume `tools_bin` 中，
> 重新啟動 container 後不需要重新下載。

---

## 六、常用操作

### 更新到新版本

```bash
# 拉取新 image
docker compose pull

# 滾動重啟（不停機）
docker compose up -d
```

### 查看 log

```bash
# backend log
docker compose logs -f backend

# frontend log
docker compose logs -f frontend

# 執行 log（ansible / oc-mirror）
ls logs/
tail -f logs/install.log
```

### 重啟服務

```bash
docker compose restart
```

### 完全停止並清除（保留資料）

```bash
docker compose down
# vars/、logs/ 目錄與 tools_bin volume 都會保留
```

### 清除 OCP 工具（重新安裝不同版本）

```bash
docker compose down
docker volume rm ocp-automation-deploy_tools_bin
docker compose up -d
# 再從 UI Tools 頁面重新下載新版本工具
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
- `vars/site.yml` 不存在 → 確認已從 `vars/site.yml.example` 複製並填入
- pull-secret 路徑不對 → 確認 `.env` 的 `PULL_SECRET_PATH`

### Frontend 顯示 502 Bad Gateway

表示 frontend 已啟動但 backend 還在初始化（啟動時會預熱 operator cache）。
等候 15–30 秒後重新整理即可。

也可以手動確認 backend 健康狀態：
```bash
curl http://localhost:8000/api/health
# 預期回應：{"status":"ok","service":"ocp-automation-api"}
```

### oc-mirror 找不到指令

表示尚未從 UI Tools 頁面下載工具。進入 UI → Tools → 選擇版本 → Download。

### Ansible playbook 找不到 role

確認 backend image 內 `/root/OpenShift-Automation` 存在：
```bash
docker compose exec backend ls /root/OpenShift-Automation/roles
```

若不存在，表示 image build 時 git clone 失敗（可能是網路問題）。
需要重新 build image。

---

## 七、CI/CD 自動化部署

本 repo 包含完整的 GitHub Actions 設定，三個 repo 各自負責：

| Repo | Workflow | 說明 |
|------|---------|------|
| `ocp-automation-backend` | `docker.yml` | Build + push backend image |
| `ocp-automation-frontend` | `docker.yml` | TypeScript check + build + push frontend image |
| `ocp-automation-deploy` | `deploy.yml` | 驗證設定 + 自動部署 |

**觸發規則：**
- `push main` → build + push `:latest` + 自動部署
- `push v*` tag → build + push `:v1.2.3` + `:latest` + 自動部署
- `pull_request` → build 驗證（不 push，不部署）
- 手動觸發（`workflow_dispatch`）→ 可指定 `IMAGE_TAG` 部署特定版本

**設定步驟：** 參考 [`docs/setup-runner.md`](docs/setup-runner.md)

---

## 目錄結構

```
ocp-automation-deploy/
├── docker-compose.yml           # 主要部署設定
├── .env.example                 # 設定範本（填完後複製為 .env）
├── .env                         # 本地設定（不進版控）
├── .gitignore
├── .github/
│   └── workflows/
│       └── deploy.yml           # 自動部署 workflow
├── docs/
│   └── setup-runner.md          # Self-hosted runner 設定指南
├── vars/
│   ├── site.yml.example         # 叢集設定範本
│   └── site.yml                 # 實際設定（不進版控）
└── logs/                        # 執行 log（自動建立，不進版控）
```
