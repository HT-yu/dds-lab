# CLAUDE.md

本文件为 Claude Code 在本仓库工作时提供上下文。面向用户的完整文档见 `README.md`。

学习文档：

- `LEARNING_PLAN.md`：8 周入门到进阶计划（协议概念、抓包、QoS、SHM、压测）。
- `ADVANCED_DDS_STUDY.md`：源码级深潜路线（发现机制、内存管理、可调试构建、实验组 E1–E8 / M1–M7、源码锚点）。

## 项目定位

`dds-lab` 是一个**单容器、从源码构建**的 DDS 中间件实验环境，用于学习、对比和压测两套 DDS
实现及其共享内存传输。它不承载业务代码，价值在于可复现的源码、构建树、安装前缀和冒烟测试。

| 组件 | 版本 | 作用 |
| --- | --- | --- |
| iceoryx | v2.0.8 | 共享内存 IPC（RouDi + POSH + C binding）。**不是 DDS 实现**。 |
| Fast-CDR | v2.4.0 | Fast DDS 的 CDR 序列化库。 |
| Fast DDS | v3.6.2 | OMG DDS/RTPS 实现，3.x 自带 SHM 传输，**不依赖 iceoryx**。 |
| Cyclone DDS | 11.0.1 | OMG DDS/RTPS 实现，通过 `psmx_iox` 插件使用 iceoryx。 |

概念上不要混淆：DDS 规范（API/数据模型）+ RTPS（线协议）由 Fast DDS 和 Cyclone DDS 实现；
iceoryx 只是共享内存传输层，Cyclone 可选地接它，Fast DDS 用的是自己的 SHM。

截至 2026-10-27：镜像 `dds-lab:latest` 和容器 `dds-lab` 已存在并运行，
`verify-install.sh` 与 `run-all-smoke.sh` 全部 PASS。当前目录**不是 git 仓库**。

## 路径与存储

宿主（Windows）：

```
E:\Code\dds-lab\
├── Dockerfile / compose.yaml / .env   # 镜像与容器编排
├── scripts/                           # 运行时挂载到 /usr/local/bin/ddslab（只读）
├── workspace/                         # 挂载到 /workspace（9p，Windows 可直接编辑）
│   ├── config/cyclonedds-shm.xml
│   ├── experiments/                   # 冒烟/演示脚本
│   └── logs/                          # 每次实验的日志（gitignored）
└── .base/                             # 本地 ubuntu-base rootfs tar.gz（gitignored）
```

容器内：

```
/build/src        源码（Docker 卷 dds-lab_dds-build，ext4）
/build/build      构建树（同一卷）
/build/downloads  固定版本 tarball（同一卷）
/build/.ccache    ccache（同一卷）
/opt/dds/{iceoryx,fastcdr,fastdds,cyclonedds}   安装前缀（卷 dds-lab_dds-opt，ext4）
/workspace        9p 绑定挂载（Windows 文件）
```

规则：

- `/workspace` 是 9p（`drvfsa`），元数据操作很慢：同一源码树解压比 ext4 慢 46–70 倍。
  **手写的小实验源码**可以放 `/workspace`，**构建树和依赖必须放 `/build`**。
- 安装产物只通过构建脚本的 `cmake --install` 写入 `/opt/dds`，不要手工往那里拷贝文件。
- `/build/src` 可以读、可以改，但 `fetch-sources.sh` 会删除并重新解压。需要长期保留的源码改动，
  应写成 patch 或构建脚本的一部分。

## 常用命令

宿主（Git Bash；容器内绝对路径参数必须加 `MSYS_NO_PATHCONV=1`）：

```bash
cd /e/Code/dds-lab
docker compose ps
docker compose up -d
MSYS_NO_PATHCONV=1 docker exec -it dds-lab bash
MSYS_NO_PATHCONV=1 docker exec dds-lab bash /workspace/experiments/run-all-smoke.sh
```

容器内（交互式 shell 的 `/root/.bashrc` 会自动 source `env.sh`；非交互 shell 需手动 source）：

