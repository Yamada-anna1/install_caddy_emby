# Caddy + Emby 多后端管理脚本

这是基于 [AiLi1337/install_caddy_emby](https://github.com/AiLi1337/install_caddy_emby) 升级的 V6 版本。

主要改进：

- 一个域名可以添加任意数量的后端地址（受服务器资源和 Caddy 配置容量限制，不设脚本数量上限）
- 多后端支持主备故障切换、客户端 IP 粘滞和轮询三种模式
- 默认推荐主备模式：始终使用第一个健康后端，避免独立 Emby 之间登录令牌不兼容
- 后端连续失败时自动临时摘除，并尝试其他可用后端
- 支持添加新域名，或更新已有域名的全部后端
- 写入前执行 Caddy 格式化和配置验证
- 新配置导致启动失败时自动恢复上一份配置
- 自动检查并修复缺失的 `caddy.service`
- 启动失败时直接显示 systemd 日志和 80/443 端口占用，不再只显示“启动失败”
- 端口清理同时处理 80/TCP、443/TCP 和 HTTP/3 使用的 443/UDP
- 防止 nginx systemd 服务自动重启；若由 Docker/面板拉起，会显示进程和 cgroup 来源
- 支持 HTTP、HTTPS、IPv4、域名和带方括号的 IPv6 后端

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Yamada-anna1/install_caddy_emby/main/install_caddy_emby.sh)
```

首次运行后可以直接输入以下命令重新打开菜单：

```bash
c
```

## 添加多个后端

在菜单选择 `2`，输入域名后逐个添加后端：

```text
后端 #1（留空默认 127.0.0.1:8096）: 10.0.0.11:8096
后端 #2（留空结束）: 10.0.0.12:8096
后端 #3（留空结束）: 10.0.0.13:8096
后端 #4（留空结束）:
```

脚本会生成类似配置：

```caddyfile
emby.example.com {
    encode zstd gzip
    header Access-Control-Allow-Origin *

    reverse_proxy 10.0.0.11:8096 10.0.0.12:8096 10.0.0.13:8096 {
        lb_policy first
        lb_try_duration 5s
        lb_try_interval 250ms
        fail_duration 30s
        max_fails 2
        unhealthy_status 5xx
        header_up X-Real-IP {remote_host}
    }
}
```

## 注意事项

- 同一个域名下的后端必须全部使用 HTTP，或全部使用 HTTPS，不能混用。
- 修改负载模式后，客户端若缓存了旧登录令牌，请退出登录或删除该服务器后重新添加一次。
- 多个完全独立的 Emby 后端通常不共享登录令牌。此时应选主备模式；轮询模式只适合共享用户数据库和状态的集群。
- HTTPS 后端请明确写成 `https://主机名:端口`。
- 多后端用于负载均衡和故障切换。Emby 用户数据、媒体库和播放状态是否一致，仍取决于各后端自身的部署方式。
- 使用前请确保域名已解析到运行 Caddy 的服务器，并开放 TCP 80/443 端口。

## 来源说明

本项目保留原作者和原项目链接。原项目未附带许可证；请在使用、分发或二次修改时遵守原项目作者的授权要求。
