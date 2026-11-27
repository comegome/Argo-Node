#!/usr/bin/env bash
# argo-node — 单机 + Cloudflare Argo 隧道，把本机变成一个出口节点
#
# 交互式，无子命令。运行一次，脚本自己判断该装、该查还是该卸。
# 落盘：/etc/argo-node/（自己的 sing-box 配置 + 状态）、两个 systemd unit
# 不共用 /etc/sing-box/config.json，与 Simple-Box 之类的 sing-box 管理脚本互不干扰。
# 不开放任何公网端口，入口只在 127.0.0.1。

set -u

STATE_DIR=/etc/argo-node
NODE_JSON=$STATE_DIR/node.json
TOKEN_ENV=$STATE_DIR/tunnel.env
BACKUP_DIR=$STATE_DIR/backup
SB_CONF=$STATE_DIR/sing-box.json
SB_SVC=sing-box-argo
SB_UNIT=/etc/systemd/system/$SB_SVC.service
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
  command -v ss      >/dev/null || warn "缺少 ss（iproute2）：端口占用只能靠 bind 探测，中断重跑可能换端口"
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
    ok "cloudflared $(cloudflared --version 2>/dev/null | awk '{print $3}') 已安装（$(command -v cloudflared)）"
    return
  fi
  local a tmp; a=$(arch_tag)
  tmp=$(mktemp -d) || die "建临时目录失败"
  curl -fsSL -o "$tmp/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$a" \
    || { rm -rf "$tmp"; die "下载 cloudflared 失败"; }
  install -m 755 "$tmp/cloudflared" /usr/local/bin/cloudflared || { rm -rf "$tmp"; die "安装 cloudflared 失败"; }
  rm -rf "$tmp"
  ok "cloudflared $(cloudflared --version | awk '{print $3}') 已安装"
}

migrate_legacy_inbound() {
  # 旧版本把 argo-ws 追加进 /etc/sing-box/config.json。这里把它搬进自己的文件，
  # 并从共享配置里摘掉，避免两个实例抢同一个端口。
  local legacy=/etc/sing-box/config.json
  [ -f "$legacy" ] || return 0
  [ -f "$SB_CONF" ] && return 0
  install -d -m 700 "$STATE_DIR"
  local r
  r=$(python3 - "$legacy" "$SB_CONF" "$SB_TAG" <<'PY'
import json, sys
legacy, new, tag = sys.argv[1:4]
try:
    d = json.load(open(legacy))
except Exception:
    sys.exit(1)
inb = [i for i in d.get("inbounds", []) if i.get("tag") == tag]
if not inb:
    sys.exit(1)
json.dump({"log": d.get("log", {"level": "warn"}), "inbounds": inb,
           "outbounds": [{"type": "direct"}]},
          open(new, "w"), indent=2, ensure_ascii=False)
d["inbounds"] = [i for i in d.get("inbounds", []) if i.get("tag") != tag]
json.dump(d, open(legacy, "w"), indent=2, ensure_ascii=False)
print("migrated")
PY
) || return 0
  if [ "$r" = "migrated" ]; then
    chmod 600 "$SB_CONF"
    # 共享配置若还有服务在跑，重启它释放端口
    if systemctl list-unit-files 2>/dev/null | grep -q "^sing-box.service"; then
      systemctl restart sing-box >/dev/null 2>&1 || true
    fi
    ok "已把 $SB_TAG 从共享配置迁到 $SB_CONF"
  fi
}

