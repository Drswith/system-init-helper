# system-init-helper

Ubuntu 一键初始化脚本，自动配置国内镜像源和常用开发环境。

## 功能

- **Ubuntu 镜像源** — 阿里云镜像加速 apt
- **Zsh + Oh-My-Zsh** — 从 Gitee 镜像安装，设为默认 Shell
- **fnm + Node.js LTS** — Node 版本管理 + npmmirror 镜像
- **Bun** — Bun 运行时（gh-proxy 加速下载）
- **Python 3 + pip** — 阿里云 PyPI 镜像
- **开发工具** — ripgrep, fd, fzf, bat, eza, tldr, jq 等

## 一键安装

```bash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/Drswith/system-init-helper/main/init.sh | sudo bash
```

如果 gh-proxy 不可用，可以直接用 GitHub 源：

```bash
curl -fsSL https://raw.githubusercontent.com/Drswith/system-init-helper/main/init.sh | sudo bash
```
