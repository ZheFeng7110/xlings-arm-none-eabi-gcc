# xlings-arm-none-eabi-gcc

从源码构建裸机 Arm 工具链（`arm-none-eabi-gcc`、newlib、picolibc、libstdc++），
并把构建产物打包成 [xlings](https://github.com/openxlings/xlings) 可安装的 xim 包。

- `fromsource/` —— fromsource 索引（配方即构建脚本）：`xlings install fromsource:<pkg>`
- `tools/fromsource.sh` —— 用固定版本的 xlings 构建 fromsource 包，检查、规范化并打包成
  xlings-res 形态的 payload（`.tar.gz` + `.sha256` + `README.provenance`）
- `tools/checks/<pkg>.sh` —— 各包的出厂检查
- `xim/pkgs/` —— 指向本仓库 Release 的 xim 配方
- `.github/workflows/build.yml` —— CI 构建与发布

设计记录见 [.agents/docs/2026-11-18-fromsource-to-xim-design.md](.agents/docs/2026-11-18-fromsource-to-xim-design.md)。

## 本地构建

```bash
# 有 docker：在固定的 Debian 镜像中构建
tools/fromsource.sh arm-none-eabi-gcc 14.2.0 out

# 没有 docker：在本机构建（需要 m4、perl、tar、bzip2、xz、wget）
FROMSOURCE_MODE=host FROMSOURCE_HOST_TOOLS=<含 m4/bzip2/xz 的目录> \
    tools/fromsource.sh arm-none-eabi-gcc 14.2.0 out
```

## 直接作为 fromsource 索引使用

```bash
xlings config --index-repo fromsource:/path/to/xlings-arm-none-eabi-gcc/fromsource
xlings update
xlings install fromsource:arm-none-eabi-gcc@14.2.0
```