```bash
source /usr/local/bin/ddslab/env.sh

/usr/local/bin/ddslab/verify-install.sh
/usr/local/bin/ddslab/shm-status.sh
/usr/local/bin/ddslab/build-all.sh                 # 全部组件（Release）
/usr/local/bin/ddslab/build-all.sh iceoryx         # 单个组件
JOBS=4 /usr/local/bin/ddslab/build-all.sh
DDSLAB_FETCH=always /usr/local/bin/ddslab/build-all.sh

# 带调试信息的并行构建（深潜实验用，见 ADVANCED_DDS_STUDY.md）
source /usr/local/bin/ddslab/env-debug.sh          # 设置各组件前缀 + RelWithDebInfo
/usr/local/bin/ddslab/build-all.sh fastcdr fastdds cyclonedds
# 之后当前 shell 处于调试前缀；切回 Release 见 env-debug.sh 头部注释

/workspace/experiments/run-iceoryx-demo.sh
/workspace/experiments/run-fastdds-demo.sh
/workspace/experiments/run-cyclone-demo.sh udp
/workspace/experiments/run-cyclone-demo.sh shm
```

## 脚本与实验约定

- 新脚本用 bash，`#!/usr/bin/env bash`，严格模式（`set -euo pipefail` 或演示脚本的
  `set -uo pipefail`），并以 `source /usr/local/bin/ddslab/env.sh` 开头。
- 脚本注释用英文，面向用户的 README/计划用中文，与现有文件保持一致。
- 每次运行写到独立日志目录：`/workspace/logs/<name>-$(date +%Y%m%d-%H%M%S)/`。
- 启动后台进程的脚本必须有 `cleanup` trap 和 `kill`，失败时以非零码退出。
- 版本号只在 `scripts/env.sh` 里维护（`DDSLAB_VERSION_*`）；构建类型用
  `DDSLAB_BUILD_TYPE`（默认 `Release`），调试构建必须配独立的 `BUILD_DIR` 和 `DDS_PREFIX`，
  不要覆盖 Release 安装前缀。
- shell 脚本保持 LF 换行；在 Windows 编辑器里改完要确认没有变成 CRLF。
- 新增快速冒烟步骤时可以挂到 `run-all-smoke.sh`；只需要几分钟的大实验不要挂进去。

我的实验工程建议这样放（源在 Windows，构建在卷）：

```
/workspace/labs/<实验名>/            源码、CMakeLists.txt
/build/labs/<实验名>/                构建树
```

CMake 已通过 `CMAKE_PREFIX_PATH` 暴露全部前缀：

```cmake
find_package(fastcdr 2 REQUIRED)
find_package(fastdds 3 REQUIRED)      # target: fastdds fastcdr
find_package(CycloneDDS REQUIRED)     # target: CycloneDDS::ddsc
```

## 已知陷阱

1. **`docker exec` 参数被 Git Bash 改写**：带 `/workspace/...` 等容器路径时加
   `MSYS_NO_PATHCONV=1`。
2. **RouDi 只在 `-DTOML_CONFIG=ON` 时构建**：`build-iceoryx.sh` 已固定该选项。缺
   `iox-roudi` 时重跑 `build-all.sh iceoryx`。
3. **cpptoml 补丁**：iceoryx 的 ExternalProject 原本要 `git clone github.com`，
   `build-iceoryx.sh` 会下载 cpptoml tarball 并改写 `cpptoml.cmake.in`。补丁是幂等的，
   重新解压源码后也会自动重打。
4. **Cyclone PSMX 三件套**：`CYCLONEDDS_URI=file:///workspace/config/cyclonedds-shm.xml`
   + `iox-roudi` 在跑 + `LD_LIBRARY_PATH` 含 `/opt/dds/cyclonedds/lib`（`env.sh` 提供）。
   配置是 Cyclone 11 的 `<General><Interfaces><PubSubMessageExchange type="iox"/>`，
   旧的 `<SharedMemory><Enable>` 已弃用。
