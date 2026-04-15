#!/bin/sh

# ================= 配置 =================
ARGO_DOMAIN="${ARGO_DOMAIN:-}"
ARGO_AUTH="${ARGO_AUTH:-}"
ARGO_PORT="${ARGO_PORT:-8001}"
IPS="${IPS:-4}"
OPERA="${OPERA:-0}"
COUNTRY="${COUNTRY:-AM}"

# ================= 工具 =================
get_free_port() {
    echo $(( ( RANDOM % 20000 ) + 10000 ))
}

# ================= 隧道设置（后台运行）=================
setup_tunnel() {
    echo "--- 清理旧二进制 ---"
    rm -f ech-server-linux opera-linux cloudflared-linux

    echo "--- 下载二进制 ---"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            #ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-amd64"
            ECH_URL="https://github.com/aisijimo666/x-tunnel-smux/releases/download/x-tunnel20260324/x-tunnel-linux-amd64"
            OPERA_URL="https://github.com/Alexey71/opera-proxy/releases/download/v1.16.0/opera-proxy.linux-amd64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        i386|i686)
            #ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-386"
            ECH_URL="https://github.com/aisijimo666/x-tunnel-smux/releases/download/x-tunnel20260324/x-tunnel-linux-386"
            OPERA_URL="https://github.com/Alexey71/opera-proxy/releases/download/v1.16.0/opera-proxy.linux-386"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386"
            ;;
        arm64|aarch64)
            #ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-arm64"
            ECH_URL="https://github.com/aisijimo666/x-tunnel-smux/releases/download/x-tunnel20260324/x-tunnel-linux-arm64"
            OPERA_URL="https://github.com/Alexey71/opera-proxy/releases/download/v1.16.0/opera-proxy.linux-arm64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        *)
            echo "❌ 不支持的架构: $ARCH"
            return 1
            ;;
    esac

    curl -fsSL "$ECH_URL" -o x-tunnel-linux || { echo "❌ 下载 ECH 失败"; return 1; }
    curl -fsSL "$OPERA_URL" -o opera-linux || { echo "❌ 下载 Opera 失败"; return 1; }
    curl -fsSL "$CLOUDFLARED_URL" -o cloudflared-linux || { echo "❌ 下载 Cloudflared 失败"; return 1; }
    chmod +x x-tunnel-linux opera-linux cloudflared-linux

    # ================= 端口 =================
    WSPORT=${WSPORT:-$(get_free_port)}
    ECHPORT=$((WSPORT + 1))
    echo "WS: $WSPORT  ECH: $ECHPORT"

    # ================= Opera =================
    if [ "$OPERA" = "1" ]; then
        COUNTRY=$(echo "$COUNTRY" | tr 'a-z' 'A-Z')
        operaport=$(get_free_port)
        echo "启动 Opera Proxy (port:$operaport, country:$COUNTRY)"
        nohup ./opera-linux -country "$COUNTRY" -socks-mode \
            -bind-address "127.0.0.1:$operaport" >/dev/null 2>&1 &
    fi

    # ================= ECH =================
    sleep 1
    ECH_ARGS="./x-tunnel-linux -l ws://0.0.0.0:$ECHPORT"
    [ -n "$TOKEN" ] && ECH_ARGS="$ECH_ARGS -token $TOKEN"
    [ "$OPERA" = "1" ] && ECH_ARGS="$ECH_ARGS -f socks5://127.0.0.1:$operaport"

    echo "启动 ECH Server..."
    nohup sh -c "$ECH_ARGS" >/dev/null 2>&1 &

    i=0
    while [ $i -lt 15 ]; do
        (bash -c "echo >/dev/tcp/127.0.0.1/$ECHPORT" 2>/dev/null) && break
        sleep 1
        i=$((i+1))
    done

    if [ $i -eq 15 ]; then
        echo "❌ ECH 未监听端口 $ECHPORT"
        return 1
    fi

    # ================= Cloudflared =================
    echo "启动 Cloudflared..."
    CLOUDFLARED_LOG="/tmp/cloudflared.log"

    if [ -n "$ARGO_AUTH" ]; then
        ARGO_AUTH_FILE="/tmp/argo_auth.json"
        echo "$ARGO_AUTH" > "$ARGO_AUTH_FILE"
        chmod 600 "$ARGO_AUTH_FILE"

        # 从凭证 JSON 中提取 TunnelID
        TUNNEL_ID=$(echo "$ARGO_AUTH" | grep -o '"TunnelID":"[^"]*"' | cut -d'"' -f4)
        echo "固定隧道 ID: $TUNNEL_ID"

        # 生成 cloudflared 配置文件（Named Tunnel 模式）
        cat > /tmp/cloudflared-config.yml <<CFEOF
tunnel: $TUNNEL_ID
credentials-file: $ARGO_AUTH_FILE
protocol: http2
metrics: 0.0.0.0:$ARGO_PORT
ingress:
  - service: http://127.0.0.1:$ECHPORT
CFEOF

        nohup ./cloudflared-linux tunnel --config /tmp/cloudflared-config.yml run \
            >"$CLOUDFLARED_LOG" 2>&1 &
    else
        # 未提供凭证，使用临时快速隧道
        nohup ./cloudflared-linux tunnel \
            --url "http://127.0.0.1:$ECHPORT" \
            --metrics "0.0.0.0:$ARGO_PORT" \
            --protocol http2 >"$CLOUDFLARED_LOG" 2>&1 &
    fi

    sleep 3

    # ================= 获取域名 =================
    if [ -n "$ARGO_DOMAIN" ]; then
        TUNNEL_DOMAIN="$ARGO_DOMAIN"
    else
        for i in $(seq 1 30); do
            TUNNEL_DOMAIN=$(curl -s --connect-timeout 2 --max-time 3 \
                "http://127.0.0.1:$ARGO_PORT/metrics" \
                | grep 'userHostname=' \
                | sed -E 's/.*userHostname="([^"]+)".*/\1/')
            [ -n "$TUNNEL_DOMAIN" ] && break
            sleep 1
        done
    fi

    if [ -z "$TUNNEL_DOMAIN" ]; then
        echo "⚠️  获取隧道域名失败，Node.js 服务仍在运行"
        return 0
    fi

    echo "✓ 隧道域名: $TUNNEL_DOMAIN"

    # ================= 写入页面 =================
    cat > ./tunnel_index.html <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>Tunnel Ready</title>
</head>
<body style="background:#020617;color:#e5e7eb;display:flex;align-items:center;justify-content:center;height:100vh">
<div>
<h1>🚀 Tunnel 已就绪</h1>
<p>$TUNNEL_DOMAIN</p>
</div>
</body>
</html>
EOF
}

# ================= main =================
# 清除旧的隧道页面，避免显示过期域名
rm -f ./tunnel_index.html

# 后台运行隧道设置
setup_tunnel &

# 立即启动 Node.js（保证健康检查通过）
echo "--- 启动 Node.js 服务器 ---"
exec node server.js
