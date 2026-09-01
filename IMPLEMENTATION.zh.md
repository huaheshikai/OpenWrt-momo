# Momo 实现说明与运维文档

本文档对应当前仓库代码（`PKG_VERSION=1.2.1`），面向需要编译、移植、配置或排查问题的开发者和 OpenWrt 运维人员。Momo 本身不实现代理协议，代理核心由 `sing-box` 提供；Momo 负责配置组合、进程托管、策略路由和 firewall4/nftables 透明接管。

## 1. 项目定位

Momo 是运行在 OpenWrt 24.10 及以上、firewall4 环境中的透明代理封装层，支持：

- TCP：`redirect`、`tproxy`、`tun` 三种接管模式；UDP 可使用 `tproxy` 或 `tun`。
- IPv4、IPv6 独立开关，以及 DNS 劫持（53 端口重定向）。
- 按路由器进程（用户、组、cgroup）和 LAN 客户端（IP、IPv6、MAC）进行访问控制。
- 本地 profile 或远程订阅，启动前自动下载、格式化并校验。
- 定时重启、日志定时清理、配置变更热重载。

运行时的总体关系如下：

```text
UCI (/etc/config/momo) ─┬─> momo.init ──> sing-box (/etc/momo/run/config.json)
                        ├─> mixin.uc（把 UCI 选项合并进 JSON）
                        └─> hijack.ut ──> nftables table inet momo
                                                └─> fw mark ──> ip rule/route
```

## 2. 目录与文件职责

| 路径 | 用途 |
| --- | --- |
| `momo/Makefile` | OpenWrt 包元数据、依赖和安装清单；无 C/C++ 编译步骤。 |
| `momo/files/momo.conf` | 默认 UCI 配置，安装为 `/etc/config/momo`。 |
| `momo/files/momo.init` | `/etc/init.d/momo`，procd 生命周期、订阅、校验、路由和清理。 |
| `momo/files/ucode/mixin.uc` | 读取 UCI 的 mixin 选项，深度合并到运行 profile。 |
| `momo/files/ucode/include.uc` | ucode 公共函数：UCI 类型转换、对象合并、路径和 profile 读写。 |
| `momo/files/ucode/hijack.ut` | utpl 模板，按 UCI/profile 生成 nftables 规则。 |
| `momo/files/scripts/include.sh` | Shell 路径常量、日志、文件准备、大小格式化等公共函数。 |
| `momo/files/scripts/firewall_include.sh` | firewall4 include 脚本；为 TUN 设备插入允许 input/forward 规则。 |
| `momo/files/scripts/debug.sh` | 生成脱敏诊断信息（配置和 profile 中的密钥、地址会被替换）。 |
| `momo/files/firewall/geoip*_cn.nft` | 可选的中国大陆 IPv4/IPv6 地址集合。 |
| `momo/files/uci-defaults/*.sh` | 首次安装初始化、防火墙 include 注册和版本迁移。 |
| `momo/files/momo.upgrade` | 升级时保留本地 profile 与订阅文件。 |
| `install.sh`/`feed.sh`/`uninstall.sh` | 发行版安装、软件源注册和卸载重置。 |

运行时目录：

- `/etc/momo/profiles/`：本地 sing-box JSON profile。
- `/etc/momo/subscriptions/`：按 UCI section 名保存的订阅 JSON。
- `/etc/momo/run/config.json`：当前启动实例的工作副本，不应直接作为持久配置编辑。
- `/var/log/momo/app.log`、`core.log`、`debug.log`：应用、sing-box 和诊断日志。
- `/var/run/momo/`：PID、启动标记、bridge sysctl 恢复标记等临时文件。

## 3. 安装、升级与卸载

### 3.1 从 feed 安装（推荐）

```sh
wget -O - https://github.com/nikkinikki-org/OpenWrt-momo/raw/refs/heads/main/feed.sh | ash
opkg install momo       # OpenWrt 24.10
apk add momo             # OpenWrt 25.12/SNAPSHOT
```

`feed.sh` 读取 `/etc/openwrt_release` 的 `DISTRIB_RELEASE` 和 `DISTRIB_ARCH`，选择 `openwrt-24.10`、`openwrt-25.12` 或 `SNAPSHOT` feed；opkg 导入构建公钥，apk 安装 `public-key.pem` 并写入自定义仓库。

### 3.2 发行版一键安装

```sh
wget -O - https://github.com/nikkinikki-org/OpenWrt-momo/raw/refs/heads/main/install.sh | ash
```

脚本先检查 firewall4 和包管理器，再下载 feed 索引（opkg）或直接从 apk 仓库安装。升级时重复执行即可。

