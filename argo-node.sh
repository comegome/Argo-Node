#!/usr/bin/env bash
# argo-node — 单机 + Cloudflare Argo 隧道，把本机变成一个出口节点
#
# 交互式，无子命令。运行一次，脚本自己判断该装、该查还是该卸。
# 只写这四个路径：/usr/local/bin/argo-node、/etc/argo-node/、sing-box 配置、systemd unit
# 不开放任何公网端口，入口只在 127.0.0.1。

set -u

STATE_DIR=/etc/argo-node
NODE_JSON=$STATE_DIR/node.json
TOKEN_ENV=$STATE_DIR/tunnel.env
BACKUP_DIR=$STATE_DIR/backup
SB_CONF=/etc/sing-box/config.json
SB_TAG=argo-ws
CF_SVC=cloudflared-argo
CF_UNIT=/etc/systemd/system/$CF_SVC.service
PORT_BASE=${ARGO_PORT:-2080}

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf '   ✗ %s\n' "$*"; }
ok()   { printf '   ✓ %s\n' "$*"; }
die()  { printf '\n错误：%s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "需要 root 运行"; }

preflight() {
  step "环境检查"
  . /etc/os-release 2>/dev/null || true
  ok "${PRETTY_NAME:-unknown} $(uname -m)"
  command -v curl    >/dev/null || die "缺少 curl"
  command -v python3 >/dev/null || die "缺少 python3（改 sing-box 配置要用）"
  ok "curl / python3 就绪"
}

arch_tag() {
  case "$(uname -m)" in
    x86_64)  echo amd64 ;;
    aarch64) echo arm64 ;;
    *) die "不支持的架构 $(uname -m)" ;;
  esac
}

# ---------- 依赖 ----------

install_cloudflared() {
  if command -v cloudflared >/dev/null; then
    ok "cloudflared $(cloudflared --version 2>/dev/null | awk '{print $3}') 已安装"
    return
  fi
  local a; a=$(arch_tag)
  curl -fsSL -o /tmp/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$a" \
    || die "下载 cloudflared 失败"
  install -m 755 /tmp/cloudflared /usr/local/bin/cloudflared && rm -f /tmp/cloudflared
  ok "cloudflared $(cloudflared --version | awk '{print $3}') 已安装"
}

ensure_singbox() {
  if command -v sing-box >/dev/null; then
    ok "sing-box $(sing-box version | head -1 | awk '{print $3}') 已安装"
    SB_MANAGED=false
    return
  fi
  local a ver; a=$(arch_tag)
  ver=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"].lstrip("v"))') \
        || die "查询 sing-box 版本失败"
  curl -fsSL -o /tmp/sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v$ver/sing-box-$ver-linux-$a.tar.gz" \
    || die "下载 sing-box 失败"
  tar xzf /tmp/sb.tar.gz -C /tmp && install -m 755 "/tmp/sing-box-$ver-linux-$a/sing-box" /usr/local/bin/sing-box
  rm -rf /tmp/sb.tar.gz "/tmp/sing-box-$ver-linux-$a"
  mkdir -p /etc/sing-box
  [ -f "$SB_CONF" ] || printf '%s\n' '{"log":{"level":"warn"},"inbounds":[],"outbounds":[{"type":"direct"}]}' > "$SB_CONF"
  cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now sing-box >/dev/null 2>&1
  SB_MANAGED=true
  ok "sing-box $ver 已安装并启动"
}

# ---------- 配置 ----------

pick_port() {
  local p
  for p in $(seq "$PORT_BASE" $((PORT_BASE + 20))); do
    if ! ss -lnt 2>/dev/null | grep -q ":$p "; then echo "$p"; return; fi
    # 占用者是 sing-box 就复用（多半是我们上次装的那条 inbound）
    if ss -lntp 2>/dev/null | grep ":$p " | grep -q "sing-box"; then echo "$p"; return; fi
  done
  die "端口 ${PORT_BASE}-$((PORT_BASE + 20)) 都不可用"
}

