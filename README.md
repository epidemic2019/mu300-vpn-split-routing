# mu300-vpn 分流配置工具

**在 ZTE F50（Unisoc T760，mu300-linux / OpenWrt）上实现「中国大陆 IP 直连、其余全部走 VPN」。**

[English](README.en.md) · [原理](docs/原理与设备约束.md) · [部署与验证](docs/部署与验证.md) · [故障排查](docs/故障排查.md)

---

## 目录

- [这是什么](#这是什么)
- [为什么需要专门做一套](#为什么需要专门做一套)
- [判定链](#判定链)
- [适用环境](#适用环境)
- [快速开始](#快速开始)
- [脚本一览](#脚本一览)
- [生成的配置长什么样](#生成的配置长什么样)
- [三层验证](#三层验证)
- [备份与回滚](#备份与回滚)
- [常见问题](#常见问题)
- [目录结构](#目录结构)
- [安全提醒](#安全提醒)
- [数据来源与致谢](#数据来源与致谢)

---

## 这是什么

`mu300-vpn` 本身是**整机全局隧道 + kill switch** 的设计，没有分流能力。它把所有出向流量都塞进隧道，隧道断了就丢包——这很安全，但意味着境内网站也被绕了一圈境外。

这套工具在**不改动 `mu300-vpn` 本体**的前提下，利用它的一个特性打开分流：

> sing-box 驱动接受**原始配置（raw config）**形态的 profile。这种形态下，配置里的
> `route.rules` 会被**逐条保留**，只把 `inbounds` 换成设备自己的 TUN。
> 于是只要在规则表末尾追加一条「中国大陆地址段 → direct」，兜底的 `final: proxy`
> 自然就变成了「其余全部走 VPN」。

结果：

| 目标 | 走向 | 出口 |
|---|---|---|
| 中国大陆地址 | 直连 | 你的蜂窝 / 运营商 IP |
| 非中国大陆地址 | 隧道 | VPN 服务器 IP |
| 私网 / 回环 / 链路本地 | 直连 | 不出设备 |
| LAN 客户端发向其他私网段 | 丢弃 | 不进隧道 |

## 为什么需要专门做一套

直接照着 sing-box 官方文档写一份配置，在这台设备上**不会生效**。以下几个约束都是实测出来的，每一条都改变了实现方式：

| 约束 | 实测结论 | 后果 |
|---|---|---|
| 引擎会被人为切换 | 默认 `KILL_SWITCH=1` 且装了 sing-box 时，`pick_engines` 把引擎**强制改成 sing-box** | 那种「用原始 Xray JSON 写在 `routing.rules` 里」的做法，配置**根本不会被加载** |
| 分享链接型 profile 的路由是写死的 | `gen_singbox()` 只生成 `sniff → hijack-dns → LAN+私网 reject → 私网 direct`，`final: proxy`，**没有任何大陆直连规则** | 想让大陆直连，必须用 raw config 形态 |
| 引擎看不到域名 | Xray 驱动入站是**回环 SOCKS 且从不 sniffing**，`hev-socks5-tunnel` 只搬运 IP 层包 | `domain:` 规则是**死代码**；判据只能是 IP |
| `geoip:cn` 不可用 | 镜像里没有 `geoip.dat` | 7456 条大陆段必须**内联**进配置 |
| 文件上限 1 MiB | 超了直接拒收 | 内联后 141 KB，还有余量但需要校验 |
| 直连出口必须带 mark | 设备只给**已有 `streamSettings` 对象**的出口写 `sockopt.mark=720` | 直连出口若省掉 `streamSettings`，包会被 kill switch 丢弃——「直连」变成「黑洞」 |
| 设备会覆盖一些参数 | 强制 `inbounds`、`route.default_mark=720`、`auto_detect_interface`，并追加自己的 bootstrap DNS | 手抄 VLESS 参数极易出错 |

最后一条是关键：**不要手抄参数**。本工具推荐的做法是先让设备自己生成一份基准配置（`mu300-vpn gen`），再把分流规则注入进去——这样 Reality 公钥、`flow`、`packet_encoding`、DNS `strategy` 等与设备预期**逐字节一致**。

## 判定链

sing-box 引擎的实际判定顺序：

```
数据包 ──▶ TUN (sbtun，172.19.0.1/30)
             │
             ├─ ① action: sniff ─────────────── 不放行，只做协议识别
             ├─ ② protocol: dns → hijack-dns ── 客户端 DNS 被劫持进隧道，不泄漏
             ├─ ③ 源∈LAN 且 目标∈私网 → reject ─ 不进隧道
             ├─ ④ 目标∈私网/回环/保留 → direct
             ├─ ⑤ 目标∈中国大陆 7456 段 → direct ─ 引擎自连，
             │                                   带 mark 0x2d0 → 内核规则 5198
             │                                   → main 表 → 蜂窝口直出
             └─ ⑥ final: proxy ──────────────── VLESS 隧道 → VPN 服务器
```

LAN 根本不进 TUN：`route_exclude_address` 里已经排除了 LAN 网段。

## 适用环境

| 项 | 值 |
|---|---|
| 设备 | ZTE F50 / MU300（Unisoc T760） |
| 系统 | mu300-linux 的 OpenWrt（实测 OpenWrt 25.12.5，aarch64） |
| 组件 | `mu300-vpn`（`vpn` extra），sing-box 1.14+ / Xray 26+ |
| 本地依赖 | POSIX `sh`、`ssh`、`scp`、`curl`、Python 3.9+ |
| 节点 | 任意 `vless` / `vmess` / `trojan` / `shadowsocks` 分享链接 |

> 其他 OpenWrt 设备上，只要 `mu300-vpn` 的 profile 语义相同，这套工具同样可用；但 `pick_engines` 的行为、profile 校验白名单、kill switch 规则需要重新确认。

## 快速开始

### 0. 取回代码

```sh
git clone <this-repo> mu300-vpn-split-routing
cd mu300-vpn-split-routing
chmod +x scripts/* tools/*
```

### 1.（推荐）从设备取一份基准配置

在设备上跑一次 `gen`，只写 `/tmp`，不碰 `/etc`：

```sh
ssh root@<设备IP>
  MU300_VPN_RUN=/tmp/gen mu300-vpn gen
  cat /tmp/gen/config.json
```

把它存成本地的 `device-base.json`。

> **为什么值得多这一步**：`gen` 会用设备自己的解析器把你的节点参数展开成
> `outbounds`。直接用它当基准，就不会出现「公钥少一位」「flow 没写」「DNS 策略不对」
> 这类只有连不通时才暴露的问题。
>
> 不想做这一步也可以用 `--uri` 离线生成，参数映射是本工具自己的实现，见
> [常见问题](#no-device-access)。

### 2. 生成配置

```sh
# 推荐：以设备基准生成（顺带校验、自检）
python3 scripts/gen-split-config.py --base device-base.json

# 或者：完全离线，从分享链接生成
python3 scripts/gen-split-config.py \
    --uri-file examples/node.example.uri \
    --lan-cidrs 192.168.77.0/24
```

产出：

```
out/split-cn.singbox.json     ← 默认引擎（KILL_SWITCH=1 时真正被加载的那个）
out/split-cn.xray.json        ← 仅在 KILL_SWITCH=0 时使用
```

**`--lan-cidrs` 在 `--base` 模式下可以省略**——设备生成的基准里已经带了
`route_exclude_address`，生成器会把 LAN 网段读回来，比手填更可靠：

```
LAN subnet          : 192.168.77.0/24  (read back from the base config's route_exclude_address)
```

离线模式（`--uri`）无法探测，默认用 F50 出厂值 `192.168.77.0/24`，并在输出里
提示你去核对 `mu300-vpn settings get LAN_CIDRS`。

### 3. 离线自检

不需要设备、不需要网络：

```sh
python3 tools/verify-routing.py out/split-cn.singbox.json
```

它会重放规则表，断言大陆地址 → `direct`、境外地址 → `proxy`、私网 → `direct`。

### 4. 在设备上排练一遍（零副作用）

利用 `MU300_VPN_CONF` / `MU300_VPN_DIR` / `MU300_VPN_RUN` 三个环境变量把组件完整重定向到 `/tmp`，跑真实引擎校验，**不动 `/etc`、不动内核、不动 nft**：

```sh
scripts/sandbox-test.sh --host 192.168.77.1 --config out/split-cn.singbox.json
```

### 5. 部署

```sh
scripts/deploy.sh --host 192.168.77.1 --lan-cidrs 192.168.77.0/24 --dry-run
scripts/deploy.sh --host 192.168.77.1 --lan-cidrs 192.168.77.0/24
```

密码通过 `--pass`、`MU300_PASS` 或交互输入提供，**代码里没有任何硬编码凭据**。

### 6. 验证

在**一台 LAN 客户端**上跑（同时会测设备自身）：

```sh
scripts/verify.sh --host 192.168.77.1
```

## 脚本一览

| 脚本 | 作用 | 会改动设备吗 |
|---|---|---|
| `scripts/gen-split-config.py` | 生成分流配置（`--base` / `--uri` 两种模式） | 否 |
| `scripts/fetch-cn-cidrs.sh` | 刷新 `data/` 里的大陆 IP 段（`--check` 只比对） | 否 |
| `tools/verify-routing.py` | 离线路由语义校验，可进 CI | 否 |
| `scripts/sandbox-test.sh` | 在设备 `/tmp` 里用真实引擎排练一遍 | 否（全在 `/tmp`） |
| `scripts/deploy.sh` | 安装 profile、设置 LAN 段、开关隧道 | **是**（`--dry-run` 可只看不动） |
| `scripts/verify.sh` | 真实网络访问测试 + IPv6 泄漏探针 | 否 |
| `scripts/backup.sh` | 流式备份 `/etc` + 逐文件哈希 | 否（只读） |
| `scripts/restore.sh` | 回滚；支持 `--verify` / `--dry-run` | **是** |
| `scripts/lib-ssh.sh` | 共用 SSH 封装（askpass，密码不进 argv） | — |

## 生成的配置长什么样

```jsonc
{
  "dns": { /* 原样取自设备 gen 输出 */ },
  "outbounds": [
    { "type": "vless", "tag": "proxy", "server": "203.0.113.10", /* … */ },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "source_ip_cidr": ["192.168.77.0/24"], "ip_is_private": true, "action": "reject" },
      { "ip_is_private": true, "outbound": "direct" },
      { "ip_cidr": [ /* 7456 条中国大陆段 */ ], "outbound": "direct" }   // ← 本工具注入
    ],
    "final": "proxy"                                                     // ← 其余全部走 VPN
  }
}
```

完整示意见 [`examples/split-cn.example.jsonc`](examples/split-cn.example.jsonc)。

设备在 rebuild 阶段会给它补上：

```jsonc
"inbounds": [{
  "type": "tun", "tag": "tun-in", "stack": "gvisor", "interface_name": "sbtun",
  "address": ["172.19.0.1/30"], "mtu": 1400,
  "auto_route": true, "strict_route": true,
  "route_exclude_address": ["192.168.77.0/24"]     // ← LAN 不进隧道
}],
"route": { "default_mark": 720, "auto_detect_interface": true,   // 720 = 0x2d0
           "default_domain_resolver": "bootstrap" }
```

## 三层验证

| 层 | 命令 | 判据 | 是否需要设备 |
|---|---|---|---|
| ① 离线语义 | `tools/verify-routing.py` | 重放规则表，断言每条判定 | 否 |
| ② 设备排练 | `scripts/sandbox-test.sh` | 设备自己的 `mu300-vpn check` / `sing-box check` / `xray -test` | 是（只读 `/tmp`） |
| ③ 真实网络 | `scripts/verify.sh` | **两个出口 IP 互为判别器** | 是 |

第 ③ 层的逻辑：分流只有两种可能出口，所以拿一个大陆 IP 回显服务和一个境外 IP 回显服务各测一次就够了。

- 大陆回显返回「运营商 IP」、境外回显返回「VPN 服务器 IP」→ 分流成立
- 两者返回同一个地址 → 分流没生效

这不是启发式判断：**出口 IP 非此即彼，不存在第三种可能**。

`verify.sh` 还会做 IPv6 泄漏探针——隧道在线时，任何 IPv6 出向都应当失败。

## 备份与回滚

```sh
# 备份（先做这个）
scripts/backup.sh --host 192.168.77.1

# 只看不动
scripts/restore.sh --dir backups/f50-<时间戳> --host 192.168.77.1 --verify
scripts/restore.sh --dir backups/f50-<时间戳> --host 192.168.77.1 --dry-run

# 真正回滚（只回滚 VPN 相关部分）
scripts/restore.sh --dir backups/f50-<时间戳> --host 192.168.77.1 --yes --only etc/mu300
```

备份包含 `/etc` 全量、`uci export`、网络状态、逐文件 md5。还原前会自动把当前 `/etc/mu300` 存到 `/tmp`，所以**错误的还原本身也是可逆的**。

回滚的另一个更轻的办法是只切回原 profile：

```sh
mu300-vpn profile use <你原来的 profile 名>
mu300-vpn settings set LAN_CIDRS ''
```

本工具不改动你原有的 profile，只新增一个，所以这条路径通常就够了。

## 常见问题

<a id="no-device-access"></a>
<details>
<summary><b>我没有设备权限，做不到第 1 步怎么办？</b></summary>

用 `--uri` / `--uri-file` 完全离线生成：

```sh
python3 scripts/gen-split-config.py --uri-file my-node.uri --lan-cidrs 192.168.1.0/24
```

这条路会把分享链接的查询参数映射成 sing-box 的出口字段。映射逻辑覆盖
`vless` / `vmess` / `trojan` / `shadowsocks` 与 `raw` / `ws` / `grpc` /
`httpupgrade` 传输，以及 `tls` / `reality` 安全层。仍有少数冷门组合可能不完整，
所以**一旦能连上设备，建议回到 `--base` 模式重新生成**。
</details>

<details>
<summary><b>为什么默认输出 sing-box 而不是 Xray？</b></summary>

因为设备默认会把你写的 Xray 配置忽略掉。`pick_engines` 里有这么一行：

```sh
if [ "$ENGINE" = xray ] && [ "$KILL_SWITCH" = 1 ] && [ -x "$BIN" ]; then ENGINE=sing-box; fi
```

`KILL_SWITCH=1` 是出厂默认，所以只要是分享链接型 profile，最终都会交给 sing-box。
想真正用 Xray 引擎就得关掉 kill switch——那会同时失去「断线不泄漏」的保护，
所以 `deploy.sh --engine xray` 会明确警告并要求确认。
</details>

<details>
<summary><b>能按域名分流吗？</b></summary>

在这台设备上不能。Xray 驱动的入站是回环 SOCKS 且没有 sniffing，
`hev-socks5-tunnel` 只把 IP 层包转成 SOCKS，**引擎从头到尾看不到域名**。
所以 `domain:` 规则写了也不会命中，判据只能是 IP 段。

sing-box 驱动那条路径虽然开了 `action: sniff`，但分流规则本身基于 IP，
保持一致的行为更可预测。
</details>

<details>
<summary><b>国内的 CDN 站点被解析成境外 IP，走了 VPN 怎么办？</b></summary>

这确实会发生：你的 DNS 查询被劫持进隧道，解析结果带有「隧道出口所在地」的视角，
少数国内站点会被调度到境外节点。

缓解办法：换一个国内 DNS 作为隧道内的解析器，或在 `--base` 生成后手工
在 CN 规则**之前**插入 `domain:*.example.com → direct` 之类的规则。
注意这是在 sing-box 路径下才有意义（有 sniffing）。

见 [故障排查](docs/故障排查.md#国内站点被判成境外)。
</details>

<details>
<summary><b>改了 IP 段之后要重新生成吗？</b></summary>

要。CN 段是**内联**进配置的，不是运行时查表。

```sh
scripts/fetch-cn-cidrs.sh                     # 刷新数据
python3 scripts/gen-split-config.py --base device-base.json
scripts/sandbox-test.sh --host <设备IP> --config out/split-cn.singbox.json
scripts/deploy.sh       --host <设备IP>
```

大陆 IP 委派变化很慢，一个月刷一次足够。
</details>

<details>
<summary><b>换了节点（新的分享链接）怎么办？</b></summary>

先在设备上把新链接跑一遍 `gen` 取新基准，再重新生成：

```sh
# 设备上
mu300-vpn profile add <类型> <名字> '<新链接>'
mu300-vpn profile use <名字>
MU300_VPN_RUN=/tmp/gen mu300-vpn gen     # 取 /tmp/gen/config.json

# 本地
python3 scripts/gen-split-config.py --base 新基准.json --name split-cn-v2
scripts/deploy.sh --host <设备IP> --config out/split-cn-v2.singbox.json --profile split-cn-v2
```
</details>

<details>
<summary><b>隧道在线，但 IPv6 好像漏了？</b></summary>

先按 `scripts/verify.sh` 的 IPv6 探针测。设备侧 sing-box 会装
`ip -6 rule 9000: from all unreachable`，LAN 侧的 IPv6 出向由 kill switch 的
`forward` 链丢弃。

⚠️ 不要用 `exec 3<>/dev/tcp/8.8.8.8/53` 这类方式判断泄漏：
对走 TUN 的目标，**sing-box 的 gvisor 栈会在本地完成握手**，看起来「连上了」，
但实际并没有出网。判泄漏看出口 IP。
</details>

<details>
<summary><b>为什么 `nft list ruleset` 两次结果不一样？</b></summary>

`counter packets` 计数在变。比对前后状态前先过滤掉：

```sh
nft list ruleset | grep -v 'counter packets'
```
</details>

## 目录结构

```
.
├── README.md                 中文主文档（本文件）
├── README.en.md              English
├── CHANGELOG.md
├── LICENSE                   MIT
├── .github/workflows/ci.yml  生成器自检 + 离线校验 + 泄漏扫描
├── data/
│   ├── cn-ipv4.txt           中国大陆 IPv4 段（7456 条）
│   ├── cn-ipv6.txt           中国大陆 IPv6 段
│   └── SOURCES.md            数据来源与更新方法
├── docs/
│   ├── 原理与设备约束.md      为什么必须这么做（中文）
│   ├── how-it-works.md        (English)
│   ├── 部署与验证.md          完整操作手册（中文）
│   ├── deploy-and-verify.md   (English)
│   ├── 故障排查.md            （中文）
│   └── troubleshooting.md     (English)
├── examples/
│   ├── node.example.uri      分享链接模板（全部为占位值）
│   ├── device-base.example.json
│   └── split-cn.example.jsonc
├── scripts/                  生成 / 部署 / 验证 / 备份 / 还原
└── tools/verify-routing.py   离线路由语义校验
```

## 安全提醒

- **备份和生成的配置都是敏感文件。** 里面有你节点的地址、UUID，备份里还有
  `/etc/shadow` 和 dropbear 主机密钥。按密码对待。`.gitignore` 已经默认排除。
- **本工具不会替你改变 kill switch 的语义。** 默认 `KILL_SWITCH=1` 全流程有效，
  隧道断了流量被丢弃而不是明文直出。`--engine xray` 需要关掉它，会明确警告。
- **`mu300-vpn off` 会撤掉 kill switch**，那之后流量是明文直出的。
  `/etc/init.d/mu300-vpn stop` 摁不住它（`respawn` 会约 5 秒后拉起来）。
- **`deploy.sh` 会写入 `/etc`。** 先用 `--dry-run` 看一遍它打算做什么。

## 数据来源与致谢

| 数据 | 来源 | 许可 |
|---|---|---|
| 中国大陆 IPv4 段 | [17mon/china_ip_list](https://github.com/17mon/china_ip_list) | MIT |
| 中国大陆 IPv6 段 | [gaoyifan/china-operator-ip](https://github.com/gaoyifan/china-operator-ip) | MIT |

`data/` 下是快照，用 `scripts/fetch-cn-cidrs.sh` 刷新；`--check` 可以只看是否有更新。
详见 [`data/SOURCES.md`](data/SOURCES.md)。

引擎相关的行为结论来自对 mu300-linux 设备上真实脚本与二进制的实测
（`bin/mu300-vpn`、`lib/vpn/*.sh`、`xray`、`sing-box`），不是文档推断。

## License

[MIT](LICENSE)