### 3.3 卸载与重置

```sh
wget -O - https://github.com/nikkinikki-org/OpenWrt-momo/raw/refs/heads/main/uninstall.sh | ash
```

卸载包后会删除 `/etc/config/momo`、`/etc/momo`、日志、临时目录、feed 条目和签名密钥。profile/订阅不会保留，请在执行前备份。

## 4. 配置模型（UCI）

编辑 `/etc/config/momo` 后执行 `uci commit momo`。关键 section 如下。

### 4.1 `config`

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `enabled` | `0` | 是否启动服务。 |
| `profile` | `file:example.json` | `file:<文件名>` 或 `subscription:<section>`。 |
| `start_delay` | `0` | 启动延迟秒数。 |
| `scheduled_restart`/`scheduled_restart_cron` | `0`/`0 3 * * *` | 定时重启。 |
| `test_profile` | `1` | 启动前执行 `sing-box check`。 |
| `core_only` | `0` | 仅运行 sing-box，不生成代理防火墙和策略路由。 |

### 4.2 `procd`、`core` 与 `mixin`

`procd.fast_reload=1` 时配置文件变更发送 HUP；`rlimit_*` 控制进程资源上限，`env_go_max_procs`/`env_go_mem_limit` 映射为 Go 环境变量。`core` 中的五个 tag 必须与 profile 的 inbound/DNS server tag 对应：`redirect_inbound_tag`、`tproxy_inbound_tag`、`tun_inbound_tag`、`dns_inbound_tag`、`fake_ip_dns_server_tag`。

`mixin` 选项由 `mixin.uc` 转换为 sing-box JSON：日志、DNS 缓存、NTP、experimental cache-file 和 Clash API（外部 UI、监听地址、secret）。空字符串、空数组和空对象会被 `trim_all()` 删除，避免覆盖 profile 原有设置。

### 4.3 `proxy`

`enabled` 总开关；`ipv4_proxy`/`ipv6_proxy` 控制地址族；`ipv4_dns_hijack`/`ipv6_dns_hijack` 控制 DNS 劫持；`tcp_mode`、`udp_mode` 取 `redirect`/`tproxy`/`tun`。`router_proxy` 和 `lan_proxy` 分别启用路由器自身与 LAN 流量。`reserved_ip`、`reserved_ip6`、`proxy_*_dport`、`bypass_dscp`、`bypass_fwmark` 是绕过条件；`bypass_china_mainland_ip*` 启用内置 GeoIP 集合；`fake_ip_ping_hijack` 接管 Fake-IP 地址的 ICMP ping。TUN 等待参数为 `tun_timeout`（秒）和 `tun_interval`（秒）。

### 4.4 访问控制 section

```uci
config router_access_control
    option enabled '1'
    list user 'nobody'
    list group 'nogroup'
    list cgroup 'services/adguardhome'
    option dns '1'
    option proxy '1'

config lan_access_control
    option enabled '1'
    list ip '192.168.1.20'
    list mac 'AA:BB:CC:DD:EE:FF'
    option dns '1'
    option proxy '1'
```

路由器规则按 UID/GID/cgroupv2 匹配；不存在的用户、组和 cgroup 会被模板过滤。LAN 规则按源 IP、IPv6 或 MAC 匹配。没有匹配条件的 section 表示默认匹配对应范围。

### 4.5 `routing` 与 `log`

`routing` 定义 TPROXY/TUN 的 fwmark、mask、rule preference、路由表号，以及 cgroup 标识和 Fake-IP IPv6 使用的 dummy 设备。默认值为 TPROXY `0x80`/表 `80`，TUN `0x81`/表 `81`。避免与系统或其他插件使用相同 mark、表号和设备名。

`log.clear_at_stop` 控制停止时清空 app/core 日志；`scheduled_clear`、`scheduled_clear_cron` 和大小阈值控制定时清理。

## 5. 启动与运行流程

1. `prepare_files` 创建日志、运行和临时目录。
2. 读取 UCI，检查 `enabled`、sing-box 可执行文件和 profile 来源。
3. 本地 profile 复制；订阅 profile 必要时通过 curl 下载，并解析 `subscription-userinfo` 响应头更新用量/到期时间。
4. 非 `core_only` 模式运行 `mixin.uc`，随后执行 `sing-box format -w`。
5. 根据启用的模式检查所需 inbound：DNS 必须是 direct 且有 `listen_port`；redirect/tproxy 必须有端口；TUN 必须有 `interface_name`。
6. `test_profile=1` 时执行 `sing-box check`；通过后由 procd 以 `sing-box -D /etc/momo/run run` 启动，并启用 respawn、pidfile、资源限制和可选 HUP。
7. `service_started` 等待 TUN UP，必要时创建 cgroup、关闭 bridge-nf-call-*，添加 `ip rule`/路由表，创建 Fake-IP IPv6 dummy 路由。
8. 使用 `utpl -S hijack.ut | nft -f -` 生成并加载 `inet momo` 表；成功后写入 `started.flag`。同时刷新 cron 中带 `#momo` 的条目。

