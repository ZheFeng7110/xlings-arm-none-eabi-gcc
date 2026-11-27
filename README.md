# xlings-arm-none-eabi-gcc

从源码构建裸机 Arm 工具链（`arm-none-eabi-gcc`、newlib、picolibc、libstdc++），
并把构建产物打包成 [xlings](https://github.com/openxlings/xlings) 可安装的 xim 包。

- `fromsource/` —— fromsource 索引（配方即构建脚本）：`xlings install fromsource:<pkg>`
- `tools/fromsource.sh` —— 用固定版本的 xlings 构建 fromsource 包，检查、规范化并打包成
  xlings-res 形态的 payload（`.tar.gz` + `.sha256` + `README.provenance`）
- `tools/checks/<pkg>.sh` —— 各包的出厂检查
- `xim/pkgs/` —— 指向本仓库 Release 的 xim 配方
- `.github/workflows/build.yml` —— CI 构建与发布

设计记录：
[编译器与打包流水线](.agents/docs/2026-11-18-fromsource-to-xim-design.md)、
[newlib 与 libstdc++](.agents/docs/2026-11-26-newlib-libstdcxx-design.md)。

## 包

| 包 | 内容 | payload |
|---|---|---|
| `arm-none-eabi-gcc@14.2.0` | GCC 14.2.0（C、C++）+ binutils 2.43.1，不含 C 库（只有 libgcc），29 个 rmprofile multilib | 每个宿主一个 |
| `newlib-arm-none-eabi@4.5.0.20241231` | newlib + newlib-nano 的 sysroot，Arm GNU Toolchain 的文件名（`nano.specs`、`nosys.specs`、`rdimon.specs`） | 一个，四个平台通用 |
| `libstdcxx-newlib-arm-none-eabi@14.2.0` | 上面的 newlib sysroot，加上 libstdc++ / libsupc++（完整版 + `_nano`） | 一个，四个平台通用 |

C 库与 libstdc++ 是 sysroot，用 `--sysroot` 选择（需要编译器 14.2.0 revision 1 及以后）：

```bash
# C
arm-none-eabi-gcc --sysroot=<newlib-arm-none-eabi>/arm-none-eabi \
    -mcpu=cortex-m4 -mthumb -mfpu=fpv4-sp-d16 -mfloat-abi=hard --specs=nano.specs --specs=nosys.specs ...
# C 与 C++
arm-none-eabi-g++ --sysroot=<libstdcxx-newlib-arm-none-eabi>/arm-none-eabi ...
```

文件名、configure 与 Arm GNU Toolchain 一致，但不追求完全对齐：例如 `std::filesystem` 在项目提供 `mkdir`、`getcwd` 等
POSIX 函数（如接在 FatFs、littlefs 上）时可以真正使用，Arm 的 libstdc++ 则一律返回 “Function not implemented”。
差异详见[设计记录 3.9 节](.agents/docs/2026-11-26-newlib-libstdcxx-design.md)。

已知限制：Windows payload 目前不能逐字节复现（同一 commit 两次构建有 3 个文件不同，不影响安装内容与生成的代码），
详见设计记录 8.4 节。

## 本地构建

```bash
# 有 docker：在固定的 Debian 镜像中构建
tools/fromsource.sh arm-none-eabi-gcc 14.2.0 out

# 已发布版本的重建（修订）：payload 名带 -r1
tools/fromsource.sh --revision 1 arm-none-eabi-gcc 14.2.0 out

# 目标代码（C 库、libstdc++）：一个与宿主无关的 payload；检查会用 xlings 安装 xim:qemu-arm
tools/fromsource.sh --data newlib-arm-none-eabi 4.5.0.20241231 out
tools/fromsource.sh --data libstdcxx-newlib-arm-none-eabi 14.2.0 out

# 没有 docker：在本机构建（需要 m4、perl、tar、bzip2、xz、wget）
FROMSOURCE_MODE=host FROMSOURCE_HOST_TOOLS=<含 m4/bzip2/xz 的目录> \
    tools/fromsource.sh arm-none-eabi-gcc 14.2.0 out

# Windows（x86_64）：在 x86_64 Linux 上交叉构建 fromsource:arm-none-eabi-gcc-mingw-cross，
# 产物为 .zip（另需 zip）；检查在 Windows 上运行（CI 的 check job）
tools/fromsource.sh --host windows arm-none-eabi-gcc 14.2.0 out

# macOS（Apple Silicon）：在 Mac 上用 Xcode 的 clang 构建（需要 Xcode 命令行工具与 GNU tar：brew install gnu-tar）
FROMSOURCE_WORK=/Users/Shared/fromsource-w tools/fromsource.sh arm-none-eabi-gcc 14.2.0 out
```

| 平台 | 构建方式 | payload |
|---|---|---|
| Linux x86_64 / aarch64 | 固定的 Debian 容器，xim:gcc + xim:glibc | `<name>-<ver>-linux-<arch>.tar.gz` |
| Windows x86_64 | 同一容器内用 xim:mingw-cross-gcc 交叉构建（Canadian cross）；libgcc 取自 Linux 构建 | `<name>-<ver>-windows-x86_64.zip` |
| macOS aarch64 | Apple Silicon runner，Xcode clang，`MACOSX_DEPLOYMENT_TARGET=11.0` | `<name>-<ver>-macosx-aarch64.tar.gz` |

## 直接作为 fromsource 索引使用

```bash
xlings config --index-repo fromsource:/path/to/xlings-arm-none-eabi-gcc/fromsource
xlings update
xlings install fromsource:arm-none-eabi-gcc@14.2.0
```