apply_inbound() {
  python3 - "$SB_CONF" "$SB_TAG" "$PORT" "$UUID" "$WSPATH" <<'PY'
import json, sys
conf, tag, port, uuid, path = sys.argv[1:6]
d = json.load(open(conf))
d.setdefault("inbounds", [])
d["inbounds"] = [i for i in d["inbounds"] if i.get("tag") != tag]
d["inbounds"].append({
    "type": "vless", "tag": tag, "listen": "127.0.0.1", "listen_port": int(port),
    "users": [{"uuid": uuid}],
    "transport": {"type": "ws", "path": path},
})
json.dump(d, open(conf, "w"), indent=2, ensure_ascii=False)
PY
}

remove_inbound() {
  [ -f "$SB_CONF" ] || return 0
  python3 - "$SB_CONF" "$SB_TAG" <<'PY'
import json, sys
conf, tag = sys.argv[1:3]
d = json.load(open(conf))
before = len(d.get("inbounds", []))
d["inbounds"] = [i for i in d.get("inbounds", []) if i.get("tag") != tag]
json.dump(d, open(conf, "w"), indent=2, ensure_ascii=False)
print("removed" if len(d["inbounds"]) != before else "absent")
PY
}

load_node() {
  eval "$(python3 - "$NODE_JSON" <<'PY'
import json, sys
from shlex import quote
d = json.load(open(sys.argv[1]))
for k in ("host", "port", "uuid", "path"):
    print("%s=%s" % (k.upper() if k != "path" else "WSPATH", quote(str(d[k]))))
print("SB_MANAGED=%s" % quote(str(d.get("sing_box_managed", False)).lower()))
PY
)"
}

save_node() {
  mkdir -p "$STATE_DIR"
  python3 - "$NODE_JSON" "$HOST" "$PORT" "$UUID" "$WSPATH" "$SB_MANAGED" <<'PY'
import json, sys, time
conf, host, port, uuid, path, managed = sys.argv[1:7]
json.dump({"host": host, "port": int(port), "uuid": uuid, "path": path,
           "sing_box_managed": managed == "true", "created": time.strftime("%F %T")},
          open(conf, "w"), indent=2)
PY
  chmod 600 "$NODE_JSON"
}

# ---------- 隧道服务 ----------

setup_service() {
  printf 'TUNNEL_TOKEN=%s\n' "$TOKEN" > "$TOKEN_ENV"
  chmod 600 "$TOKEN_ENV"
  cat > "$CF_UNIT" <<EOF
[Unit]
Description=Cloudflare Tunnel ($HOST)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
EnvironmentFile=$TOKEN_ENV
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$CF_SVC" >/dev/null 2>&1
}