ensure_singbox() {
  if command -v sing-box >/dev/null; then
    ok "sing-box $(sing-box version | head -1 | awk '{print $3}') 已安装"
  else
    local a ver tmp; a=$(arch_tag)
    ver=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
          | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"].lstrip("v"))') \
          || die "查询 sing-box 版本失败"
    tmp=$(mktemp -d) || die "建临时目录失败"
    curl -fsSL -o "$tmp/sb.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/v$ver/sing-box-$ver-linux-$a.tar.gz" \
      || { rm -rf "$tmp"; die "下载 sing-box 失败"; }
    tar xzf "$tmp/sb.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die "解包 sing-box 失败"; }
    install -m 755 "$tmp/sing-box-$ver-linux-$a/sing-box" /usr/local/bin/sing-box \
      || { rm -rf "$tmp"; die "安装 sing-box 失败"; }
    rm -rf "$tmp"
    ok "sing-box $ver 已安装"
  fi

  migrate_legacy_inbound
  install -d -m 700 "$STATE_DIR"
  [ -f "$SB_CONF" ] || printf '%s\n' '{"log":{"level":"warn"},"inbounds":[],"outbounds":[{"type":"direct"}]}' > "$SB_CONF"
  local sb_bin; sb_bin=$(command -v sing-box) || die "找不到 sing-box"
  cat > "$SB_UNIT" <<EOF
[Unit]
Description=sing-box (argo-node inbound)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$sb_bin run -c $SB_CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SB_SVC" >/dev/null 2>&1
  chmod 600 "$SB_CONF"
  ok "sing-box 实例 $SB_SVC 就绪（配置 $SB_CONF）"
}

# ---------- 配置 ----------

# 回环端口是否空闲：优先 ss，没有就用 bind 探测（宁可多跳一个端口也不误判为空闲）
port_free() {
  if command -v ss >/dev/null 2>&1; then
    [ -z "$(ss -lntH "sport = :$1" 2>/dev/null)" ]
    return
  fi
  python3 - "$1" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

port_owner_pid() {
  ss -lntpH "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2
}

pick_port() {
  local p main
  main=$(systemctl show -p MainPID --value "$SB_SVC" 2>/dev/null)
  for p in $(seq "$PORT_BASE" $((PORT_BASE + 20))); do
    if port_free "$p"; then echo "$p"; return; fi
    # 只复用 sing-box-argo 自己的端口（安装中断后重跑的情形）；
    # 别的 sing-box 实例（Simple-Box 等）占着的端口一律避开。
    if [ -n "${main:-}" ] && [ "$main" != 0 ] && [ "$(port_owner_pid "$p")" = "$main" ]; then
      echo "$p"; return
    fi
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

load_node() {
  eval "$(python3 - "$NODE_JSON" <<'PY'
import json, sys
from shlex import quote
d = json.load(open(sys.argv[1]))
for k in ("host", "port", "uuid", "path"):
    print("%s=%s" % (k.upper() if k != "path" else "WSPATH", quote(str(d[k]))))
PY
)"
}

save_node() {
  install -d -m 700 "$STATE_DIR"
  python3 - "$NODE_JSON" "$HOST" "$PORT" "$UUID" "$WSPATH" <<'PY'
import json, sys, time
conf, host, port, uuid, path = sys.argv[1:6]
json.dump({"host": host, "port": int(port), "uuid": uuid, "path": path,
           "created": time.strftime("%F %T")},
          open(conf, "w"), indent=2)
PY
  chmod 600 "$NODE_JSON"
}

# ---------- 隧道服务 ----------

setup_service() {
  install -d -m 700 "$STATE_DIR"
  local cf_bin; cf_bin=$(command -v cloudflared) || die "找不到 cloudflared"
  printf 'TUNNEL_TOKEN=%s\n' "$TOKEN" > "$TOKEN_ENV"
  chmod 600 "$TOKEN_ENV"
  cat > "$CF_UNIT" <<EOF
[Unit]
Description=Cloudflare Tunnel (argo-node)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
TimeoutStartSec=20
EnvironmentFile=$TOKEN_ENV
ExecStart=$cf_bin tunnel --no-autoupdate --protocol http2 run
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
  # 逐个候选串验证，命中第一个合法令牌就返回（避免抓错前半段的超长参数）
  while IFS= read -r t; do
    token_ok "$t" && { printf '%s' "$t"; return; }
  done < <(printf '%s' "$raw" | grep -oE '[A-Za-z0-9_=-]{40,}')
  printf '%s' "$raw"
}

# 令牌必须是 base64 的 {"a":账户,"t":隧道,"s":密钥}
token_ok() {
  python3 - "$1" <<'PY'
import sys, json, base64
t = sys.argv[1].strip()
try:
    d = json.loads(base64.urlsafe_b64decode(t + "=" * (-len(t) % 4)))
    ok = isinstance(d, dict) and {"a", "t", "s"} <= set(d)
except Exception:
    ok = False
sys.exit(0 if ok else 1)
PY
}

token_tunnel_id() {
  python3 - "$1" <<'PY'
import sys, json, base64
t = sys.argv[1].strip()
try:
    d = json.loads(base64.urlsafe_b64decode(t + "=" * (-len(t) % 4)))
    print(str(d.get("t", ""))[:8])
except Exception:
    print("")
PY
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
    nets = []
if not nets:
    print("unknown"); raise SystemExit
hit = [ip for ip in sys.argv[2:] if any(ipaddress.ip_address(ip) in n for n in nets)]
print("cf" if hit else "notcf")
PY
)
  rm -f "$tmp"
  case "$verdict" in
    cf) ok "域名已指向 Cloudflare 边缘（$(echo "$ips" | tr '\n' ',' | sed 's/,$//')）" ;;
    unknown)
      say "   ! 拉不到 Cloudflare 的 IP 段（cloudflare.com/ips-v4），已跳过域名校验"
      return 0 ;;
    *)
      warn "解析到 $(echo "$ips" | tr '\n' ',' | sed 's/,$//')，不是 Cloudflare 的 IP"
      say "       （zone 里多半有泛解析 *，要加 Public Hostname 才会生成指向隧道的 CNAME）"
      return 1 ;;
  esac
}

