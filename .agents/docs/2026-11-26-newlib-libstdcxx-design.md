# arm-none-eabi：newlib 与 libstdc++（newlib）打包设计记录

> 日期：2026-11-26 起
> 前一轮：[2026-11-18-fromsource-to-xim-design.md](2026-11-18-fromsource-to-xim-design.md)（编译器 `arm-none-eabi-gcc@14.2.0`，
> 四个平台已发布）
> 背景：[openxlings/xim-pkgindex#1174](https://github.com/openxlings/xim-pkgindex/pull/1174) 的拆包设计——编译器、C 库、
> libstdc++ 各自成包。#1174 里已有 newlib 的构建脚本（`tools/res/arm-none-eabi/newlib.sh`）与 xim 配方，本轮把它们改写为
> 本仓库的 fromsource 配方，并补上 libstdc++。

## 1. 目标

- `fromsource:newlib-arm-none-eabi@4.5.0.20241231`：newlib + newlib-nano，覆盖编译器的全部 29 个 rmprofile multilib，
  文件名与 Arm GNU Toolchain 一致（`libc_nano.a`、`nano.specs`、`nosys.specs`、`rdimon.specs`）。
- `fromsource:libstdcxx-newlib-arm-none-eabi@14.2.0`：针对上面这份 newlib 构建的 libstdc++ / libsupc++（完整版 + `_nano`）。
- 两者都是目标代码：各打一个与宿主无关的 `--data` payload，在 x86_64 Linux 上构建一次，四个平台通用。
- 写出两者的 xim 配方；为此先发布编译器的修订版 `14.2.0-r1`（第 3.1 节）。
- 用户可选的组合：

  | 用途 | 安装 | 编译参数 |
  |---|---|---|
  | 只写 freestanding 代码 | `arm-none-eabi-gcc` | `-nostdlib … -lgcc` |
  | C | `arm-none-eabi-gcc` + `newlib-arm-none-eabi` | `--sysroot=<newlib>/arm-none-eabi` |
  | C / C++ | `arm-none-eabi-gcc` + `libstdcxx-newlib-arm-none-eabi` | `--sysroot=<libstdcxx-newlib>/arm-none-eabi` |

  选定 sysroot 后，STM32CubeMX 式的 `--specs=nano.specs --specs=nosys.specs` 无需改动即可链接。不带 `--sysroot` 也能用
  （“CubeMX 命令零参数”）不在本轮范围（见第 7 节）。

## 2. 调查结论

### 2.1 从 #1174 继承的内容

- newlib 的两组 configure 与 Arm 相同；sysroot 布局：`arm-none-eabi/include`（newlib 头文件）、
  `include/newlib-nano/newlib.h`（`nano.specs` 用 `-isystem =/include/newlib-nano` 把它放在最前）、
  `lib/<multilib>/{libc,libm,libg,libnosys,librdimon}.a crt0.o rdimon-crt0.o` 与 `{libc,libg,librdimon}_nano.a`。
- 检查：CubeMX 式链接三个 multilib 行（m0 nano、m3 完整版、m4 hard nano），用 `-Wl,-t` 确认链接的是哪一个归档——放错目录的库
  能正常链接，到运行时才出错；hard ≠ softfp（`Tag_ABI_VFP_args`）；`nano.specs` 选中 nano 的 `newlib.h`；在 qemu
  mps2-an385（Cortex-M3）与 mps2-an386（Cortex-M4 hard float）上用半主机运行 `printf` / `malloc` / float。
- 不同之处：#1174 用 Debian 的 build-essential 与已发布的编译器构建；这里按 fromsource 的方式，主机编译器来自 xim，
  目标编译器是同一索引里的 `fromsource:arm-none-eabi-gcc`（3.4 节）。

### 2.2 `limits.h`：只装编译器时没问题，一加 C 库就错（上一轮 7.4 遗留）

核对 gcc 14.2.0 源码（`gcc/Makefile.in` 的 `stmp-int-hdrs`）：

```
LIMITS_H_TEST = [ -f $(BUILD_SYSTEM_HEADER_DIR)/limits.h ]
if $(LIMITS_H_TEST); then cat limitx.h glimits.h limity.h > limits.h   # 末尾 #include_next C 库的 limits.h
else                       cat glimits.h > limits.h                     # 只有 C 标准的那几个宏
```

编译器以 `--without-headers` 构建，构建时 sysroot 里没有 `limits.h`，安装的 `lib/gcc/arm-none-eabi/14.2.0/include/limits.h`
就只有 `glimits.h`。而 GCC 的 include 目录排在 sysroot 之前，结果：

- 即使用 `--sysroot` 选了 newlib，`#include <limits.h>` 也看不到 newlib 的 `limits.h`：`PATH_MAX`、`ARG_MAX`、
  `NL_ARGMAX` 等全部缺失（newlib 本身不定义 `SSIZE_MAX`、`_POSIX_ARG_MAX`，Arm 工具链也没有）。
- `MB_LEN_MAX` 被 `glimits.h` 定为 1；newlib 以 `--enable-newlib-mb` 构建（3.2 节），它自己的值是 `_MB_LEN_MAX`（8）。
  这是错误的值，不只是缺失。
- 直接拼接 `limitx.h + glimits.h + limity.h` 也不行：没有 C 库时，`syslimits.h` 里的 `#include_next <limits.h>` 找不到文件，
  会让只装编译器的 freestanding 用法报错。

修复（属于编译器的头文件，只能在编译器包里改）：安装后按 with-headers 的方式重新生成 `limits.h`
（`limitx.h + glimits.h + limity.h`），并给 `limity.h` 中递归到 C 库的那一处 `#include_next` 加守卫：

```c
#ifdef _GCC_NEXT_LIMITS_H
#if __has_include_next(<limits.h>)
#include_next <limits.h>		/* recurse down to the real one */
#endif
#endif
```

包含链：第一遍进入 GCC 的 `limits.h` → `#include "syslimits.h"` → 其中的 `#include_next <limits.h>` 又回到 GCC 自己的
`limits.h`（`syslimits.h` 是按引号形式在同目录找到的，不在搜索链上，`include_next` 从链首找起）→ 第二遍走 `limity.h` 分支，
这里的 `include_next` 才到达 C 库。`syslimits.h` 保持 GCC 原样。（最初把守卫加在 `syslimits.h` 上——它的 `__has_include_next`
总是为真，第二遍仍然报错；新增的编译器检查当场发现，见 6.1。）

没有 C 库时与现在相同（只有 glimits）；有 newlib 时与 Arm 工具链（with-headers 构建）相同。libgcc 在编译器构建过程中使用的是
构建树里的头文件，不受影响：**r1 的目标代码应与 r0 逐字节相同**，可以用来检验这次修改的范围（5.1 节）。

### 2.3 C++ 头文件只在编译器自己的前缀里找，`--sysroot` 换不掉

`gcc/configure.ac`：未给 `--with-gxx-include-dir` 时，C++ 头文件目录是
`$(libsubdir)/$(libsubdir_to_prefix)arm-none-eabi/include/c++/$(version)`，**相对编译器前缀**，与 sysroot 无关
（`GPLUSPLUS_INCLUDE_DIR_ADD_SYSROOT=0`）。只有当 `--with-gxx-include-dir` 的值以 `--with-sysroot` 的值开头时，才会去掉这个
前缀并置 `ADD_SYSROOT=1`，之后 C++ 头文件随 sysroot 查找。用本机的 Arm 15.3.rel1 核实：传 `--sysroot=/nonexist` 后，C++ 头文件仍从
编译器前缀里找。

因此当前已发布的编译器（r0）**无法使用单独打包的 libstdc++**：头文件必须位于编译器自己的前缀下，而 xlings 的每个包都装在
各自的目录。库文件则没有这个问题：`libstdc++.a` 安装在 `<sysroot>/lib/<multilib>/`，`--sysroot` 能找到。

修复：编译器加 `--with-gxx-include-dir=<prefix>/arm-none-eabi/include/c++/14.2.0`（以 `--with-sysroot=<prefix>/arm-none-eabi`
开头）。编译器自己的 sysroot 里没有 C++ 头文件，行为不变；`--sysroot=X` 时到 `X/include/c++/14.2.0` 里找。

### 2.4 一个 `--sysroot` 只能指向一个目录 → libstdc++ 的 payload 自带 newlib

libstdc++ 的头文件、库与 newlib 的必须在同一个 sysroot 下，而 xlings 的包互不重叠。（Debian 的
`libnewlib-arm-none-eabi` / `libstdc++-arm-none-eabi-newlib` 可以分包，是因为它们装进同一个 `/usr`。）

两种做法比较过：(a) payload 自带构建它所用的那份 newlib，本身就是完整的 sysroot；(b) payload 只含 libstdc++，xim 的
`install()` 再从 `xim:newlib-arm-none-eabi` 复制 newlib 进来。**采用 (a)**（2026-11-26 决定）：自包含，工厂检查过的字节就是
用户拿到的字节，libstdc++ 与编译它时用的 newlib 头文件不可能错配。代价是 payload 多出一份 newlib：按 Arm 工具链的大小估算，每个
multilib 约 3.7 MB（libstdc++ 完整版 + nano 约 10.8 MB），29 个 multilib 共多约 110 MB（解压后）。

### 2.5 Arm 的参照（本机 Arm GNU Toolchain 15.3.rel1）

- manifest 中的 newlib configure：
  - 完整版：`--disable-newlib-supplied-syscalls --enable-newlib-retargetable-locking --enable-newlib-reent-check-verify
    --enable-newlib-io-long-long --enable-newlib-io-c99-formats --enable-newlib-register-fini --enable-newlib-mb`
  - nano：`--disable-newlib-supplied-syscalls --enable-newlib-retargetable-locking --enable-newlib-reent-check-verify
    --enable-newlib-nano-malloc --disable-newlib-unbuf-stream-opt --enable-newlib-reent-small
    --disable-newlib-fseek-optimization --enable-newlib-nano-formatted-io --disable-newlib-fvwrite-in-streamio
    --disable-newlib-wide-orient --enable-lite-exit --enable-newlib-global-atexit`

  #1174 的完整版缺 `--enable-newlib-mb`，这里补上。
- `libstdc++_nano.a` / `libsupc++_nano.a` 以 **`-fno-exceptions`** 构建。实测：nano 版中引用 `__cxa_throw` 的次数为 0
  （完整版为 20 / 7），`functexcept.o` 中没有 `.ARM.extab`，`std::__throw_*` 直接 abort。对象数相同（191 / 65），只是编译选项不同。
- 只有一套 C++ 头文件（来自完整版构建）；`c++config.h` 按 multilib 存放在 `include/c++/<ver>/arm-none-eabi/<multilib>/bits/`。
- nano 版 libstdc++ **必须用 newlib-nano 的 `newlib.h` 编译**：`--enable-newlib-reent-small` 改变了 `struct _reent` 的布局，
  而 libstdc++ 的 stdio 缓冲（`std::cout` 等）通过它访问 `stdout`。Arm 用 nano 的安装树构建第二个 gcc；这里在 nano 那一遍加
  `-isystem <sysroot>/include/newlib-nano`，与用户使用 `nano.specs` 时的头文件顺序完全一致。

### 2.6 检查用的 qemu

xim 有 `xim:qemu-arm@9.2.4-1`（xPack 构建，含 `qemu-system-arm`，自带全部库，只依赖 glibc 核心库，不需要 elfpatch），
QEMU 9.2 支持 mps2-an385/an386。检查脚本声明它（3.6 节），由 `tools/fromsource.sh` 用 xlings 装进同一个 home——容器模式与宿主
模式相同，不需要 apt，也符合上游“工厂工具都从索引安装”的方向。

## 3. 设计

### 3.1 编译器 `arm-none-eabi-gcc@14.2.0` revision 1

- fromsource 配方 `arm-none-eabi-gcc` 与 `arm-none-eabi-gcc-mingw-cross`：
  1. configure 加 `--with-gxx-include-dir=$prefix/arm-none-eabi/include/c++/$version`（2.3 节）；
  2. 安装后重新生成 `limits.h`（2.2 节）；mingw 配方从 Linux 构建复制同一个文件。
  3. （不需要改）`download_prerequisites` 默认 `--no-force`，已存在的包会跳过，libstdcxx 配方再次使用同一份
     `gcc-14.2.0` 源码树时可以重复执行。
- 版本号仍是 14.2.0（同一份上游源码）；payload、资产与 Release tag 名带 `-r1`：`arm-none-eabi-gcc-14.2.0-r1-linux-x86_64.tar.gz`，
  tag 为 `arm-none-eabi-gcc-14.2.0-r1`。这与上游 xlings-res 的规则一致（`docs/11-official-resources.md`：已发布资源不可变，重建以
  `<version>-r<N>` 发布）。r0 的资产保留。
- xim 配方：`["14.2.0"] = { revision = 1, floor = 1, … }`，并给出显式 url（`source` 模板拼出的是 r0 的文件名）。
  `floor = 1`：r0 一旦与 C 库搭配就是错的（limits.h、C++ 头文件），这属于“每个已安装 payload 都有的缺陷”。
- 四个平台都重建。Windows 的 L1（不可逐字节复现）这一轮不动（2026-11-26 决定），r1 的 Windows 资产同样不可复现。
- 目标代码（libgcc 及 startfiles）应与 r0 相同；编译器程序本身的字节会变（配置的路径变了）。

### 3.2 `fromsource:newlib-arm-none-eabi@4.5.0.20241231`

| 项 | 值 |
|---|---|
| url | `https://sourceware.org/pub/newlib/newlib-4.5.0.20241231.tar.gz`（CN：tuna 的 sourceware 镜像），sha256 `33f12605…` |
| 构建依赖 | `arm-none-eabi-gcc@14.2.0`（同一索引）、`xim:gcc@16.2.0`、`xim:binutils@2.47`、`xim:make@4.3` |
| 运行时依赖 | `xim:glibc@2.44.3`、`xim:linux-headers@5.11.1`：与其他配方相同，让 SubOS 成为主机编译器的 sysroot（顶层 configure 需要一个能工作的主机 cc） |
| 平台 | 仅 `linux`、`x86_64`：目标代码只构建一次 |
| configure | 2.5 节中 Arm 的两组参数，另加 `--disable-nls MAKEINFO=true` |
| CFLAGS_FOR_TARGET | 完整版 `-O2 -ffunction-sections -fdata-sections`，nano 版 `-Os …`；都加 `-ffile-prefix-map=<runtimedir>=/xlings-build`。不加 `-g`（与 #1174 相同，payload 小一半以上） |

payload：

```
newlib-arm-none-eabi-4.5.0.20241231/
  arm-none-eabi/include/…                 newlib 的头文件
  arm-none-eabi/include/newlib-nano/newlib.h
  arm-none-eabi/lib/*.specs               nano / nosys / rdimon / …（libgloss 安装的全部）
  arm-none-eabi/lib/<multilib>/…          完整版 + {libc,libg,librdimon}_nano.a
  COPYING.NEWLIB  COPYING.LIBGLOSS  README.provenance
```

配方的 `install()` 只做构建与最低限度的完整性断言；29 行 multilib 逐行检查放在 `tools/checks/newlib-arm-none-eabi.sh`。

### 3.3 `fromsource:libstdcxx-newlib-arm-none-eabi@14.2.0`

| 项 | 值 |
|---|---|
| url | gcc 14.2.0 tarball（与编译器配方相同；源码树在 runtimedir 中共用） |
| 构建依赖 | `arm-none-eabi-gcc@14.2.0`（提供 arm 的 as/ld，并作为检查用的编译器）、`newlib-arm-none-eabi@4.5.0.20241231`、xim 的 gcc / binutils / make |
| 平台 | 仅 `linux`、`x86_64` |

构建步骤：

1. 把 newlib 依赖的 `arm-none-eabi/` 整个复制到 `<prefix>/arm-none-eabi`：它既是最终 payload 的 sysroot，也是构建时的 sysroot。
2. 用与编译器配方**完全相同**的 configure（含 r1 的 `--with-gxx-include-dir`），只去掉 `--without-headers` 与
   `--disable-libstdcxx`；`--prefix=<prefix>`，于是 `--with-sysroot=<prefix>/arm-none-eabi` 正好是第 1 步的目录，libstdc++
   直接安装到 payload 的位置。arm 的 as/ld 从编译器依赖的 `bin/` 进入 PATH（gcc 构建树生成的 `as` / `collect-ld` 包装调用它们）。
3. `make all-gcc all-target-libgcc all-target-libstdc++-v3`，然后只执行 `install-target-libstdc++-v3`。编译器本身与这次构建出的
   libgcc 都不安装（用户用的是编译器包里的那份）。
4. nano：删除构建树中各 multilib 的 `libstdc++-v3` 目录，以
   `CXXFLAGS_FOR_TARGET="-Os -ffunction-sections -fdata-sections -fno-exceptions"`（`CFLAGS_FOR_TARGET` 同样改为 `-Os`：
   libsupc++ 中的 `cp-demangle.c` 是 C 代码）重新 `make all-target-libstdc++-v3`，安装到临时 `DESTDIR`，再把
   `libstdc++.a` / `libsupc++.a` 以 `_nano.a` 名放入 payload。这一遍期间把 nano 的 `newlib.h` 放在 sysroot 的
   `include/newlib.h` 位置，结束后放回并 `cmp` 核对。没有用 `-isystem <sysroot>/include/newlib-nano`：树内构建自己会在前面加
   `-isystem <tooldir>/include`，先找到的会是完整版的 `newlib.h`。替换的效果与用户使用 `nano.specs` 时完全相同。
5. 删除 `*.la`、`libstdc++*-gdb.py` 与 `<prefix>/share`（gdb pretty printer：其中写有构建路径，且不属于 sysroot）。

payload：

```
libstdcxx-newlib-arm-none-eabi-14.2.0/
  arm-none-eabi/                          newlib-arm-none-eabi 的完整 sysroot，加上：
    include/c++/14.2.0/…                  C++ 头文件；arm-none-eabi/<multilib>/bits/c++config.h 等
    lib/<multilib>/libstdc++.a libsupc++.a libstdc++exp.a …  libstdc++_nano.a libsupc++_nano.a
  COPYING.NEWLIB COPYING.LIBGLOSS COPYING3 COPYING.RUNTIME README.provenance
```

`README.provenance` 记录其中 newlib 的版本（由依赖关系决定，即 4.5.0.20241231）。

### 3.4 构建依赖用同一索引的 fromsource 编译器，而不是已发布的 xim 包

- `xim:arm-none-eabi-gcc` 目前只在本仓库的 `xim/` 下，不在上游主索引中，`fromsource.sh` 的全新 home 解析不到它。
- fromsource 的配方本来就是构建的唯一事实来源；Linux 产物可复现，目标代码与已发布的编译器相同（libgcc 逐字节相同，5.1 节
  核对）。决定 newlib 能否用的是 multilib 集合与编译器的行为，二者都由配方决定。
- 代价：每个 C 库 job 都要重新构建一次 binutils + gcc（CI 约 30 分钟）。#1174 合入主索引后，可以改为依赖 `xim:arm-none-eabi-gcc`。

### 3.5 `tools/fromsource.sh` 的改动

- `--revision N`：payload 名、目录名与 provenance 带 `-rN`（fromsource 的版本号不变）。容器模式原样传入。
- 检查脚本可以用注释声明检查时需要的 xim 包，例如：

  ```bash
  # needs: xim:qemu-arm@9.2.4-1
  ```

  `fromsource.sh` 在运行检查前用同一个 xlings 安装它们，并把各自的 `bin/` 加到检查的 PATH 前面。
- 给检查脚本传 `FROMSOURCE_XPKGS=<home>/data/xpkgs`：库包的检查需要编译器，默认使用该 home 中 fromsource 构建的
  `arm-none-eabi-gcc`。也可以用 `ARM_NONE_EABI_GCC=<prefix>` 指定另一个编译器，例如已发布的 xim 包，用来交叉核对。

### 3.6 检查

- `tools/checks/arm-none-eabi-gcc.sh`（新增）：
  - 不带 C 库时 `#include <limits.h>` 可用，且 `INT_MAX` 等有定义；
  - `--sysroot=<一个只有 include/limits.h 的目录>` 时，`limits.h` 会 `#include_next` 到它（用一个哨兵宏验证）；
  - `g++ --sysroot=sr -E -v` 的搜索列表中出现 `sr/include/c++/<version>`（相对路径：Windows 的 Git Bash 不需要做路径转换）。
- `tools/checks/newlib-arm-none-eabi.sh`：
  - payload 的 multilib 集合等于编译器的 `-print-multi-lib`，每一行的文件都齐全；`nano.specs` / `nosys.specs` / `rdimon.specs` 存在；
  - #1174 的全部检查（2.1 节）；
  - `limits.h`：选中 newlib 后与 Arm 15.3.rel1 相同——`PATH_MAX` 1024、`ARG_MAX` 65536，完整版 `MB_LEN_MAX == 8`，nano 版为 1（nano 未开 mb）；
  - qemu：`# needs: xim:qemu-arm@9.2.4-1`，在 an385 / an386 上运行。声明了就是必需的：缺少 qemu 时检查失败（不设“可选”开关）。
    libgloss 的 M-profile `crt0` 不打开 FPU，测试程序自带复位入口：先置位 CPACR 的 CP10/CP11，再跳到 `_start`。
- `tools/checks/libstdcxx-newlib-arm-none-eabi.sh`：
  - newlib 部分完整（复用 newlib 的逐行检查）；每个 multilib 有 `libstdc++{,_nano}.a`、`libsupc++{,_nano}.a`，且有对应的 `c++config.h`；
  - nano 版不引用 `__cxa_throw`，完整版引用；
  - CubeMX 式 C++ 链接（m4 hard + `nano.specs`）链接的是 `thumb/v7e-m+fp/hard/libstdc++_nano.a`；不加 `nano.specs` 时链接 `libstdc++.a`；
  - `<cstdio> <vector> <string> <memory> <algorithm> <iostream> <climits>` 能编译；
  - qemu：完整版——静态构造、`std::vector` / `std::string`、抛出并捕获异常、`std::printf`；nano 版（`-fno-exceptions`）——同一个程序去掉异常部分。

### 3.7 xim 配方

- `xim/pkgs/n/newlib-arm-none-eabi.lua`：以 #1174 的配方为基础，改用本仓库 Release：
  `…/releases/download/newlib-arm-none-eabi-4.5.0.20241231/newlib-arm-none-eabi-4.5.0.20241231.tar.gz`，同一个 sha256 用于
  linux / macosx / windows。`install()` 逐行断言 29 个 multilib。`config()` 只注册总节点：目标头文件不能进入宿主的 include 路径。
- `xim/pkgs/l/libstdcxx-newlib-arm-none-eabi.lua`：同上；另外断言 C++ 头文件与 `_nano` 库存在。描述中写明它已含 newlib，
  并且需要 `arm-none-eabi-gcc` 14.2.0 revision ≥ 1。
- 不声明对编译器的依赖：sysroot 与编译器的组合由用户选择（与 #1174 相同）。
- sha256 在 CI 构建并发布后填写（宿主模式与容器模式的字节不同，本地构建的值不能用）。

### 3.8 CI

- `.github/build-matrix.json`：条目可带 `"revision": N`；编译器的四个条目改为 revision 1；新增两条 `kind: data` 的 linux x86_64 条目。
- `build.yml`：`--revision` 传给 `fromsource.sh`；artifact 名 `res-<what>-<version>[-rN]-[<os>-]<arch>`，release job 据此得到 tag
  `<what>-<version>[-rN]`（现有的解析方式不用改）。lint 检查 `revision` 是正整数。
- 预计耗时（CI 4 核，未实测）：newlib job ≈ 编译器 30 分钟 + newlib；libstdcxx job ≈ 编译器 + newlib + gcc 重建 + 两遍 libstdc++，
  应在 330 分钟以内。实测后记入第 6 节。

### 3.9 与 Arm GNU Toolchain 的差异：不完全对齐

本仓库的包**不以完全对齐 Arm GNU Toolchain 为目标**（2026-11-27 决定）。文件名、configure、multilib 与 Arm 一致，
STM32CubeMX 生成的项目可以直接链接；但凡是 Arm 的构建关掉了、而这里的目标环境能够支持的能力，就保留。

**增强：`std::filesystem` 可以真正使用。** libstdc++ 的 `fs_ops.cc` 按 `c++config.h` 中的宏决定每个操作的实现：宏为 1 时调用
对应的 POSIX 函数（`::mkdir`、`::getcwd`、`::chdir`、`::chmod` 等）；宏未定义时，直接返回 `errc::function_not_supported`。

| | Arm GNU Toolchain 15.3.rel1 | 本仓库（libstdc++ 14.2.0） |
|---|---|---|
| `_GLIBCXX_USE_{MKDIR,GETCWD,CHDIR,CHMOD,FCHMOD,FCHMODAT}`、`_GLIBCXX_HAVE_{READLINK,SYMLINK,UNLINKAT,OPENAT}` | 未定义 | 1 |
| `create_directory`、`current_path` 等 | 永远返回 “Function not implemented”（实测，见下） | 调用项目提供的 `mkdir`、`getcwd` 等 |
| `_GLIBCXX_HAVE_ICONV` | 未定义 | 1（newlib 自带 iconv） |

Arm 的实测（本机，cortex-m4 hard，qemu mps2-an386，`--specs=rdimon.specs`）：

```
create_directory: 0, ec=88 (Function not implemented)
current_path: '', ec=88 (Function not implemented)
```

使用方法：newlib 在 arm 上不实现这些函数（`libc/unix` 不参与 arm 的构建；`libc/reent` 只有 `_mkdir_r`，没有 `mkdir`），
需要由项目提供，**用 POSIX 名字**（`mkdir`、`getcwd`、…，不是 `_mkdir`），通常是接在 FatFs、littlefs 等文件系统上的一层薄封装。
提供之后，`std::filesystem` 的对应操作就真正在设备上的文件系统里执行。

代价：项目用到某个操作却没有提供对应函数时，结果是**链接错误**，而不是 Arm 那样在运行时返回错误码。想要 Arm 的行为，
可以提供一个返回 `-1` 并设置 `errno = ENOSYS` 的同名函数。（附带一提：Arm 的工具链用 `--specs=nosys.specs` 链接
`std::filesystem` 本身就会失败——`resize_file` 需要的 `truncate` 只有 rdimon 提供。）

需要哪些函数（实测，6.3 节）：所有操作都在同一个 `fs_ops.o` 里。

| 程序用到的操作 | 带 `-Wl,--gc-sections`（CubeMX 默认） | 不带 |
|---|---|---|
| `create_directory` | `mkdir` | `chdir fchmod fchmodat getcwd mkdir pathconf readlink symlink truncate`（整个 `fs_ops.o`） |
| `current_path` | `getcwd`、`pathconf` | 同上 |
| `exists`（只用 `stat`，libnosys 有） | 无，直接链接 | 同上 |

也就是说，带 `--gc-sections` 时，只需要实现实际用到的那几个；链接器报出的未定义符号就是要实现的清单。`truncate` 由 rdimon 提供。

**与 Arm 保持一致的地方：`std::random_device` 不使用 `getentropy` / `arc4random`。** 原因不在于对齐 Arm：每个用到
`std::runtime_error` 的程序都会经由字符串实例化引入 `random_device`，而 `_getentropy` 除了 libnosys 的桩以外没有人提供，
保留它会让大量普通程序链接失败，换来的能力（硬件熵源）却需要项目另外实现（6.3 节）。

## 4. 实施顺序

1. 编译器配方（r1 两处修改）+ 新检查，本地构建，核对 libgcc 与 r0 是否逐字节相同。
2. `fromsource.sh`：`--revision`、`# needs:`、`FROMSOURCE_XPKGS`。
3. newlib 配方与检查，本地构建（宿主模式）。
4. libstdcxx 配方与检查，本地构建。
5. xim 配方（sha256 待填），用本地 payload 在临时 home 中端到端安装测试。
6. CI：matrix 与 workflow；`release=false` 跑一遍 → 核对 → `release=true` 发布 → 填 sha256。推送与发布前先确认。

## 5. 风险与待验证

1. 重新生成 `limits.h` 后，r1 的 libgcc 是否与 r0 逐字节相同（预期相同：libgcc 在安装之前就已构建完）。
2. 带 `--with-gxx-include-dir` 时，编译器在 Windows 上把 C++ 头文件目录随 sysroot 重定位（Windows `check` job 验证）。
3. 两个配方共用 runtimedir 中的 `gcc-14.2.0` 源码树：xlings 第二次解压同一个 tarball 时是覆盖还是跳过；`download_prerequisites` 不能重复执行。
4. 以 `-fno-exceptions` 构建 libstdc++ 14.2.0（Arm 的做法）能否通过；`make` 命令行上的 `CXXFLAGS_FOR_TARGET` 能否传到重新 configure 的 libstdc++。
5. libstdc++ 的 payload 是否含有构建路径（`fromsource.sh` 的泄漏扫描会发现）。
6. qemu-arm（xPack）在 Debian 12 容器中能否直接运行。

## 6. 实施记录

本地均为宿主模式（16 核，本机无 docker），xlings 2026.11.16.1，复用同一个 `FROMSOURCE_HOME` 迭代；字节与 CI 容器构建不同，
sha256 不能用于 xim 配方。

### 6.1 编译器 14.2.0-r1

- 第一次构建，新增的编译器检查当场失败：`#include <limits.h>` 在没有 C 库时报 `limits.h: No such file or directory`。
  原因是守卫加错了地方（2.2 节已改正）：`syslimits.h` 是按引号形式找到的，它的 `include_next` 回到 GCC 自己的 `limits.h`，
  `__has_include_next` 总是为真；真正到达 C 库的是第二遍 `limity.h` 里的那一处。改为守卫 `limity.h`、`syslimits.h` 保持原样后通过。
- 约 10 分钟（binutils 已在 home 中）。payload `arm-none-eabi-gcc-14.2.0-r1-linux-x86_64.tar.gz`。
- **与已发布的 r0（CI 容器构建，c0b8058）对比：`lib/gcc/arm-none-eabi/14.2.0` 下 203 个 `.a` / `.o`（libgcc 与 startfiles，全部
  multilib）逐字节相同；头文件只有 `include/limits.h` 不同。** 构建方式（宿主 / 容器）和主机侧依赖（xim:binutils 2.42.1 → 2.47、
  glibc 2.44.3-r4、gcc 16.2.0-r1）都变了，目标代码不变；r1 的改动范围与设计一致。
- 用 r1 的 xim 条目（`revision = 1, floor = 1`、按架构给出显式 url）在全新 home 中安装（预置下载缓存）：elfpatch 把 INTERP 绑到
  `<home>/abi/linux-x86_64-glibc`，shim 可用。

### 6.2 newlib-arm-none-eabi

- 约 15 分钟（两个变体 × 29 个 multilib）。payload 34 MB（解压 128 MiB），没有构建路径。
- 检查第一次失败两处，都是 #1174 遗留、从未实际运行过的检查本身的问题，payload 没有问题：
  1. `limits.h` 检查要求 `SSIZE_MAX`、`_POSIX_ARG_MAX`，但 newlib 不定义它们（Arm 15.3.rel1 也没有）。改为与 Arm 的结果对齐：
     `PATH_MAX` 1024、`ARG_MAX` 65536、`MB_LEN_MAX` 完整版 8 / nano 版 1——两者完全一致。
  2. `mps2.ld` 没有定义 `__end__`（rdimon 的 crt0 引用它作为堆的起点），运行程序链接失败。补上；另加 `-Wl,--no-warn-rwx-segments`
     （测试镜像只有一块可读写执行的 RAM）。
- 运行检查：qemu 9.2.4（xim:qemu-arm），an385 nano、an386 nano、an386 完整版（含 `%.2f`）都输出正确。**反例**：去掉打开 FPU
  的复位入口后，an386 上的 hard-float 程序在第一条 VFP 指令处 Lockup——复位入口是必需的。
- xim 配方（本地 sha256）安装通过，`install()` 逐行断言 29 个 multilib；以用户的方式（shim + `--sysroot=<安装目录>/arm-none-eabi`
  + `--specs=nano.specs --specs=nosys.specs`）链接 cortex-m4 hard，并在 an386 上运行：`PATH_MAX=1024 MB_LEN_MAX=8`。

### 6.3 libstdcxx-newlib-arm-none-eabi

- 第一次构建约 40 分钟（gcc 重建 + libgcc + 两遍 libstdc++）。nano 与完整版的 `c++config.h` 完全相同（0 行差异）。
- 检查在完整版的运行链接处失败：`undefined reference to _getentropy`。链接图：`cow-string-inst.o` → `std::random_device::_M_init`
  → `random.o` → `arc4random` / `getentropy` → `_getentropy`，而只有 libnosys 有它的桩，rdimon 没有。用到 `std::runtime_error`
  就会走到这条链；用 rdimon，或自己写 syscalls 而不链 libnosys 的项目会链接失败。Arm 的 `random.o` 同样被引入，但不引用这两个函数。
  原因：GCC 14 交叉构建时只能对它们做编译测试，newlib 声明了它们，检测通过。修复：`glibcxx_cv_getentropy=no
  glibcxx_cv_arc4random=no`（与 Arm 一致；`random_device` 退回 mt19937），并在检查中断言 libstdc++ 不引用它们。
- 以 `_getentropy` 桩预先验证了其余检查（在第一次构建的产物上）：全部通过，包括 qemu 上的 4 次 C++ 运行（静态构造、容器、虚调用；
  完整版在 M3 与 hard-float M4 上抛出并捕获异常）。

- 文件系统（2026-11-27）：检查中的程序自带内存版的 `mkdir`、`getcwd`、`pathconf`，带 `--gc-sections` 链接，在 an386 上
  `create_directory` 成功、`current_path` 返回项目给出的 `/flash`。第一次只提供了 `mkdir`、`getcwd`，链接报缺 `pathconf`——
  `current_path` 先用 `pathconf(".", _PC_PATH_MAX)` 确定缓冲区大小。各操作需要的符号见 3.9 节的表。
- CI（run 45940907309）中 nano 那一遍失败：`_udivdi3.dep:111: *** missing separator`。换入 nano 的 `newlib.h` 让它变新，
  `all-target-libstdc++-v3` 先经过 libgcc，libgcc 的依赖文件记录了这个头文件，于是 29 个 multilib 的 libgcc 在 4 核上并行重建，
  其中一个 `.dep` 被写坏（本地 16 核没有撞上）。修复：换入后用 `touch -r` 保留原来的时间，并断言这一遍没有重建 libgcc。
- 修复后重建约 42 分钟，检查全部通过。payload 105 MB（解压 432 MiB，与 2.4 节的估算相符），没有构建路径。
- xim 配方（本地 sha256）安装通过；以用户的方式（shim + `--sysroot=<安装目录>/arm-none-eabi`）构建一个用到异常、`std::map`
  静态构造的程序，在 an386 上运行正确；CubeMX 式 `--specs=nano.specs --specs=nosys.specs -fno-exceptions -fno-rtti` 编译通过。

与 Arm 15.3.rel1 的 `c++config.h` 相比，还有以下宏不同（Arm 为 no，这里为 yes）：`_GLIBCXX_HAVE_ICONV`、`_GLIBCXX_HAVE_OPENAT`、
`_GLIBCXX_HAVE_READLINK`、`_GLIBCXX_HAVE_SYMLINK`、`_GLIBCXX_HAVE_UNLINKAT`、`_GLIBCXX_USE_{CHDIR,CHMOD,FCHMOD,FCHMODAT,GETCWD,MKDIR}`。
它们只在使用 `std::filesystem`（或 iconv 编码转换）时才会被引用。保持 GCC 14 的检测结果：这是有意的增强，不是遗漏
（3.9 节，2026-11-27 决定）。

### 6.4 尚未完成

- 未推送；CI 尚未运行。容器模式、aarch64 / Windows / macOS 的 r1 编译器，以及 CI 中 data 包的耗时，都由 CI 首次验证。
  Windows 的 `check` job 会验证 C++ 头文件随 sysroot 重定位（5 节第 2 项）。
- xim 配方：newlib / libstdcxx 的 sha256 为 `PENDING` 占位；编译器的 r1 条目（`revision = 1, floor = 1`、显式 url）在 CI 发布后
  再写入 `xim/pkgs/a/arm-none-eabi-gcc.lua`（形式已在 6.1 中用本地 payload 验证）。
- 发布顺序：`release=false` 全量构建一遍 → 核对 → `release=true` → 填写三个配方的 sha256 → 全新 home 从 Release 安装验证。

## 7. 不在本轮范围

- picolibc 与 `libstdcxx-picolibc-arm-none-eabi`：下一轮，沿用本轮的结构。
- 不带 `--sysroot` 的 CubeMX 命令：需要组合包装（xvm alias 带参数或包装脚本），另行设计。
- Windows L1。
- 依赖改为 `xim:arm-none-eabi-gcc`（等 #1174 合入后）。
