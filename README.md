# DDS Lab：iceoryx / Fast DDS / Cyclone DDS 源码实验环境

一个单容器、可重复的 DDS 中间件实验环境：从源码编译 **iceoryx**、**Fast DDS**、
**Cyclone DDS**，并提供共享内存（SHM）和 UDP 的发布/订阅冒烟测试。

当前已验证的环境：

| 组件 | 版本 | 安装前缀 |
| --- | --- | --- |
| iceoryx（RouDi + POSH + C binding） | v2.0.8 | `/opt/dds/iceoryx` |
| Fast-CDR | v2.4.0 | `/opt/dds/fastcdr` |
| Fast DDS（内置 SHM 传输） | v3.6.2 | `/opt/dds/fastdds` |
| Cyclone DDS（PSMX iceoryx 插件） | 11.0.1 | `/opt/dds/cyclonedds` |
| cpptoml（iceoryx 配置依赖） | v0.1.1 | 构建时下载并打入 iceoryx |
| 基础系统 | Ubuntu 22.04.5 | 本地导入的 rootfs 镜像 |

宿主机：Windows 11 + WSL2 + Docker Desktop。Docker VM 配置为 8 CPU / 8 GiB 内存 /
4 GiB swap，容器 `/dev/shm` 为 2 GiB。

## 学习文档

- `LEARNING_PLAN.md`：8 周入门到进阶计划（协议概念、抓包、QoS、SHM、压测）。
- `ADVANCED_DDS_STUDY.md`：源码级深潜路线（发现机制、内存管理、可调试构建、
  实验组 E1–E8 / M1–M7、Fast DDS / Cyclone / iceoryx 源码锚点）。

## 目录结构

```
dds-lab/
├── .env                          # 基础镜像与 apt 镜像配置
├── Dockerfile                    # Ubuntu 22.04 + 构建工具链
├── compose.yaml                  # 单容器 + 两个数据卷 + workspace 挂载
├── scripts/
│   ├── env.sh                    # 所有路径、PATH、版本号
│   ├── import-base-image.sh      # 从 USTC 下载 ubuntu-base rootfs 并 docker import
│   ├── fetch-sources.sh          # 下载固定版本源码 tarball
│   ├── build-fastcdr.sh
│   ├── build-iceoryx.sh          # TOML_CONFIG=ON + 本地 cpptoml
│   ├── build-fastdds.sh
│   ├── build-cyclonedds.sh       # ENABLE_ICEORYX=ON
│   ├── build-all.sh              # 按依赖顺序构建
│   ├── verify-install.sh         # 检查工具、库、CMake 包
│   └── shm-status.sh             # 查看 /dev/shm 与 RouDi
└── workspace/                    # 从 Windows 直接编辑，容器内立即可见
    ├── config/
    │   ├── cyclonedds-shm.xml    # Cyclone DDS 的 iceoryx PSMX 配置
    │   ├── cyclonedds-trace.xml  # finest 日志 + 内建 pcap（深潜实验）
    │   ├── cyclonedds-fast-spdp.xml
    │   └── fastdds-fast-spdp.xml # 发现通告/租约调参（深潜实验）
    ├── experiments/
    │   ├── run-iceoryx-demo.sh
    │   ├── run-fastdds-demo.sh
    │   ├── run-cyclone-demo.sh   # [udp|shm]
    │   └── run-all-smoke.sh
    └── logs/                     # 每次实验的日志
```

源码、构建树和 ccache 位于 Docker 卷 `dds-lab_dds-build`，安装在
`dds-lab_dds-opt`，避免在 Windows bind mount 上编译。

## 快速开始

在 Git Bash 中：

```bash
cd /e/Code/dds-lab
docker compose up -d
MSYS_NO_PATHCONV=1 docker exec -it dds-lab bash
```

> Git Bash/MSYS 会把容器内绝对路径改写成 Windows 路径，所以在 Git Bash 里执行
> `docker exec` 时请加 `MSYS_NO_PATHCONV=1`。PowerShell 不受影响。

进入容器后环境变量会自动加载。若在使用非交互 shell，请先：

```bash
source /usr/local/bin/ddslab/env.sh
```

### 构建全部组件

镜像已经包含构建工具，源码和构建产物在数据卷中：