check_ws() {
  local code
  local rflag=""
  local ip; ip=$(resolve_ips | head -1)
  [ -n "$ip" ] && rflag="--resolve $HOST:443:$ip"
  code=$(curl -s --http1.1 -o /dev/null -m 10 -w '%{http_code}' $rflag \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H "Sec-WebSocket-Key: $(head -c 16 /dev/urandom | base64)" \
    "https://$HOST$WSPATH" 2>/dev/null)
  case "$code" in
    101|400) ok "ws 握手到达本机（HTTP $code）"; return 0 ;;
    404) warn "路径没对上（HTTP 404）——面板里的 Path 或本地 path 不一致"; return 1 ;;
    502|503) warn "边缘连不上本机（HTTP $code）——面板端口应填 127.0.0.1:$PORT"; return 1 ;;
    530) warn "隧道没有活跃连接（HTTP 530 / CF 1033）"; return 1 ;;
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
  say "   在 Tunnels → 当前隧道 → 添加路由："
  say "     主机名：$HOST"
  say "     路径：留空"
  say "     服务地址：http://127.0.0.1:$PORT"
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
  step "客户端配置（mihomo / ClashX Meta，已启用 TUN）"
  cat <<EOF

mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false
tcp-concurrent: true

tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 223.5.5.5
    - 119.29.29.29

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

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - ${HOST%%.*}
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY

EOF
}

# ---------- 卸载 ----------

do_uninstall() {
  step "卸载"
  # 不先查 unit 是否存在：文件被删过但进程还在时也要停掉
  if [ -f "$CF_UNIT" ] || systemctl is-active --quiet "$CF_SVC" 2>/dev/null; then
    systemctl disable --now "$CF_SVC" >/dev/null 2>&1
    ok "隧道服务已停止并删除"
  fi
  rm -f "$CF_UNIT"
  if [ -f "$SB_UNIT" ] || systemctl is-active --quiet "$SB_SVC" 2>/dev/null; then
    systemctl disable --now "$SB_SVC" >/dev/null 2>&1
    ok "sing-box 实例 $SB_SVC 已停止并删除"
  fi
  rm -f "$SB_CONF" "$SB_UNIT"
  systemctl daemon-reload
  rm -rf "$STATE_DIR"
  ok "本地状态已清除"
  say ""
  say "还需要你在 CF 控制台手动删除："
  say "  1. Tunnels → 删除包含 ${HOST:-该域名} 的隧道"
  say "  2. DNS → 删除 ${HOST:-该域名} 的 CNAME 记录"
}

# ---------- 安装 ----------

