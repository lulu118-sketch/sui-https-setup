# S-UI HTTPS 一键配置工具

用于已安装的 S-UI 服务，为 **面板和订阅服务** 配置 HTTPS 证书。脚本会优先复用 `/root/.acme.sh` 中与输入域名匹配且有效的证书；找不到时尝试通过 acme.sh / Let's Encrypt 签发证书。

> 本项目不会安装 S-UI，也不会主动修改 Reality 入站。运行前请先备份 VPS，并确认域名和端口条件符合要求。

## Debian 13 / Ubuntu 一键运行


```bash
 bash <(curl -fsSL https://raw.githubusercontent.com/lulu118-sketch/sui-https-setup/main/sui-ssl-setup.sh)
```

也可以先下载再运行：

```bash
curl -fL -o sui-ssl-setup.sh https://raw.githubusercontent.com/lulu118-sketch/sui-https-setup/main/sui-ssl-setup.sh
chmod +x sui-ssl-setup.sh
sudo bash ./sui-ssl-setup.sh
```

## 运行前检查

1. 服务器已经安装并运行 S-UI；本工具不会替你安装 S-UI。
2. 将面板域名的 DNS A 记录指向此 VPS；如果使用 AAAA 记录，也请确认 IPv6 指向正确。
3. 首次签发使用 ACME standalone 验证，公网 TCP 80 端口必须可访问，且签发时不能被其他服务占用。
4. 运行账户需要 root 权限。
5. 请提前确认云厂商安全组和系统防火墙规则。配置完成后，面板端口和订阅端口仍须按需放行。

## 脚本行为

- 检查已安装的 S-UI。
- 按系统包管理器安装缺少的依赖。
- 自动搜索常见 S-UI 数据目录中的 SQLite 数据库，并检查 `settings` 表结构。
- 在修改数据库前创建带时间戳的备份文件。
- 检查证书域名、有效期和证书/私钥是否匹配。
- 将面板和订阅的域名、证书路径写入对应设置项。
- 安装证书续期部署钩子，并尝试重启 S-UI。
- 输出面板地址、订阅地址、证书路径和数据库备份路径。

## 软件包名称说明

Debian 13 / Ubuntu 的 SQLite 命令行客户端软件包名为 **`sqlite3`**，不能使用 `sqlite` 作为 Debian 安装包名。脚本在检测到 APT 时安装 `sqlite3`；其他支持的包管理器使用对应的软件包名称，并以 `sqlite3` 命令是否可用作为最终检查。

## 支持范围与注意事项

- 优先面向 Debian 12/13、Ubuntu 等使用 APT 的系统；其他系统能否运行取决于包管理器、systemd、S-UI 数据库布局及 acme.sh 的兼容性。
- 脚本需要使用 `curl`、`openssl`、`sqlite3`、`socat` 等工具。
- 脚本会修改 S-UI 数据库中的 `webDomain`、`webCertFile`、`webKeyFile`、`subDomain`、`subCertFile`、`subKeyFile` 六项设置，并在修改前备份数据库。
- 请先审阅脚本再以 root 身份运行。不要从不可信的 fork 或未经核验的 URL 执行远程脚本。
- 若服务重启失败，请检查：`journalctl -u s-ui --no-pager -n 100`。
- 自动续期是否成功还取决于 acme.sh 的计划任务/调度器是否正常运行。

## 故障排查

### Debian 提示找不到 sqlite 软件包

更新到本仓库最新脚本。APT 分支必须安装 `sqlite3`：

```bash
apt-get update
apt-get install -y sqlite3
sqlite3 --version
```

### 证书签发失败

检查 DNS 解析是否指向本机、TCP 80 是否可从公网访问，以及端口是否被占用。若端口 80 正被 Nginx 等服务使用，先评估现有服务影响，再安排签发；不要盲目停止生产服务。

### S-UI 重启失败

查看 `journalctl -u s-ui --no-pager -n 100`，并使用脚本输出的数据库备份文件恢复前先核对数据库路径与服务状态。

## License

MIT，详见 [LICENSE](LICENSE)。