```bash
# 容器内
/usr/local/bin/ddslab/fetch-sources.sh
/usr/local/bin/ddslab/build-all.sh
```

只重建某一部分：

```bash
/usr/local/bin/ddslab/build-all.sh iceoryx
/usr/local/bin/ddslab/build-all.sh fastdds cyclonedds
```

常用环境变量：

```bash
JOBS=4 /usr/local/bin/ddslab/build-all.sh          # 限制并行度
DDSLAB_FETCH=always /usr/local/bin/ddslab/build-all.sh  # 强制重新下载源码
```

## 运行实验

一条命令跑完全部五项：

```bash
MSYS_NO_PATHCONV=1 docker exec dds-lab bash /workspace/experiments/run-all-smoke.sh
```

预期输出：

```
PASS  verify-install
PASS  iceoryx
PASS  fastdds
PASS  cyclone-udp
PASS  cyclone-shm
```

也可以单独运行：

```bash
MSYS_NO_PATHCONV=1 docker exec dds-lab bash /workspace/experiments/run-iceoryx-demo.sh
MSYS_NO_PATHCONV=1 docker exec dds-lab bash /workspace/experiments/run-fastdds-demo.sh
MSYS_NO_PATHCONV=1 docker exec dds-lab bash /workspace/experiments/run-cyclone-demo.sh udp
MSYS_NO_PATHCONV=1 docker exec dds-lab bash /workspace/experiments/run-cyclone-demo.sh shm
```

### 实验说明了什么

**iceoryx（零拷贝 SHM）**

`iox-roudi` 创建管理段和 payload 池，publisher/subscriber 都映射同一块 SHM：

```
--- shared-memory mappings ---
... rw-s ... /dev/shm/root
... rw-s ... /dev/shm/iceoryx_mgmt
--- /dev/shm ---
64M  iceoryx_mgmt
143M root
[PASS] iceoryx pub/sub over shared memory (30 samples)
```

**Fast DDS（内置 SHM 传输）**

Fast DDS 3.6.2 自带 SHM 传输，不依赖 iceoryx。`hello_world` 每 100 ms 发一条，
`--samples 100` 时约 10 秒结束，脚本在启动 1 秒后抓取 `/proc/<pid>/maps`：

```
... /dev/shm/fastdds_port7411
... /dev/shm/fastdds_port7413
... /dev/shm/fastdds_<participant-id>
[PASS] Fast DDS hello_world over shared memory
```

**Cyclone DDS UDP**

`ddsperf` 走默认 UDP 路径，能看到约 1 M samples/s、约 100 Mb/s 的统计。

**Cyclone DDS + iceoryx（PSMX）**

先启动 `iox-roudi`，再挂载 `cyclonedds-shm.xml`：

```
Loading PSMX instance iox
... /dev/shm/root
... /dev/shm/iceoryx_mgmt
[PASS] Cyclone DDS (shm) pub/sub
```

配置使用 Cyclone 11 的现代写法（旧的 `<SharedMemory><Enable>` 已弃用）：

```xml
<General>
    <Interfaces>
        <PubSubMessageExchange type="iox" />
    </Interfaces>
</General>
```

注意：`psmx_iox` 插件通过 `LD_LIBRARY_PATH` 找到
`/opt/dds/cyclonedds/lib/libpsmx_iox.so`，因此必须在加载了 `env.sh` 的 shell 中运行。

## 共享内存管理

```bash
MSYS_NO_PATHCONV=1 docker exec dds-lab bash /usr/local/bin/ddslab/shm-status.sh
```

查看容量、段文件和 RouDi 进程。正常退出后 Fast DDS 会自动清理自己的
`/dev/shm/fastdds_*`；如果进程被强杀，可能有残留：

```bash
# 先确认没有相关进程在运行！
pkill -f iox-roudi
pkill -f ddsperf
pkill -f hello_world
rm -f /dev/shm/fastdds_* /dev/shm/sem.fastdds_*
rm -f /dev/shm/iceoryx_mgmt /dev/shm/root
```

容器 `/dev/shm` 只有 2 GiB，原因是 compose 中的 `shm_size: "2gb"`。iceoryx 默认
预留约 207 MiB，Fast DDS 每个 participant 约 0.5 MiB。需要更大压力测试时调大
`shm_size` 后重新 `docker compose up -d`。