# 从粘贴内容里取令牌：直接粘令牌、cloudflared service install ...、docker run ... --token ... 都认
extract_token() {
  local raw t
  raw=${1//\"/}
  raw=${raw//\'/}
  t=$(printf '%s' "$raw" | grep -oE '[A-Za-z0-9_=-]{40,}' | head -1)
  printf '%s' "${t:-$raw}"
}

# ---------- 校验 ----------

check_tunnel() {
  if ! systemctl is-active --quiet "$CF_SVC"; then
    if journalctl -u "$CF_SVC" --no-pager -n 100 2>/dev/null \
       | grep -qiE "Provided Tunnel token is not valid|Invalid tunnel secret"; then
      warn "tunnel token 无效（cloudflared 直接拒绝了它）"
      TOKEN_BAD=1
    else
      warn "隧道服务未运行"
    fi
    return 1
  fi
  local since lines n
  since=$(systemctl show -p ActiveEnterTimestamp --value "$CF_SVC" 2>/dev/null)
  if [ -n "$since" ]; then
    lines=$(journalctl -u "$CF_SVC" --since "$since" --no-pager 2>/dev/null | grep "Registered tunnel connection")
  else
    lines=$(journalctl -u "$CF_SVC" --no-pager -n 200 2>/dev/null | grep "Registered tunnel connection")
  fi
  [ -n "$lines" ] || { warn "隧道进程在跑，但没有注册到任何边缘（token 多半无效）"; return 1; }
  n=$(printf '%s\n' "$lines" | grep -o 'connIndex=[0-9]*' | sort -u | wc -l | tr -d ' ')
  ok "隧道已连接（$n 条边缘连接）"
}

resolve_ips() {
  if command -v dig >/dev/null 2>&1; then
    dig +short +time=3 +tries=1 A "$HOST" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u
  else
    getent ahostsv4 "$HOST" 2>/dev/null | awk '{print $1}' | sort -u
  fi
}

check_dns() {
  local ips; ips=$(resolve_ips)
  [ -n "$ips" ] || { warn "域名 $HOST 解析不到"; return 1; }
  local tmp verdict
  tmp=$(mktemp)
  curl -fsSL -m 5 https://www.cloudflare.com/ips-v4 -o "$tmp" 2>/dev/null || true
  verdict=$(python3 - "$tmp" $ips <<'PY'
import sys, ipaddress
try:
    nets = [ipaddress.ip_network(l.strip()) for l in open(sys.argv[1]) if l.strip() and not l.startswith('#')]
except Exception:
    print("unknown"); raise SystemExit
hit = [ip for ip in sys.argv[2:] if any(ipaddress.ip_address(ip) in n for n in nets)]
print("cf" if hit else "notcf")
PY
)
  rm -f "$tmp"
  if [ "$verdict" != "cf" ]; then
    warn "解析到 $(echo "$ips" | tr '\n' ',' | sed 's/,$//')，不是 Cloudflare 的 IP"
    say "       （zone 里多半有泛解析 *，要加 Public Hostname 才会生成指向隧道的 CNAME）"
    return 1
  fi
  ok "域名已指向 Cloudflare 边缘（$(echo "$ips" | tr '\n' ',' | sed 's/,$//')）"
}

check_ws() {
  local code
  local rflag=""
  local ip; ip=$(resolve_ips | head -1)
  [ -n "$ip" ] && rflag="--resolve $HOST:443:$ip"
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' $rflag \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H "Sec-WebSocket-Key: $(head -c 16 /dev/urandom | base64)" \
    "https://$HOST$WSPATH" 2>/dev/null)
  case "$code" in
    101|400) ok "ws 握手到达本机（HTTP $code）"; return 0 ;;
    404) warn "路径没对上（HTTP 404）——面板里的 Path 或本地 path 不一致"; return 1 ;;
    502|503) warn "边缘连不上本机（HTTP $code）——面板端口应填 127.0.0.1:$PORT"; return 1 ;;
    1033) warn "隧道没有活跃连接（HTTP 1033）"; return 1 ;;
    000|"")
      warn "连不上 $HOST:443"
      say "       DNS 已指向 CF，但边缘没有这条隧道的路由"
      say "       常见原因：DNS 里加的是 A 记录，而不是在隧道页面加 Public Hostname"
      return 1 ;;
    *) warn "意外的响应（HTTP $code）"; return 1 ;;
  esac
}

dashboard_hint() {
  say ""
  say "   面板里加一条 Public Hostname："
  say "     域名    $HOST"
  say "     类型    HTTP"
  say "     地址    127.0.0.1:$PORT"
  say "     Path    留空"
}

do_check() {
  TOKEN_BAD=0
  step "校验"
  if ! check_tunnel; then
    say ""
    if [ "${TOKEN_BAD:-0}" = "1" ]; then
      say "下一步：回 CF 面板重新复制 token，重跑脚本选 r（会重新生成 uuid 和 path）。"
    else
      say "下一步：journalctl -u $CF_SVC -n 30 看原因；确认无误后重跑脚本选 r。"
    fi
    return 1
  fi
  if ! check_dns; then dashboard_hint; say ""; say "加完重跑脚本。"; return 1; fi
  if ! check_ws;  then dashboard_hint; say ""; say "对照上面的值改面板，改完重跑脚本。"; return 1; fi
  return 0
}

print_client() {
  step "客户端配置（ClashX Meta / mihomo）"
  cat <<EOF

proxies:
  - name: ${HOST%%.*}
    type: vless
    server: $HOST
    port: 443
    uuid: $UUID
    network: ws
    tls: true
    udp: true
    servername: $HOST
    client-fingerprint: chrome
    ws-opts:
      path: $WSPATH
      headers:
        Host: $HOST

EOF
}

# ---------- 卸载 ----------

