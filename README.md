# 這是專案的說明文件，包含了完整的配置指南。

# ⚡ ECH Tunnel + Cloudflare Argo Quick Tunnel Docker 專案

這個專案將 **ech-server**、**Opera Proxy**（可選）和 **Cloudflare Argo Quick Tunnel** 整合到一個輕量級的 Docker 容器中，用於快速建立一個臨時的 WSS/ECH 連線通道。

---

## 🚀 快速開始

### 2.透過設定環境變數 (-e) 來客製化服務的運行方式。
隧道项目启动run command
sh start.sh

環境變數	預設值	說明	可選值
在：
Config files
.replit  增加变量：
[userenv]

[userenv.shared]
WSPORT = "7860"