# 只接受裸主机名：去掉协议头、路径、查询串、空白，转小写
norm_host() {
  local h=${1:-}
  h=${h#http://}
  h=${h#https://}
  h=${h%%/*}
  h=${h%%\?*}
  h=${h%%#*}
  h=${h//[[:space:]]/}
  h=${h%.}
  printf '%s' "${h,,}"
}

host_ok() {
  [ ${#1} -le 253 ] && [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

guide_tunnel() {
  step "创建隧道"
  say "   1. Cloudflare → Tunnels → 创建隧道"
  say "   2. 创建完成后，复制页面上那段令牌代码"
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
  TOKEN=""
  for i in 1 2 3 4 5 6 7 8; do
    # 首行等用户粘贴；后续行 1 秒无输入就收工，避免误输后干等 7 次回车
    if [ "$i" = 1 ]; then IFS= read -rs LINE || break; else IFS= read -rs -t 1 LINE || break; fi
    CAND=$(extract_token "$LINE")
    if token_ok "$CAND"; then TOKEN=$CAND; break; fi
  done
  say ""
  [ -n "$TOKEN" ] || die "没找到隧道令牌（令牌是一段 base64，粘贴时带上整条命令也可以）"
  ok "已读取令牌：${#TOKEN} 字符，隧道 $(token_tunnel_id "$TOKEN")…"

  step "启动隧道"
  setup_service
  local wait_i=0
  while [ $wait_i -lt 20 ]; do
    sleep 1
    wait_i=$((wait_i + 1))
    check_tunnel >/dev/null 2>&1 && break
    systemctl is-failed --quiet "$CF_SVC" && break
  done
  TOKEN_BAD=0
  if ! check_tunnel; then
    say ""
    if [ "${TOKEN_BAD:-0}" = "1" ]; then
      say "   令牌无效，已回滚。回 Cloudflare 重新复制令牌后重跑脚本。"
    else
      say "   隧道 20 秒内没有注册到边缘，已回滚。"
      say "   常见原因：令牌对应的隧道已被删除，或本机出站到 CF 被拦。"
      say "   详细原因：journalctl -u $CF_SVC -n 30"
    fi
    # 回滚干净：不留开机自启的空 sing-box 实例；配置留着，重跑时可直接复用端口
    systemctl disable --now "$CF_SVC" >/dev/null 2>&1
    systemctl disable --now "$SB_SVC" >/dev/null 2>&1
    rm -f "$CF_UNIT" "$SB_UNIT" "$TOKEN_ENV"
    systemctl daemon-reload
    exit 1
  fi

  PORT=$(pick_port)
  UUID=$(python3 -c 'import uuid;print(uuid.uuid4())')
  WSPATH="/$(python3 -c 'import secrets;print(secrets.token_hex(8))')"

  install -d -m 700 "$BACKUP_DIR"
  if [ ! -f "$SB_CONF" ]; then
    mkdir -p "$(dirname "$SB_CONF")"
    printf '%s\n' '{"log":{"level":"warn"},"inbounds":[],"outbounds":[{"type":"direct"}]}' > "$SB_CONF"
  fi
  local bk; bk="$BACKUP_DIR/config.json.$(date +%Y%m%d_%H%M%S)"
  cp -a "$SB_CONF" "$bk" && chmod 600 "$bk"
  apply_inbound
  if sing-box check -c "$SB_CONF" >/dev/null 2>&1; then
    systemctl restart "$SB_SVC" >/dev/null 2>&1
    ok "本地入口已写入（仅监听回环）"
  else
    cp -a "$bk" "$SB_CONF"
    die "配置校验失败，已还原，未做任何改动"
  fi

  step "添加路由"
  say "   主机名：例如 argo-node.example.com"
  say "   路径：留空"
  say "   服务地址：http://127.0.0.1:$PORT"
  say ""
  printf '填写完整主机名: '
  local tries=0
  while :; do
    read -r HOST || die "读取主机名失败"
    HOST=$(norm_host "$HOST")
    [ -n "$HOST" ] || die "域名不能为空"
    host_ok "$HOST" && break
    [ $tries -ge 2 ] && die "主机名不合法：$HOST"
    tries=$((tries + 1))
    warn "只填裸主机名（如 argo-node.example.com），不要带 https:// 、路径或空格"
    printf '重新填写: '
  done

  save_node

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