5. **Fast DDS 示例路径**：3.x 的示例不是 `/opt/dds/fastdds/bin/hello_world`，而是在
   `/opt/dds/fastdds/share/fastdds/examples/cpp/<name>/bin/` 下。
6. **`fastdds` CLI 需要 psutil**：旧镜像缺 `python3-psutil` 时 `fastdds` /
   `fast-discovery-server` 会报 `"psutil" module not found`。`Dockerfile` 已加入该包，
   当前容器也已手动安装；若重建镜像后仍报错，先检查这一项。
7. **`/dev/shm` 只有 2 GiB**（compose `shm_size: "2gb"`）。iceoryx 默认预留约 207 MiB，
   Fast DDS 每个 participant 约 0.5 MiB。压测大样本时注意容量；改 `shm_size` 后需
   `docker compose up -d` 重建容器。
8. **残留段**：进程被强杀会留下 `/dev/shm/fastdds_*`、`/dev/shm/iceoryx_mgmt`、
   `/dev/shm/root`。清理前先确认没有 `iox-roudi` / `ddsperf` / `hello_world` 在跑。
9. **破坏性操作**：`docker compose down -v` 会删除源码、构建树、ccache 和安装产物，恢复需要
   重新 fetch + build。执行前必须得到用户明确同意。
10. **网络**：Docker Hub 和 github.com 可能不可达。基础镜像来自本地
    `dds-lab-base:22.04`，源码走 codeload 并回退 `ghproxy.net`。不要改成直接拉
    `ubuntu:22.04` 或 `git clone`。
11. **同一 domain 会互通**：所有实验默认 domain 0。并行跑 Fast DDS 和 Cyclone 实验时，
    同 topic/type 可能互相发现；需要隔离就改 domain ID。
12. **`tcpdump -i any` 会重复计数**：容器内同一组播包会在 `lo` 和 `eth0` 各出现一次
    （一个包三条记录）。统计发现报文时用 `-i eth0`，否则结论放大 3 倍。
13. **调试构建不用于性能结论**：`RelWithDebInfo`/`Debug` 只用于断点和行为观察；
    吞吐、延迟、内存上限必须用 Release 构建测。
14. **`DDS_PREFIX` 不会传导到组件前缀**：镜像 `ENV` 显式导出 `FASTCDR_PREFIX` /
    `FASTDDS_PREFIX` / `CYCLONEDDS_PREFIX`，`build-*.sh` 直接用它们。构建调试版必须先
    `source env-debug.sh`；只 `export DDS_PREFIX=/opt/dds-debug` 会把调试库装进
    `/opt/dds`。误装后用 Release 构建树重跑 `build-all.sh` 即可恢复（数秒）。

## 验证流程

改动脚本、compose 或构建配置后：

```bash
MSYS_NO_PATHCONV=1 docker exec dds-lab bash /usr/local/bin/ddslab/verify-install.sh
MSYS_NO_PATHCONV=1 docker exec dds-lab bash /workspace/experiments/run-all-smoke.sh
```

预期结尾：

```
=== verify-install: PASS ===
PASS  verify-install
PASS  iceoryx
PASS  fastdds
PASS  cyclone-udp
PASS  cyclone-shm
```

项目没有单元测试框架，冒烟脚本就是回归测试。日志在 `workspace/logs/smoke-<timestamp>/`。

## 给 Claude 的工作规则

- 用中文回复用户；文件路径、命令和代码标识符保持原样。
- 动手前先 `docker compose ps`，容器通常已经在运行，不要无谓地重建。
- 不要把构建产物、依赖或大文件写进 `/workspace`。
- 不要修改 `workspace/logs/` 里的历史日志，也不要删 `.base/`。
- 不要把一次性的调试文件留在项目根目录；实验代码放 `workspace/labs/`，脚本放
  `workspace/experiments/`。
- 涉及删除卷、清理 `/dev/shm`、终止他人进程时，先确认再执行。
- 如果用户要学习/修改 DDS 内部实现，优先在 `/build/src` 里读源码，并说明重新 fetch 会覆盖改动。
