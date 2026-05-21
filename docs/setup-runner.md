# Self-hosted GitHub Actions Runner 設定指南

GitHub Actions 的 self-hosted runner 必須跑在 **bastion 主機**上，
才能直接存取 mirror-registry（`<bastion>:8443`）。

---

## 一、在 GitHub 建立 Runner

三個 repo 各自需要一個 runner，或是在 **Organization 層級**設定一個共用的 runner。

### 推薦：Organization-level Runner（三個 repo 共用）

1. 進入 GitHub Organization → **Settings** → **Actions** → **Runners**
2. 點擊 **New self-hosted runner**
3. 選擇 **Linux / x64**
4. 複製頁面上顯示的安裝指令（每次產生的 token 不同，需即時複製）

### 備選：Repo-level Runner（各 repo 獨立）

進入各 repo → **Settings** → **Actions** → **Runners** → **New self-hosted runner**

---

## 二、在 Bastion 安裝 Runner

以下在 bastion 主機上以 **root** 執行（或有 sudo 權限的帳號）：

```bash
# 建立專用目錄與使用者（建議用非 root 帳號跑 runner）
useradd -m -s /bin/bash github-runner
su - github-runner

mkdir -p ~/actions-runner && cd ~/actions-runner

# 下載 runner（版本號請從 GitHub 頁面複製最新版）
curl -o actions-runner-linux-x64-2.319.1.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.319.1/actions-runner-linux-x64-2.319.1.tar.gz

tar xzf ./actions-runner-linux-x64-2.319.1.tar.gz

# 設定 runner（貼上從 GitHub 頁面複製的指令，包含 --token）
# 範例（token 每次不同，請用 GitHub 頁面上的）：
./config.sh \
  --url https://github.com/<your-org-or-user> \
  --token <TOKEN_FROM_GITHUB> \
  --name bastion-runner \
  --labels "self-hosted,bastion,linux" \
  --runnergroup Default \
  --work _work
```

---

## 三、信任 mirror-registry 的 Self-signed Certificate

mirror-registry 使用自簽憑證，Docker daemon 預設拒絕連線。需要一次性設定：

```bash
# 切回 root
exit   # 離開 github-runner

# 找到 mirror-registry 的 CA 憑證（路徑依安裝時設定而定）
# 通常在以下位置之一：
ls /etc/quay-install/quay-rootCA/rootCA.pem
ls /mirror-registry/quay-rootCA/rootCA.pem

# 設定 Docker 信任該 CA（替換 <bastion-host> 為實際 hostname 或 IP）
REGISTRY_HOST="<bastion-host>:8443"
mkdir -p /etc/docker/certs.d/${REGISTRY_HOST}
cp /etc/quay-install/quay-rootCA/rootCA.pem \
   /etc/docker/certs.d/${REGISTRY_HOST}/ca.crt

# 重啟 Docker
systemctl restart docker

# 驗證可以登入
docker login ${REGISTRY_HOST} \
  --username init \
  --password <your-registry-password>
```

---

## 四、允許 Runner 使用 Docker

runner 的執行帳號（`github-runner`）需要有 Docker 權限：

```bash
# 將 runner 帳號加入 docker group
usermod -aG docker github-runner

# 驗證（切換到 github-runner 再測試）
su - github-runner
docker ps   # 應該可以執行
```

---

## 五、設定為系統服務（開機自動啟動）

```bash
su - github-runner
cd ~/actions-runner

# 安裝服務
sudo ./svc.sh install github-runner

# 啟動
sudo ./svc.sh start

# 確認狀態
sudo ./svc.sh status
```

---

## 六、設定 GitHub Secrets

在 GitHub 各 repo 或 Organization 層級設定以下 Secrets：

### 三個 repo 共用（建議設在 Organization）

| Secret 名稱 | 說明 | 範例值 |
|---|---|---|
| `REGISTRY_HOST` | mirror-registry 位址 | `bastion.example.com:8443` |
| `REGISTRY_USERNAME` | 登入帳號 | `init` |
| `REGISTRY_PASSWORD` | 登入密碼 | `P@ssw0rd` |

---

## 七、驗證 Runner 運作正常

設定完成後，推一個空 commit 到 main 觸發 workflow：

```bash
git commit --allow-empty -m "ci: trigger runner test"
git push origin main
```

在 GitHub repo 的 **Actions** 頁面確認 workflow 跑在 `bastion-runner`（而不是 `ubuntu-latest`）。

---

## 疑難排解

### Runner 無法連線到 GitHub

bastion 必須能連到 `github.com`：
```bash
curl -I https://github.com
```

若在完全離線環境，需要設定 HTTPS proxy：
```bash
export HTTPS_PROXY=http://proxy.example.com:3128
./config.sh ...
```

### Docker login 失敗（certificate verify failed）

重新確認 CA 憑證設定：
```bash
ls /etc/docker/certs.d/<bastion-host>:8443/ca.crt
openssl verify -CAfile /etc/docker/certs.d/<bastion-host>:8443/ca.crt \
  /etc/docker/certs.d/<bastion-host>:8443/ca.crt
```

### Build 失敗：secret not found

確認 `GIT_CLONE_PAT` Secret 有設定在正確的 repo，且 workflow 中 `secrets.GIT_CLONE_PAT` 拼寫正確。