## 网络与 Docker 配置（国内环境）

这套环境针对以下限制做了处理：

1. **Docker Hub 不可达**
   - 不从 registry 拉基础镜像。`scripts/import-base-image.sh` 从 USTC 下载
     `ubuntu-base-22.04.5-base-amd64.tar.gz`，用 `docker import` 生成
     `dds-lab-base:22.04`。
   - 需要重建该镜像时，在 Windows Git Bash 中运行：
     ```bash
     bash scripts/import-base-image.sh
     ```
   - 如果 Docker Hub 恢复可用，把 `.env` 中的 `BASE_IMAGE` 改成 `ubuntu:22.04`。

2. **GitHub 不可达**
   - `fetch-sources.sh` 使用 `codeload.github.com` 的 tarball，失败时回退到
     `ghproxy.net`。
   - iceoryx 的 cpptoml 依赖原本在 CMake configure 阶段执行
     `git clone https://github.com/skystrife/cpptoml.git`。`build-iceoryx.sh`
     会先把 tarball 下载到 `/build/downloads/cpptoml-0.1.1.tar.gz`，再把它
     注入 iceoryx 的 ExternalProject 模板，避免访问 github.com。
   - 该修改在源码重新解压后会自动重新应用。

3. **Windows 系统代理失效**
   - 当前 Windows 系统代理仍为 `127.0.0.1:7890`（`ProxyEnable=1`），但该端口
     没有进程监听；而且 7890 落在 WinNAT 的保留端口段 7872–7971 内，WSL2
     访问也不可靠。
   - Docker Desktop 的 `proxyHttpMode` 已改为 `manual`，HTTP/HTTPS override
     为空，因此容器直接连外网，绕过这个坏代理。
   - 如果以后启动 FlClash/Clash 并希望容器也走代理，把 Docker Desktop
     Settings → Resources → Proxies 改为手动并填写可用代理；**不建议**在代理
     未运行的情况下改回 `system`。
   - 如果不再需要系统代理，可在 Windows“设置 → 网络和 Internet → 代理”中关闭，
     或把 `HKCU\...\Internet Settings\ProxyEnable` 置 0。

4. **Docker 数据位置**
   - `docker-desktop-data` WSL 发行版位于 `E:\docker-data\wsl`。
   - 迁移前的备份 `E:\docker-data\docker-desktop-data.tar`（约 3.7 GiB）仍保留，
     确认环境稳定后可手动删除。

## 常见问题

**`iox-roudi: command not found` / 没有安装 RouDi**

RouDi 只在 iceoryx 以 `-DTOML_CONFIG=ON` 构建时生成。`build-iceoryx.sh` 已固定
该选项。若你手动改过源码/构建目录，重新执行：

```bash
/usr/local/bin/ddslab/build-all.sh iceoryx
```

**Cyclone DDS 没有加载 PSMX**

- 必须设置 `CYCLONEDDS_URI=file:///workspace/config/cyclonedds-shm.xml`；
  `run-cyclone-demo.sh shm` 会自动设置。
- `iox-roudi` 必须在运行。
- 检查 `/opt/dds/cyclonedds/lib/libpsmx_iox.so` 是否存在，以及
  `LD_LIBRARY_PATH` 是否包含 `/opt/dds/cyclonedds/lib`。

**Fast DDS 实验看不到 `/dev/shm`**

示例发送节奏是 100 ms/条，`--samples 10` 一秒内就结束。演示脚本已经改用 100 条
并在 1 秒时抓取映射；手动实验时也要在进程存活期间查看 `/proc/<pid>/maps`。

**`docker exec` 路径被 Git Bash 改写**

使用 `MSYS_NO_PATHCONV=1 docker exec ...`，或改用 PowerShell。

## 清理与重建

```bash
# 停止容器，保留数据卷（推荐）
docker compose stop

# 删除容器和网络，保留源码/构建/安装卷
docker compose down

# 彻底删除构建产物（源码、构建树、ccache、安装库都会丢失）
docker compose down -v
```

`down -v` 之后需要重新 `fetch-sources.sh` 和 `build-all.sh`。Fast DDS 完整构建
大约需要数分钟到十几分钟，取决于 CPU 和 ccache 状态。
