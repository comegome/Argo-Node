# argo-node

把一台 VPS 变成**只经 Cloudflare 隧道可达**的出口节点。公网不开放任何端口，代理入口只监听 `127.0.0.1`。

适用场景：机器 IP 被针对、需要一个干净入口，或者不想暴露源站 IP。**不解决线路质量问题**——落点由 BGP 决定，不归这个脚本管。

## 用法

```bash
curl -fsSL https://raw.githubusercontent.com/comegome/Argo-Node/main/argo-node.sh -o /tmp/argo-node.sh
sudo bash /tmp/argo-node.sh
```

**不要用 `curl | bash`**。脚本是交互式的，管道会让 `read` 直接读到 EOF，拿不到你输入的域名和 token。

需要：Linux + systemd、root、`curl`、`python3`。`cloudflared` 和 `sing-box` 缺了会自动装（sing-box 已存在则只追加 inbound，不动原有配置）。

## 流程

1. **运行脚本**，确认后自动装依赖（cloudflared + sing-box）
2. **CF 控制台建隧道**：Cloudflare → Tunnels → 创建隧道 → 复制令牌粘给脚本（直接粘整条 `cloudflared`/`docker` 命令也行，脚本会自己提取）
3. **脚本先起隧道验证令牌**：连不上就直接回滚退出，不会让你白跑面板
4. **脚本写本地入口**：固定端口 `2080`（被占用则顺延 2081、2082…），只监听 `127.0.0.1`
5. **添加路由**：在隧道页面把脚本给的 `http://127.0.0.1:2080` 粘进 Service URL，Path 留空，并选一个公共主机域名
6. **回脚本输入那个主机名**，脚本启动隧道并校验

端口固定是为了重跑不换号——中途退出重来，面板里填的地址依然有效。

状态驱动，没有子命令：

```
未安装      → 安装流程 → 自动校验
已安装      → [c] 检查   [r] 卸载重装   [u] 只卸载
```

## 校验分三层

| 层 | 判据 | 失败含义 |
|---|---|---|
| 隧道 | `systemctl is-active` + journal 里 `Registered tunnel connection` 计数 | token 无效，或 cloudflared 起不来 |
| 域名 | `dig @1.1.1.1` 解析结果落在 Cloudflare IP 段内 | 没加 Public Hostname，或被 zone 的泛解析 `*` 抢走 |
| 握手 | `curl` 带 Upgrade 头请求 `https://域名/path`，**400 或 101 都算通** | 404=path 不匹配，502=面板端口错，1033=隧道没连上 |

400 是 sing-box 拒绝非真正的 ws 握手，说明请求已经穿过隧道到达本机——这正是我们想确认的。

## 落盘

```
/etc/argo-node/node.json   # 安装期常量：host / port / uuid / path
/etc/argo-node/tunnel.env  # tunnel token，600
/etc/argo-node/backup/     # 改 sing-box 配置前的备份
```

除这几处外不写任何东西。`cloudflared` 是共享依赖，卸载时不删。

## 卸载

跑脚本选 `u`，本地会清干净（inbound 移除、unit 删除、状态目录删除）。

**面板里还要手动删两样**：隧道本身、对应的 CNAME 记录。模式 A 不持有 CF API 凭证，脚本删不了远端。

## 安全

- 仓库里没有任何密钥。token 是运行时输入的，只存在目标机 `/etc/argo-node/tunnel.env`（600）
- 不开放任何公网端口，代理入口只在回环
- 修改 sing-box 配置前先备份，`sing-box check` 失败自动还原并退出

## 已知限制

- **一个隧道只挂一台机器**。同一隧道挂两台，请求会在连接器之间轮询，两条链路一起变慢
- **本机 DNS 缓存会骗人**。zone 里有 `*` 泛解析时，加完 Public Hostname 后本机仍可能返回旧 IP。脚本已用 `dig @1.1.1.1` + `curl --resolve` 绕开；客户端侧（macOS）需要 `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`
- **CF 前置有固有延迟**。中国方向常被 BGP 甩到 LAX/AMS，首字节 0.5–3s 都可能。要低延迟请直连 Reality/Hy2

## License

MIT