do_uninstall() {
  step "卸载"
  if systemctl list-unit-files 2>/dev/null | grep -q "^$CF_SVC.service"; then
    systemctl disable --now "$CF_SVC" >/dev/null 2>&1
    rm -f "$CF_UNIT"
    systemctl daemon-reload
    ok "隧道服务已停止并删除"
  fi
  if [ -f "$SB_CONF" ] && command -v sing-box >/dev/null; then
    local r; r=$(remove_inbound)
    if [ "$r" = "removed" ]; then
      if sing-box check -c "$SB_CONF" >/dev/null 2>&1; then
        systemctl restart sing-box >/dev/null 2>&1 && ok "sing-box inbound 已移除并重载"
      else
        warn "移除后配置校验失败，未重载 sing-box（原配置未改动前已备份）"
      fi
    else
      ok "sing-box 里没有 $SB_TAG，跳过"
    fi
  fi
  rm -rf "$STATE_DIR"
  ok "本地状态已清除"
  say ""
  say "还需要你在 CF 控制台手动删除："
  say "  1. Tunnels → 删除包含 ${HOST:-该域名} 的隧道"
  say "  2. DNS → 删除 ${HOST:-该域名} 的 CNAME 记录"
}

# ---------- 安装 ----------

guide_tunnel() {
  step "创建隧道"
  say "   1. 在 Cloudflare → Tunnels 创建一条隧道"
  say "   2. 保存后复制页面上那段令牌"
}

install_flow() {
  preflight

  step "安装依赖"
  say "   cloudflared（约 40MB）+ sing-box（若未安装）"
  printf '   继续？[Y/n] '
  read -r ans
  case "${ans:-Y}" in [Yy]*) ;; *) die "已取消" ;; esac
  install_cloudflared
  ensure_singbox

  guide_tunnel
  say ""
  printf 'Tunnel token（粘贴后回车，输入不回显）: '
  read -rs TOKEN
  say ""
  [ -n "${TOKEN:-}" ] || die "token 不能为空"
  RAW=$TOKEN
  TOKEN=$(extract_token "$RAW")
  [ "$TOKEN" != "$RAW" ] && ok "已从粘贴内容中提取令牌"
  [ ${#TOKEN} -ge 40 ] || die "这段内容不像隧道令牌（只有 ${#TOKEN} 个字符）"
  ok "已读取令牌：${#TOKEN} 字符，末 4 位 ${TOKEN: -4}"

  PORT=$(pick_port)
  UUID=$(python3 -c 'import uuid;print(uuid.uuid4())')
  WSPATH="/$(python3 -c 'import secrets;print(secrets.token_hex(8))')"

  step "写入本地入口"
  mkdir -p "$BACKUP_DIR"
  cp -a "$SB_CONF" "$BACKUP_DIR/config.json.$(date +%Y%m%d_%H%M%S)"
  apply_inbound
  if sing-box check -c "$SB_CONF" >/dev/null 2>&1; then
    systemctl restart sing-box >/dev/null 2>&1
    ok "inbound $SB_TAG 已加入（只监听 127.0.0.1）"
  else
    cp -a "$(ls -t "$BACKUP_DIR"/config.json.* | head -1)" "$SB_CONF"
    die "配置校验失败，已还原，未做任何改动"
  fi

  step "去 CF 面板给这条隧道添加路由"
  say "   服务地址  http://127.0.0.1:$PORT"
  say "   Path      留空"
  say ""
  printf '公共主机域名: '
  read -r HOST
  [ -n "${HOST:-}" ] || die "域名不能为空"

  save_node
  step "启动隧道"
  setup_service
  sleep 3

  if do_check; then
    say ""
    say "== 全部就绪"
    print_client
  else
    say ""
    say "== 本地已装好，但还没打通。"
    say "   完成上面提示的那一步后，重跑本脚本即可复查。"
    say "   要重来：重跑脚本选 r。"
  fi
}

main() {
  need_root
  if [ -f "$NODE_JSON" ]; then
    load_node
    step "检测到已安装"
    say "   $HOST → 127.0.0.1:$PORT"
    printf '   [c] 检查  [r] 卸载重装  [u] 只卸载   (默认 c): '
    read -r ans
    case "${ans:-c}" in
      [Cc]) do_check && print_client; exit 0 ;;
      [Uu]) do_uninstall; exit 0 ;;
      [Rr]) do_uninstall ;;
      *) die "无效输入" ;;
    esac
  fi
  install_flow
}

main "$@"