停止/重载会删除策略路由、dummy 设备、`inet momo` 表及 firewall4 中带 `comment "momo"` 的规则，恢复 bridge sysctl、清理 cron 和启动标记。

## 6. nftables 与策略路由实现

`hijack.ut` 先从 profile 提取 inbound 端口、TUN 设备和 Fake-IP 网段，再从 UCI 构造 set 与链。主要链：

- `router_dns_hijack`/`lan_dns_hijack`：TCP/UDP 53 重定向到 DNS inbound。
- `router_redirect`/`lan_redirect`：TCP `redirect to :port`。
- `router_tproxy`/`lan_tproxy`：设置 TPROXY mark，并 `tproxy to :port`。
- `router_tun`/`lan_tun`：设置 TUN mark，由策略路由送入 TUN。
- `nat_output`、`mangle_output`：处理路由器本机流量；`dstnat`、`mangle_prerouting_lan`：处理 LAN 入站流量。
- 规则优先跳过本地/保留地址、中国大陆地址（可选）、非目标端口、DSCP 和 fwmark 绕过项，并避免 reply 流量重复接管。

TPROXY 使用 `ip rule fwmark 0x80/0xFF table 80` 和 `local default dev lo`；TUN 使用 `0x81/0xFF table 81` 和 `default dev <tun>`。IPv4/IPv6 根据开关分别创建。TUN 模式额外通过 firewall include 放行该设备的 input/forward。

## 7. 编译与发布

在 OpenWrt 源码树中：

```sh
echo 'src-git momo https://github.com/nikkinikki-org/OpenWrt-momo.git;main' >> feeds.conf.default
./scripts/feeds update -a
./scripts/feeds install -a
make package/momo/compile V=s
```

`Build/Compile` 为空，因为包只安装脚本和模板。依赖由 Makefile 声明：`ca-bundle`、`curl`、`firewall4`、`ip-full`、`kmod-inet-diag`、`kmod-nft-socket`、`kmod-nft-tproxy`、`kmod-tun`、`kmod-dummy`、`sing-box`。GitHub Actions 对 OpenWrt 24.10、25.12 和 SNAPSHOT 的多架构矩阵构建；打 `v*` 标签时使用 25.12 x86_64 SDK 发布 APK。

## 8. 排错与安全注意事项

```sh
/etc/init.d/momo restart
logread -e momo
tail -f /var/log/momo/app.log /var/log/momo/core.log
nft list table inet momo
ip rule show; ip route show table 80; ip route show table 81
/etc/momo/scripts/debug.sh > /tmp/momo-debug.txt
```

常见故障：profile 文件不存在；tag 与 `core` 不一致；对应 inbound 缺少端口/接口名；`sing-box check` 失败；TUN 未在超时内 UP；内核缺少 nft tproxy/socket、tun 或 inet-diag 模块；mark/路由表与其他服务冲突。修改 UCI 后应先 `uci commit momo` 再重启。

订阅 URL、API secret、节点密码和密钥属于敏感信息；不要把原始 `/etc/momo` 或 core.log 上传到公开渠道。`debug.sh` 会脱敏常见字段，但仍建议人工复核。安装脚本通过网络下载并执行，生产环境应固定版本、校验脚本和软件包签名。

## 9. 扩展指南

- 新增 UCI 选项：在 `momo.conf` 加默认值，在 `momo.init` 或 `hijack.ut` 读取，并在 `mixin.uc` 中补充 JSON 映射；必要时在 `migrate.sh` 添加兼容迁移。
- 新增防火墙逻辑：优先在 `hijack.ut` 的 set/chain 中实现，确保 `cleanup()` 能删除生成对象；需要 firewall4 主表放行时才修改 `firewall_include.sh`。
- 修改安装内容：同步更新 `momo/Makefile` 的 `Package/momo/install` 和 `momo.upgrade` 保留策略。
- 提交前至少执行 shell 语法检查（`sh -n`）、在目标 OpenWrt 上运行 `sing-box check`，并验证 `nft list table inet momo`、IPv4/IPv6 及停止后的清理结果。

