# arm-none-eabi 工具链：fromsource 构建 → 打包 → xlings-res → xim 设计记录

> 日期：2026-11-17 ~ 2026-11-18
> 背景：[openxlings/xim-pkgindex#1174](https://github.com/openxlings/xim-pkgindex/pull/1174)
> （arm-none-eabi-gcc 14.2.0 + newlib-arm-none-eabi，拆包设计）。维护者在该 PR 中建议
> “先自建仓库，放可复现的打包脚本，资源放 release，后面可以转移仓库”，本仓库即为此而建。

## 1. 目标

- 在本仓库内完成从源码构建 `arm-none-eabi-gcc`（含 binutils）、`newlib`、`picolibc`、
  `libstdc++` 的全部设施。
- 构建方式先适配 xlings 的 **fromsource** 索引（配方即构建的唯一事实来源），再把
  fromsource 包的构建产物打包，写成 xim 包描述供 `xlings install` 安装。
- 包拆分沿用 #1174 的设计：编译器、C 库、libstdc++ 各自独立成包，用户可以只装编译器，
  或选择编译器 + newlib / picolibc 的组合。

## 2. 调查结论

### 2.1 fromsource 是什么、怎么用

- 独立子索引仓库 `openxlings/xim-pkgindex-fromsource`。**已不在主索引的默认子索引列表中**
  （主索引 `xim-indexrepos.lua` 只有 awesome / scode / d2x；xlings `src/core/xim/repo.cppm`
  注释也提到 fromsource 已被移出），需手动添加：

  ```bash
  xlings config --index-repo fromsource:https://github.com/openxlings/xim-pkgindex-fromsource.git
  xlings update
  xlings install fromsource:gcc@16.1.0
  ```

  本地目录也可以作为索引（`name:/path/to/index`），这是本仓库测试配方的方式。
- 配方形态：`spec = "1"`、`namespace = "fromsource"`，`url` 指向上游源码 tarball；xlings
  下载并解压到 runtimedir 后调用 `install()`，在其中 configure / make 到
  `pkginfo.install_dir()`，即 `xpkgs/fromsource-x-<name>/<ver>`。
- hook 沙箱限制（见 fromsource `gcc.lua` 注释）：`os.cd` 不传给子进程、`os.cpuinfo` 与
  `path.absolute` 为 nil → 所有步骤放进同一个 `sh -c`（或写成脚本文件再执行）；
  `io.readfile` / `io.writefile` 可用；hook 内可联网（`download_prerequisites` 能工作）。
- 依赖：`deps = { runtime = {…}, build = {…} }`；裸名指**同一索引**内的包；构建依赖路径
  可通过 `pkginfo.build_dep("x").path` 或环境变量 `XLINGS_BUILDDEP_X_PATH` 获得
  （libxpkg `pkginfo.lua`）。因此 newlib 配方可以直接拿到 fromsource gcc 的前缀。
- 仓库规范（fromsource AGENTS.md + tests）：依赖必须带版本 `name@ver`；不得直接设置
  `LD_LIBRARY_PATH`；必须有 `install` / `uninstall`；使用 `xvm.add` 新 API；CI 只跑
  L0–L2 静态检查，不做真实构建。
- 既有的 fromsource → xim 路径：`xpkg-helper <ns:pkg@ver> --export-path <dir>` 把 xpkgs
  目录原样拷出（`linux-sysroot-create` 即如此使用 fromsource:glibc）。主索引 zlib /
  freetype / glibc 的注释表明早期 xlings-res 资源就是 fromsource 产物，但**泄漏了构建机
  路径**（`.pc` 中的 `prefix=/home/...`、RUNPATH），后来只能重建或在安装时重定位
  ——导出时必须做规范化。

### 2.2 上游 res-build 现状

- `tools/res/build.sh <what> <version> <out>`：每种资源一段专门的 shell，在固定 digest 的
  Debian / Alpine 容器中构建并做出厂检查，产出 `<name>-<ver>-linux-<arch>.tar.gz`
  （目标代码/数据为 `<name>-<ver>.tar.gz`）+ `.sha256`，payload 内含 `README.provenance`。
- `.github/workflows/res-build.yml`：构建（无密钥，产出 artifact
  `res-<what>-<version>-<arch>`）与发布（`publish_runs=<run ids>`，受保护环境
  `xlings-res-publish`，`tools/res/publish.py` 只新增、不覆盖资产）分离。
- 其中 `gcc` 条目已是“容器内装 xlings → 用 xlings 装 glibc + linux-headers 做 sysroot →
  按 fromsource:gcc 的 configure 构建”，但 configure 是手抄的。
- `build.sh` 注释原文：“that the factory itself is built from the index (self-hosting) is
  the direction, not yet the state.”

### 2.3 平台约束

| | x86_64 | aarch64 |
|---|---|---|
| xim 上可用的引导 gcc | 15.1.0 / 16.x | 仅 16.x |
| xim 上的 glibc | 2.39 起 | 仅 2.44.3 |
| xim 上的 meson | 有 | 无 |

- aarch64 的 fromsource 编译器产物 glibc 下限为 2.44（#1174 用 Debian 12 构建时为 2.36）。
- newlib / picolibc / libstdc++ 是目标代码，只在 x86_64 上构建一次，不受影响。

## 3. 方案

### 3.1 流水线

```
fromsource 配方（本仓库 fromsource/pkgs）
   │  固定容器 + 固定 xlings 版本 + 全新 XLINGS_HOME，本仓库 fromsource/ 作为本地索引
   ▼
xlings install -y fromsource:arm-none-eabi-gcc@14.2.0 ...
   ▼
tools/fromsource.sh：导出 → 规范化 → 通用检查 → 包专属检查 → 可复现打包 + .sha256 + provenance
   ▼
本仓库 GitHub Release（后续转移到 xlings-res）
   ▼
xim 配方（xim/pkgs，用于更新 #1174）→ xlings install arm-none-eabi-gcc
```

### 3.2 仓库布局

```
fromsource/pkgs/a/arm-none-eabi-binutils.lua
fromsource/pkgs/a/arm-none-eabi-gcc.lua
fromsource/pkgs/n/newlib-arm-none-eabi.lua            (后续)
fromsource/pkgs/p/picolibc-arm-none-eabi.lua          (后续)
fromsource/pkgs/l/libstdcxx-newlib-arm-none-eabi.lua  (后续)
fromsource/pkgs/l/libstdcxx-picolibc-arm-none-eabi.lua(后续)
xim/pkgs/...                    # 二进制包的 xim 配方
tools/fromsource.sh             # 通用：fromsource 包 → xlings-res 形态的 payload
tools/checks/<name>.sh          # 包专属出厂检查
.github/workflows/build.yml
```

`fromsource/` 本身是一个合规的索引目录，可整体贡献给 `xim-pkgindex-fromsource`。

### 3.3 fromsource 包拆分

| 包 | url（xlings 校验 sha256） | 构建依赖 | 产物 |
|---|---|---|---|
| `arm-none-eabi-binutils@2.43.1` | binutils tarball | xim:gcc、glibc、make | binutils |
| `arm-none-eabi-gcc@14.2.0` | gcc tarball | 上面的 binutils、xim:gcc、glibc、make | 编译器 + binutils（仅 libgcc） |
| `newlib-arm-none-eabi@4.5.0.20241231` | newlib tarball | gcc | newlib + nano（Arm 命名） |
| `picolibc-arm-none-eabi@1.8.x` | picolibc tarball | gcc、meson、ninja | picolibc sysroot |
| `libstdcxx-newlib-arm-none-eabi@14.2.0` | gcc tarball | gcc、newlib | libstdc++/libsupc++（完整 + `_nano`） |
| `libstdcxx-picolibc-arm-none-eabi@14.2.0` | gcc tarball | gcc、picolibc | 同上 |

要点：

- binutils 单独成包：一个配方只有一个 `url`，拆开后每份源码都被 xlings 校验 sha256；
  gcc 的 `install()` 先把 binutils 目录树复制进自己的前缀再 configure，使编译器产物与
  #1174 一样自包含（`<prefix>/arm-none-eabi/bin/as` 相对可寻）。
- configure 照搬 #1174 的 `gcc.sh` / `newlib.sh`，另外：主机侧程序静态链接 libstdc++
  （NEEDED 只剩 glibc）；补 `limits.h`——`--without-headers` 时 gcc 生成的 `limits.h`
  不会 `#include_next` C 库的 `limits.h`（`PATH_MAX` 等缺失），按 LFS 的做法用
  `limitx.h + glimits.h + limity.h` 重新生成。
- 构建脚本内联在配方里（Lua 长字符串写到 runtimedir 再 `bash` 执行），配方自包含；
  需要 qemu 等重依赖的验收检查不放进配方，由 `tools/checks/` 在 CI 中执行。
- libstdc++：用同一组 configure 加 `--with-build-sysroot=<libc>` 重建
  `all-gcc all-target-libgcc all-target-libstdc++-v3`，只收取 libstdc++ 部分；nano 版
  参照 Arm `build-toolchain.sh` 再构建一遍并改名为 `_nano.a`。

### 3.4 导出（tools/fromsource.sh）

1. 定位 `$XLINGS_HOME/data/xpkgs/fromsource-x-<name>/<ver>`。
2. 规范化：重置 ELF 的 INTERP 为系统默认 loader、删除 RUNPATH（安装时由 xim 的 elfpatch
   接到 xim:glibc）；strip；删除 `*.la`、`share/info`、`share/man`；扫描文本文件中残留的
   构建机路径；检查 NEEDED 白名单；不得有硬链接。
3. 运行包专属检查 `tools/checks/<name>.sh`（版本、sysroot 可重定位、rmprofile multilib、
   freestanding 链接；库包：每个 multilib 齐全、CubeMX 式链接、hard ≠ softfp、qemu mps2）。
4. 可复现打包（`--sort=name --mtime=@0 --owner=0`），生成 `.sha256` 与
   `README.provenance`（xlings 版本、配方 commit、源码 sha256、依赖版本）。

### 3.5 CI 与发布

- x86_64 一个 job 依次构建 gcc → newlib → picolibc → libstdcxx×2；aarch64 一个 job 只构建
  gcc。
- Release tag 为 `<name>-<version>`（如 `arm-none-eabi-gcc-14.2.0`），资产
  `arm-none-eabi-gcc-14.2.0-linux-x86_64.tar.gz`。转移到 `xlings-res/<name>` 时 tag 为
  `<version>`，字节不变 → sha256 不变，xim 配方只改 url。
- 已发布资产不可变；重建用 `-r1` 等 revision。

### 3.6 xim 配方

基本即 #1174 的两个文件，把 PENDING 换成本仓库 Release 地址：

```lua
["14.2.0"] = {
    url = "https://github.com/ZheFeng7110/xlings-arm-none-eabi-gcc/releases/download/arm-none-eabi-gcc-14.2.0/arm-none-eabi-gcc-14.2.0-linux-${arch}.tar.gz",
    sha256 = { x86_64 = "...", aarch64 = "..." },
},
```

用 `xlings config --add-xpkg` 在本地测试；转移到 xlings-res 前没有 CN（gitcode）镜像。

## 4. 把“fromsource → xlings-res → xim”做成通用 GitHub Action 的可行性

### 4.1 结论

可行，且与上游方向一致，但目标需修正：

- 能做到：**构建逻辑**移出 xim 仓库——不再为每个包在 `build.sh` 写专门的 shell，配方统一
  在 fromsource。
- 不建议：让 xim 仓库完全不跑构建（在 fork / 独立仓库构建后直接发布到 xlings-res），信任链
  上基本过不去。

推荐形态：一个通用的“fromsource 产物导出”工具（`tools/fromsource.sh` + reusable
workflow），并给上游 res-build 增加通用的 `fromsource:*` 分支。任何人都能在自己的仓库预构建、
验证；正式发布仍由 xim-pkgindex 的 res-build 重新构建，并走受保护的 publish 环境。

### 4.2 依据

1. `build.sh` 明确写着 self-hosting 是方向。
2. res-build 的 `gcc` 条目已是“容器内装 xlings 构建”的半成品；早期 zlib、freetype 就是
   fromsource 产物导出。
3. 构建与发布已分离，接口为 artifact `res-<what>-<version>-<arch>`（一个 payload + 一个
   `.sha256`）；新工具产出同样格式即可，**publish 一半无需改动**。
4. “一个 payload、一个 sha256、xim 配方引用它”与 fromsource 安装目录天然对应。

### 4.3 难点与对策

| 问题 | 说明 | 对策 |
|---|---|---|
| 产物带构建机信息 | INTERP / RUNPATH 指向 subos，`.pc` / `.la` 含 `prefix=/home/...` | 导出时通用规范化，包特有处理留钩子 |
| 信任链 | publish 用 `gh run download -R $GITHUB_REPOSITORY`，只认 xim-pkgindex 自己的 run | 第三方仓库只做预构建/验证；正式产物由上游重建；可复现打包 + provenance 使两边 sha256 对得上 |
| 可复现性 | 直接在 runner 上跑会混用宿主的 m4 / perl / python / texinfo | 固定 digest 容器 + 固定 xlings 版本 + 固定 fromsource 索引 commit（本地路径索引） |
| 包专属验收 | 通用流程替代不了每个包的检查 | 通用检查进工具；包专属检查用 fromsource 测试框架的 L4 `verify` 或 `tools/checks/<name>.sh` |
| fromsource 配方质量 | 粗略统计 45 个配方中 44 个至少有一个版本没有 sha256；全部只声明 x86_64；上游已移出默认子索引 | 设准入：有 sha256、依赖写死版本、有 verify；aarch64 依赖在 Lua 里按架构分支 |
| 依赖连带构建 | `xlings install fromsource:X` 会把 fromsource 依赖也从源码构建 | 尽量依赖 xim 预编译包；CI 缓存；算进 6 小时限制 |
| 名字/版本映射 | fromsource 包名不一定等于 xlings-res 仓库名；目标代码需打成无架构的 data 形式 | matrix 条目显式写 `what: "fromsource:<name>"`、`kind: data`、`res_name` |
| glibc 下限 | 由 xim 的 glibc 决定（x86_64 2.39，aarch64 2.44） | 写进 provenance；xim 配方 `deps.runtime` 用 `xim:glibc@>=…` |

### 4.4 落地形态

```
openxlings/xim-pkgindex
  .github/res-build-matrix.json
     { "what": "fromsource:arm-none-eabi-gcc", "version": "14.2.0", "arch": "x86_64" }
  tools/res/build.sh
     fromsource:*) → tools/res/fromsource.sh     # 新增的通用分支
  publish 不变
```

本仓库：以 reusable workflow 调用同一个 `fromsource.sh` 预构建、迭代 arm-none-eabi 配方；
先用本仓库 Release 自托管；稳定后配方贡献给 `xim-pkgindex-fromsource`，`fromsource.sh` 贡献给
xim-pkgindex，由上游 res-build 重建并发布到 xlings-res，xim 配方切换到
`source = "xlings-res"`。

### 4.5 需与上游确认

1. 是否接受“res-build 调用 fromsource 配方”，以及把 fromsource 索引 commit 作为构建输入
   （类似 `inputs.txt`）。
2. 是否接受第三方仓库的 run 直接发布（预计不接受，以上游重建为准）。
3. fromsource 配方进入 res-build 的准入标准。

## 5. 风险与待验证项

1. 本地路径索引的命名空间 / 安装目录名是否为 `fromsource-x-…`；hook 内能否联网。
2. aarch64 glibc 下限 2.44 是否可接受（否则 aarch64 只能继续用 Debian 构建）。
3. 编译器与 C 库分包后需要 `--sysroot`；让 CubeMX 命令无参数可用需要组合包或包装脚本
   （gcc 会解析符号链接，单纯符号链接合并不可行；xvm alias 能否带参数待确认）。
4. picolibc 的 specs 是否可重定位（`-Dsysroot-install=true` 生成的路径是否相对 sysroot）。
5. libstdc++ 需重建 gcc，时间约翻倍；需校验其 multilib 与单独发布的编译器完全一致。
6. 版本线：先 14.2.0，再维护者提到的 15.x；默认用 GNU 上游源码，Arm 源码快照
   （15.3.rel2）可作为单独变体。

## 6. 实施顺序

1. 用临时 `XLINGS_HOME` 验证第 5 节第 1 项。
2. 写 binutils + gcc 的 fromsource 配方，本地 x86_64 构建通过。
3. 写 `tools/fromsource.sh` 与检查，对比 #1174 fork 构建的产物（multilib、sysroot、host ELF）。
4. 接 CI，发布第一个 Release，更新 #1174 的 gcc 配方。
5. newlib → picolibc → libstdcxx×2。
6. 配方贡献给 `xim-pkgindex-fromsource`，`fromsource.sh` 贡献给 xim-pkgindex，资源转移到
   xlings-res。

## 7. 实施记录（2026-11-18，第一轮：fromsource.sh + arm-none-eabi-gcc）

### 7.1 已验证的事实（隔离的 `XLINGS_HOME`，xlings 2026.11.16.1，x86_64 宿主模式）

- 本地路径索引以 `fromsource` 名称加入后，安装目录为 `xpkgs/fromsource-x-<name>/<ver>`；
  hook 内可以联网；hook 的工作目录是 `data/runtimedir`，**所有包共用**，构建目录必须按包名区分。
- 构建依赖注入 `XLINGS_BUILDDEP_<NAME>_PATH`，其 `bin` 加到 PATH 前面；裸名依赖
  （`arm-none-eabi-binutils@2.43.1`）解析到同一索引。
- hook 继承调用者的环境（PATH、`XLINGS_*`），宿主模式必须 `env -i` 清理，否则会用到外部的 gcc。
- **运行时 glibc 由环境统一决定**：构建依赖写 `xim:glibc@2.39` 也会被改为 `glibc@2.44.3`。
  因此两种架构的基线一致（2.44.3），2.3 节中 aarch64 的“例外”不复存在；实测产物的 glibc
  符号版本最高为 2.38。
- 作为构建依赖直接调用 xim:gcc 时，它的 sysroot 是工厂写死的 `/w/xh/subos/current`，找不到
  `stdio.h`；binutils 也不在 PATH 上。做法：把 `xim:glibc` + `xim:linux-headers` 声明为
  runtime 依赖（subos 因此成为完整的 sysroot），`CC="gcc --sysroot=$S"`，并把 `xim:binutils`
  加入构建依赖——与上游 res-build 的 gcc 条目一致。
- xlings 安装后会对依赖 glibc 的包**自动 elfpatch**（INTERP → `<home>/abi/linux-<arch>-glibc/...`，
  RPATH → payload/lib + abi 目录）；导出时把 INTERP 重置为系统 loader 并删掉 RPATH，再通过 xim
  配方安装时会被正确地重新绑定（已用本地 overlay 端到端验证）。
- xlings 下载只接受 HTTPS（`file://` 和本地路径都不行）；本地测试 xim 配方时，把 tarball 预先
  放进 `data/runtimedir`，sha256 匹配即可跳过下载。
- 宿主机需要 xlings 索引中没有的工具：m4（in-tree gmp）、bzip2（`download_prerequisites`）、
  xz、perl、wget。本机用 linuxbrew 装了 m4，并通过 `FROMSOURCE_HOST_TOOLS` 只暴露这几个工具。

### 7.2 构建结果

- `fromsource:arm-none-eabi-binutils@2.43.1`：约 36 秒（16 核）。
- `fromsource:arm-none-eabi-gcc@14.2.0`：约 8 分钟；全新 home 端到端（下载 xlings、依赖、构建
  binutils + gcc、检查、导出）约 10 分钟；payload 约 97 MB。
- 检查通过：版本、可重定位 sysroot、29 个 rmprofile multilib 且每个都有 libgcc.a、典型 CPU 的
  multilib 选择、无 C 库/libstdc++、freestanding C 链接（`__aeabi_idiv`）、freestanding C++20、
  hard-float 的 VFP 寄存器 ABI；宿主 ELF 只依赖 glibc。

### 7.3 发现并修复的问题

| 问题 | 修复 |
|---|---|
| `.xlings-resolution.json` 被写进安装目录 | 导出时通用删除 |
| binutils 的 ldscripts 里 `SEARCH_DIR("=<prefix>/arm-none-eabi/lib")` 写死了构建路径 | binutils 配方删除该项（与已有的 `=/lib` 等价，sysroot 就是 `<prefix>/arm-none-eabi`） |
| gcc 的 `install-tools/`、`plugin/` 记录了 configure 参数和路径 | gcc 配方删除（不支持开发 GCC 插件） |
| libgcc 自带 `-g`（`LIBGCC2_DEBUG_CFLAGS`），调试信息记录了源码/构建目录 | `CFLAGS_FOR_TARGET` 加 `-ffile-prefix-map=<runtimedir>=/xlings-build` |
| 泄漏规则过松（二进制里的路径只计数） | 只有宿主 ELF 允许包含构建 home（配置前缀，运行时重定位）；文本与目标代码出现即失败 |
| 两次构建字节不同：宿主程序内嵌配置前缀，cc1/cc1plus 还有覆盖自身目标文件的 checksum | 构建目录固定（容器内 `/w`，宿主模式 `FROMSOURCE_WORK`） |
| 固定目录后 cc1/cc1plus 仍不同：它们内嵌的 checksum 覆盖了宿主静态库（libbackend.a、libcody.a 等），而 xim:binutils 的 `ar` 默认记录时间戳与 uid | gcc 配方用包装脚本给宿主 `ar` / `ranlib` 的写操作加 `D`（包括 libcody 的 `ar -cr` 写法） |
| 下载 xlings 时偶发 TLS 错误，`curl --retry` 默认不重试 | 加 `--retry-all-errors` |
| CI 产物里出现 xlings 的安装元数据 `.xpkg-install.json`（payload stamp）和 `.xpkg.lua`（配方快照）——会把 fromsource 的安装状态带给 xim 包的安装者 | 导出时删除安装目录顶层所有 `.xpkg*` / `.xlings*` |

**结果：两次全新构建（宿主模式、相同 `FROMSOURCE_WORK`）得到逐字节相同的 payload**（sha256 `97ad94b6…`）。

教训：bash 边执行边读脚本，**不要在脚本运行时修改它**。

### 7.4 尚未完成

- `limits.h` 问题（2.3 节）留到 newlib 阶段处理：直接拼接 `limitx.h + glimits.h + limity.h` 会让
  没有 C 库时 `#include <limits.h>` 失败（`include_next` 找不到），需要带 `__has_include_next`
  保护的写法，并用 newlib 验证。
- 容器模式（`docker`）与 aarch64 尚未在本地运行，由 CI 首次验证。
- xim 配方的 sha256 待 CI 构建并发布后填写（宿主模式与容器模式的字节不同，不能用本地构建的值）。

### 7.5 CI 首次运行（2026-11-19，run 44446406293，commit 344441a）

- lint、x86_64、aarch64 全部通过：**容器模式与 aarch64 首次验证即通过**（x86_64 约 30 分钟，aarch64 约 19 分钟）。
- 两个架构的宿主 ELF 都只依赖 glibc，符号版本最高 2.38；provenance 记录了干净的 commit 与固定的 Debian 镜像。
- 用 xim 配方（本地 overlay + 预置下载缓存）安装 CI 的 x86_64 产物：elfpatch 把 INTERP 绑到
  `<home>/abi/linux-x86_64-glibc`，sysroot 跟随安装目录，cortex-m0 freestanding 链接、cortex-m33 C++ 编译通过。
- 发现：产物顶层带着 xlings 的 `.xpkg-install.json` / `.xpkg.lua` / `.xlings-resolution.json`（本地宿主模式的
  构建也有，之前未注意）；已在导出时统一删除，该次 CI 产物因此不发布。
- 验证时注意：本机 PATH 中有 Arm 官方工具链（`~/local/arm-none-eabi`），测试 shim 时必须用
  `env -i ... /bin/bash --noprofile --norc`，否则会误测到它。

### 7.6 首次发布与可复现性核对（2026-11-19）

- run 44453953062（`release=false`）与 run 44456719656（`release=true`）都构建自 c0b8058，两次产物逐字节相同：
  x86_64 `b60eea24…`，aarch64 `9cd587d8…`，即 Release `arm-none-eabi-gcc-14.2.0` 上资产的 digest。
- Actions 页面上 artifact 的 digest 每次都不同，原因是那是 `actions/upload-artifact` 打的 **zip** 的哈希：
  zip 里记录了上传时的 mtime（04:09:32 与 04:36:40）。两个 zip 大小相同，解开后文件的 sha256 完全一致。
  **比较可复现性要看 payload 自身的 sha256（日志里的 `[fromsource] <sha256>` 行或 `.sha256` sidecar），
  不要看 artifact digest。**
- 关于“gcc 构建产物不保证逐字节可复现”：只在条件不受控时成立，并非 GCC 的固有性质。本项目中的变化来源都已
  消除（构建路径、宿主 `ar` 的时间戳、工具链与依赖版本）；本地 16 核与 CI 4 核的构建都可复现，说明并行度不影响结果。
  前提是输入相同：同一架构、固定的 `/w`、同一 Debian 镜像、同一 xlings 版本、同样版本的 xim 依赖。xim 依赖若
  发布了新 revision，产物就可能变化，届时需要按新版本 revision 重新发布。
- xim 配方已填入上述 sha256；在全新 home 中直接从 GitHub Release 下载安装（不再预置缓存）通过：shim、可重定位
  sysroot、cortex-m0 链接均正常；发布的 tarball 顶层不再含 `.xpkg*` / `.xlings*`。

## 8. Windows 与 macOS（2026-11-19）

### 8.1 方案

| 平台 | 在哪里构建 | 编译器 | 产物 |
|---|---|---|---|
| Windows x86_64 | x86_64 Linux（同一 Debian 容器） | xim:mingw-cross-gcc@16.1.0（Canadian cross：build=Linux，host=mingw，target=arm-none-eabi） | `<name>-<ver>-windows-x86_64.zip` |
| macOS aarch64 | Apple Silicon runner（`macos-15`，宿主模式） | Xcode clang + SDK，`MACOSX_DEPLOYMENT_TARGET=11.0` | `<name>-<ver>-macosx-aarch64.tar.gz` |

- 依据：xlings 只发布 `linux-*`、`macosx-arm64`、`windows-x86_64` 客户端；xim 在 macOS 上没有 gcc / make，
  在 Linux 上有 mingw-cross-gcc。在 Windows 上原生构建 GCC 需要 MSYS2 整套 POSIX 环境，慢且难复现；交叉构建
  也是 Arm 官方 Windows 工具链的做法。没有 Intel macOS（xlings 无该客户端）。
- Windows 是**单独的 fromsource 配方** `arm-none-eabi-binutils-mingw-cross` / `arm-none-eabi-gcc-mingw-cross`（仅
  `linux` 段，安装出的是给 Windows 用的 .exe 目录树，不注册 xvm）。`tools/fromsource.sh --host windows <name>`
  构建 `fromsource:<name>-mingw-cross`，产物仍以 `<name>` 命名。
  命名参照主索引的 `mingw-cross-gcc`（在 Linux 上运行、产出 Windows 程序）与 `mingw-gcc`（在 Windows 上运行）分成两个包；
  上游 fromsource 索引（`bec5139`）的 45 个配方都只有 `linux` 段、`archs = {"x86_64"}`，没有多平台或交叉构建的先例。
- Windows 版只构建编译器（`all-gcc`），**libgcc 从 Linux 构建（fromsource:arm-none-eabi-gcc）复制**：目标代码
  与宿主无关，三个平台的 libgcc 字节相同，multilib 集合一致。
- macOS 用同一份 `arm-none-eabi-binutils` / `arm-none-eabi-gcc` 配方的 `macosx` 段；构建脚本按 `uname -s` 分支
  （clang、无 `--with-static-standard-libraries`、`ZERO_AR_DATE=1` 代替 ar 包装、`sed -i.orig` 兼容 BSD sed）。
  in-tree gmp 由 GCC 以 `--host=none-…` 配置（纯 C），不受 Apple Silicon 上 x18 寄存器问题影响。
- 导出的规范化按宿主：Linux 同前；macOS 检查 Mach-O 只链接 `/usr/lib`、`/System/Library`，无 `LC_RPATH`，
  记录 minos；Windows 检查 PE 只导入系统 DLL，且 PE 头时间戳为 0。Windows 打包为可复现 zip
  （固定 mtime 与 `TZ=UTC0`，`-X -D`，排序）。
- 检查：macOS 在构建机上运行 `tools/checks/<name>.sh`；Windows 产物在 CI 的 `check` job（`windows-2022`，Git Bash）
  上解压后运行同一脚本（脚本去掉 Windows 程序输出的 CR，readelf 默认用 payload 自带的）。

### 8.2 本地验证（x86_64 宿主模式）与修复

| 问题 | 修复 |
|---|---|
| Canadian cross 时 `gcc/build.*` 子 configure 的测试程序不能运行：不使用 `LDFLAGS_FOR_BUILD`，且 SubOS 没有 libstdc++ | loader、rpath、`-static-libstdc++ -static-libgcc` 直接写进 `CC_FOR_BUILD` / `CXX_FOR_BUILD`；`LD_FOR_BUILD=ld LDFLAGS_FOR_BUILD=""`（否则默认取 mingw 的） |
| binutils 程序导入 `libwinpthread-1.dll` | libtool 会删掉任何位置的 `-static`；改为在 CC 中写 `--static`（GCC 视为同义，libtool 不识别而原样传递） |
| 所有 PE 都带构建时间：`install-strip` 时 strip 重写 PE 头 | `SOURCE_DATE_EPOCH=0`（ld 另有 `--no-insert-timestamp`） |
| （CI）容器里 mingw 编译器 “cannot create executables”：xim:mingw-cross-gcc 不声明 glibc 依赖、用宿主 glibc，需要 2.38 与 libzstd.so.1，Debian 12 只有 2.36 | Windows 交叉工厂改用固定 digest 的 Debian 13 镜像（glibc 2.41）；Linux payload 仍用 Debian 12（其 glibc 基线由 xim:glibc 决定，与镜像无关） |
| （CI）xim:gcc@16.2.0 发布了 revision 1，产生 `.base64` / `.aeabi_subsection`，固定的 xim:binutils@2.42.1 的 as 不认 | 构建依赖改为 xim:binutils@2.47 |
| （CI）macOS：binutils 自带 zlib 的 zutil.h 定义了 fdopen，与 Xcode 16.4 SDK 的声明冲突 | macOS 用 `--with-system-zlib`（/usr/lib/libz.dylib） |

结果：`fromsource:arm-none-eabi-gcc-mingw-cross@14.2.0` 构建通过，45 个 PE 程序只导入 KERNEL32 / msvcrt / ADVAPI32，
时间戳为 0；29 个 multilib 的 libgcc.a 齐全；zip 约 95 MB。新增 `FROMSOURCE_KEEP=1`：失败时保留构建目录以便查看 `config.log`。

### 8.3 尚未验证

- macOS 构建（本地无 Mac），由 CI 首次验证；Windows 产物在真实 Windows 上的检查由 CI `check` job 首次验证。
- macOS 产物的逐字节可复现性尚未用两次同一 commit 的构建核对。
- Windows 产物尚不可逐字节复现：见 8.4 已知限制 L1。
- 已发布（run 45107607496，b01941d）：Release `arm-none-eabi-gcc-14.2.0` 新增 `windows-x86_64.zip`（`90d12207…`）与 `macosx-aarch64.tar.gz`（`4d984923…`），
  Linux 资产保留首次发布的字节（新依赖下的重建字节不同，按设计不覆盖）。xim 配方已加 `windows` / `macosx` 段（`source` 改为按平台），
  在全新 home 中用该配方安装 Linux x86_64 版通过；Windows / macOS 上的 xim 安装尚未实测。

### 8.4 已知限制（2026-11-23）

**L1. Windows payload 不能逐字节复现**（暂不修复，之后处理）

- 现象：同一 commit（b01941d）的两次构建 run 45001482719 与 45107607496 得到 `0abc0dc3…` 与 `90d12207…`（后者已发布）。
  解压后只有 3 个文件不同：
  - `libexec/gcc/arm-none-eabi/14.2.0/liblto_plugin.dll.a`：5 字节，在 ar 成员头的 mtime 字段——ld `--out-implib` 写入当前时间。
  - `cc1.exe`、`cc1plus.exe`：各 18 字节——PE 头校验和（2 字节）与一段连续 16 字节，位置和长度与 cc1 内嵌的、覆盖其链接输入的
    MD5（executable checksum）相符。说明 mingw 交叉构建中仍有某个宿主侧链接输入不确定（Linux 上同类问题由 ar 包装解决），尚未定位。
- 对用户的影响（评估于 2026-11-23）：
  - 安装内容：无。xim 配方按 sha256 锁定已发布的那一份，所有用户得到相同字节。
  - 生成的固件：无。不同的字节不是机器码，也不写入用户的 `.o` / `.elf`（依据为字节比对；未在 Windows 上用两份 cc1 实际编译对照）。
  - 预编译头：该校验和用于校验 `.gch`。只有在不同修订的 Windows 资产之间共享 `.gch` 时才会被拒绝并回退到 `.h`（变慢，不出错）。
  - 独立验证：用户无法自行重建并比对 Windows 产物的字节（Linux 可以）。
- 修复方向：
  1. 从 payload 删除 `liblto_plugin.dll.a`（运行时不需要）。
  2. 复用同一个 xlings home（`FROMSOURCE_HOME`）连续构建两次 `arm-none-eabi-gcc-mingw-cross`（`FROMSOURCE_KEEP=1` 保留构建目录），
     比对两次构建树中参与 cc1 链接的 `.a` / `.o`，找出不确定的输入并在配方中消除。
  3. 修复后的构建作为 Windows 资产的新 revision 发布（已发布的资产不覆盖），并更新 xim 配方的 sha256。
