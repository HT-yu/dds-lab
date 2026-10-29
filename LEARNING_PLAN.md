# DDS 学习计划（基于 dds-lab）

> 目标：从“能跑 demo”到“能选型、能调 QoS、能抓包排障、能做性能对比”。
> 建议节奏：8 周，每周 6–8 小时（两次 × 3–4 小时）。可压缩为 4 周。
> 所有命令都在 `dds-lab` 容器内执行，除非特别标注“宿主”。

---

## 0. 先厘清一个概念

严格说，这个实验室里不是“三个 DDS 协议”：

- **DDS**（OMG 规范）定义数据中心发布/订阅的 API、数据模型和 QoS。
- **RTPS**（DDSI-RTPS）是 DDS 的线协议，让不同厂商的实现可以互通。
- **Fast DDS**（eProsima）和 **Cyclone DDS**（Eclipse）是两套独立的 DDS/RTPS 实现。
- **iceoryx** 不是 DDS 实现，而是进程间**共享内存 IPC**；Cyclone 通过 PSMX 插件使用它，
  Fast DDS 3.x 使用的是自己的 SHM 传输。

所以本计划实际覆盖：**一套 DDS 概念 + 两套实现 + 三条共享内存数据通路**。把 iceoryx 当成
“DDS 的零拷贝底座”来学，而不是第三种 DDS。

### 先修假设

C++11/17、CMake、Linux 进程/共享内存概念、UDP 与 multicast 基础。不要求读过 DDS 规范。

---

## 1. 学完后的验收标准

1. 能画出 DDS 实体模型（DomainParticipant / Topic / Publisher / DataWriter /
   Subscriber / DataReader），并解释 QoS 在哪个实体上生效。
2. 不抄示例，能独立写出 Fast DDS 和 Cyclone DDS 的 publisher/subscriber，包含自定义 IDL 类型。
3. 能用 `tcpdump` + Wireshark 抓到 RTPS 包，指出 SPDP、SEDP、DATA、HEARTBEAT、ACKNACK。
4. 能配置并解释至少 6 组 QoS 行为：reliability、durability、history、deadline、
   ownership、partition（外加 content filter）。
5. 能证明数据是否走了共享内存、是否零拷贝，并解释 Fast DDS SHM、Cyclone PSMX、
   iceoryx 原生 API 三者的差异。
6. 能用 `ddsperf` / Fast DDS `benchmark` 做吞吐和延迟测试，并排查
   “不匹配 / 丢样本 / deadline missed / SHM 未生效”。
7. 完成一个综合项目，产出一份 Fast DDS vs Cyclone DDS 的对比报告。

---

## 2. 总体路线

| 阶段 | 周次 | 主题 | 关键产出 |
| --- | --- | --- | --- |
| A. 建立闭环 | 第 1–2 周 | 概念模型 + 自己写 pub/sub | 架构图、两套 hello world |
| B. 协议机制 | 第 3–5 周 | 发现/RTPS、QoS、IDL/XTypes | pcap 分析、QoS 实验表、keyed topic |
| C. 传输与性能 | 第 6–8 周 | 共享内存、压测、故障排查、综合项目 | benchmark 表、排障手册、对比报告 |

学习原则：**阅读不超过 1/3，动手不少于 2/3**。每个实验都要改参数、记录差异，而不是只跑通。

---

## 3. 每周详细计划

### 第 1 周：建立全景图（环境 + 概念）

**目标**：知道每个进程、每条数据路径、每块 `/dev/shm` 分别属于谁。

**阅读（约 2 h）**

- OMG DDS 1.4 第 2 章（概念模型）：
  <https://www.omg.org/spec/DDS/1.4/>
- Fast DDS 文档“DDS Layer”总览：<https://fast-dds.docs.eprosima.com/>
- Cyclone DDS “About / Getting started”：<https://cyclonedds.io/docs/>
- iceoryx “Overview”：<https://iceoryx.io/>

**动手（约 4 h）**

```bash
# 宿主
cd /e/Code/dds-lab
docker compose ps
MSYS_NO_PATHCONV=1 docker exec -it dds-lab bash

# 容器
source /usr/local/bin/ddslab/env.sh
/usr/local/bin/ddslab/verify-install.sh
/workspace/experiments/run-all-smoke.sh
```

然后逐项拆开看：

```bash
/workspace/experiments/run-iceoryx-demo.sh
/workspace/experiments/run-fastdds-demo.sh
/workspace/experiments/run-cyclone-demo.sh udp
/workspace/experiments/run-cyclone-demo.sh shm
```

每个实验结束后，查看对应日志目录里的：

- `publisher.log` / `subscriber.log`：数据是否真的收到；
- `publisher-shm-maps.txt` / `subscriber-shm-maps.txt`：`/dev/shm` 映射；
- `shm.txt`：当时 `/dev/shm` 里的段文件；
- `roudi.log`：RouDi 分配了哪些 segment / mempool。

再用 `tmux` 手动观察 iceoryx：

```bash
tmux
# pane 1
iox-roudi
# pane 2
iox-cpp-publisher
# pane 3
iox-introspection-client      # TUI：看 mempool、port、process
```

观察 `/dev/shm`：

```bash
/usr/local/bin/ddslab/shm-status.sh
watch -n 1 'ls -lh /dev/shm'
```

**自测问题**

1. RouDi 负责什么？`/dev/shm/root` 和 `/dev/shm/iceoryx_mgmt` 分别存什么？
2. Fast DDS 的 demo 没有 RouDi，为什么也有 `/dev/shm/fastdds_*`？
3. Cyclone 的 UDP 模式和 SHM 模式分别依赖哪些进程/配置？
4. 三个 `run-*-demo.sh` 里，哪些会自己拉起 RouDi，哪些复用已有的？

**产出**：`workspace/notes/week01.md`，包含一张“进程 → 通信方式 → `/dev/shm` 段”的关系图，
以及上述四个问题的答案。

---

### 第 2 周：自己写第一个 pub/sub（两套实现）

**目标**：摆脱示例程序，独立创建 participant、topic、writer/reader，并自定义类型。

**阅读（约 2 h）**

- Fast DDS 3.x 的 “Writing a simple publisher and subscriber”。
  **注意**：网上大量教程是 Fast DDS 2.x，3.x 的 `create_publisher` 等签名已经变化。
- Cyclone DDS 的 “Getting started” 和 `examples/helloworld`。
- IDL 基础：`module`、`struct`、`sequence`、`string`、`@key`。

**参考源码**

```bash
/build/src/Fast-DDS/examples/cpp/hello_world/
/build/src/cyclonedds/examples/helloworld/
```

**工程布局**

```
/workspace/labs/02-hello/            # 源码（9p，方便编辑）
├── fastdds/  publisher.cpp subscriber.cpp CMakeLists.txt
└── cyclone/  publisher.c  subscriber.c  HelloWorld.idl  CMakeLists.txt

/build/labs/02-hello/                # 构建树（ext4）
```

**Fast DDS：最小 CMake**

```cmake
cmake_minimum_required(VERSION 3.22)
project(fastdds_hello LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)

find_package(fastcdr 2 REQUIRED)
find_package(fastdds 3 REQUIRED)

add_executable(pub pub.cpp)
target_link_libraries(pub fastdds fastcdr)
add_executable(sub sub.cpp)
target_link_libraries(sub fastdds fastcdr)
```

**Cyclone：IDL + 生成代码**

```bash
cd /workspace/labs/02-hello/cyclone
idlc -l c HelloWorld.idl          # 生成 HelloWorld.c / HelloWorld.h
```

```cmake
find_package(CycloneDDS REQUIRED)
add_executable(pub publisher.c HelloWorld.c)
target_link_libraries(pub CycloneDDS::ddsc)
```

**构建（两种实现都一样）**

```bash
cmake -S /workspace/labs/02-hello/fastdds -B /build/labs/02-hello/fastdds \
      -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build /build/labs/02-hello/fastdds -j

cmake -S /workspace/labs/02-hello/cyclone -B /build/labs/02-hello/cyclone \
      -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build /build/labs/02-hello/cyclone -j
```

**实验**

1. 相同的 topic 名和类型，自己写一对 pub/sub，确认收发包序号连续。
2. 只改 publisher 的 topic 名 → 观察“不匹配”。
3. 只在一边改 domain ID → 观察“不匹配”。
4. 记录两端启动先后对结果的影响（这会在第 4 周用 durability 解释）。

**验收**：能不看示例写出两套程序；能解释每一个 DDS 实体由谁创建、由谁销毁。

**产出**：`workspace/labs/02-hello/` + 一个简短 README（如何构建、如何运行、观察到的现象）。

---

### 第 3 周：RTPS 与发现机制

**目标**：把“为什么两个进程能自动找到对方”从黑盒变成可观察的报文序列。

**阅读（约 2 h）**

- DDSI-RTPS 2.5 第 8 章（Builtin Endpoints、Discovery）：
  <https://www.omg.org/spec/DDSI-RTPS/2.5/>
- Fast DDS “Discovery” 文档（简单发现、静态发现、Discovery Server）。
- Cyclone DDS “Discovery” 文档。

**实验（约 4 h）**

1. 观察端口占用：

```bash
ss -uanp | grep -E '7400|7401|7410|7411'
```

2. 抓包（容器已安装 tcpdump；Docker 默认能力集包含 `NET_RAW`）：

```bash
tcpdump -i any -nn -s 0 -w /workspace/logs/rtps-domain0.pcap \
        'udp portrange 7400-7420'
# 另开终端跑第 2 周自己写的 pub/sub，或者默认 demo
# Ctrl+C 结束抓包
```

3. 在 Windows 上用 Wireshark 打开 `E:\Code\dds-lab\workspace\logs\rtps-domain0.pcap`，
   启用 RTPS dissector，按时间顺序标注：
   - SPDP（participant 宣告）
   - SEDP（publication/subscription 宣告）
   - DATA（用户数据）
   - HEARTBEAT / ACKNACK（可靠传输）

4. 端口公式（RTPS well-known ports）：

```
SPDP 组播   = 7400 + 250 * domainId
发现单播    = 7400 + 250 * domainId + 10
用户组播    = 7400 + 250 * domainId + 1
用户单播    = 7400 + 250 * domainId + 11
```

domain 0 时即 `7400 / 7410 / 7401 / 7411`。改 domain 再抓一次，验证公式。

5. 静态发现 / Discovery Server（Fast DDS 自带示例）：

```bash
find /opt/dds/fastdds/share/fastdds/examples/cpp -path '*discovery*' -name README.md
```

6. **跨实现互通（进阶）**：用第 2 周自己写的程序，让 Fast DDS publisher 与
   Cyclone subscriber 在同一个 domain 互通。前提是 topic 名、type 名、CDR 布局和 QoS 兼容；
   注意共享内存不能跨实现互通，必须走 UDP。

**验收**

- 能解释一次“启动 → 发现 → 匹配 → 收到第一条数据”的报文顺序。
- 能根据端口号反推 domain ID。
- 能说清静态发现和动态发现的取舍。

**产出**：pcap 文件 + 一张时序图 + 200 字分析。

---

### 第 4 周：QoS 深入

**目标**：让 QoS 从“配置项”变成“可预测的行为”。

**阅读（约 2 h）**

- DDS 1.4 的 QoS 章节（至少 RELIABILITY / DURABILITY / HISTORY / DEADLINE /
  LIVELINESS / OWNERSHIP / RESOURCE_LIMITS）。
- `/opt/dds/fastdds/share/fastdds/examples/cpp/configuration/README.md`（已安装，强烈建议）。
- Cyclone 的 QoS XML 配置文档。

**工具**：Fast DDS 的 `configuration` 示例已经把常用 QoS 做成了命令行参数：

```bash
CFG=/opt/dds/fastdds/share/fastdds/examples/cpp/configuration/bin/configuration
$CFG --help
```

**实验 4.1 Durability（VOLATILE vs TRANSIENT_LOCAL）**

```bash
# 先启动 publisher，晚 1 秒再启动 subscriber
$CFG publisher --transient-local -i 200 -s 25 &
sleep 1
$CFG subscriber --transient-local
```

对比不加 `--transient-local` 的结果：迟到的 subscriber 能否收到历史样本？历史上限由 history 决定。

**实验 4.2 History（KEEP_LAST 深度）**

```bash
$CFG publisher -i 1 -s 5000 -m 1024 -t UDPv4 &
sleep 1
$CFG subscriber -k 1 -t UDPv4
```

把 subscriber 改成 `-k 100` 或 `--keep-all`，比较收到的样本序号是否连续。解释
“样本被覆盖”发生在 writer 侧还是 reader 侧。

**实验 4.3 Reliability（BEST_EFFORT vs RELIABLE）**

用 `tc netem` 在 `lo` 上注入丢包和延迟（Compose 已给 `NET_ADMIN`）：

```bash
tc qdisc add dev lo root netem loss 5% delay 20ms

# 对照组：不加 -r，默认 best effort
$CFG publisher -t UDPv4 -i 1 -s 2000 &
$CFG subscriber -t UDPv4

# 实验组：两端都加 -r
$CFG publisher -r -t UDPv4 -i 1 -s 2000 &
$CFG subscriber -r -t UDPv4

tc qdisc del dev lo root
```

必须用 `-t UDPv4`：SHM 不经过网络栈，netem 影响不到它——这本身就是一条重要结论。

**实验 4.4 Deadline**

```bash
$CFG subscriber --deadline 100 &
$CFG publisher --deadline 100 -i 300 -s 10
```

观察 subscriber 的 deadline-missed 回调。

**实验 4.5 Ownership（exclusive）**

```bash
$CFG subscriber -o &
$CFG publisher -o --ownership-strength 10 -i 200 -s 20 &
$CFG publisher -o --ownership-strength 5  -i 200 -s 20
```

只有高 strength 的 writer 的数据会被交付。

**实验 4.6 Partition**

```bash
$CFG subscriber -p B &
$CFG publisher  -p A -s 5      # 不匹配
$CFG publisher  -p A -s 5 &    # 改 subscriber 为 -p A 后匹配
```

**实验 4.7 Content Filter**

```bash
CF=/opt/dds/fastdds/share/fastdds/examples/cpp/content_filter/bin/content_filter
$CF subscriber --lower-bound 3 --upper-bound 5
$CF publisher
```

**实验 4.8 Cyclone 的等价配置**

用 XML 配 RELIABLE + TRANSIENT_LOCAL + KEEP_LAST(10)：

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<CycloneDDS xmlns="https://cdds.io/config">
  <Domain id="any">
    <QoS>
      <Reliability><Kind>RELIABLE</Kind></Reliability>
      <Durability><Kind>TRANSIENT_LOCAL</Kind></Durability>
      <History><Kind>KEEP_LAST</Kind><Depth>10</Depth></History>
    </QoS>
  </Domain>
</CycloneDDS>
```

```bash
export CYCLONEDDS_URI=file:///workspace/labs/04-qos/reliable.xml
```

**验收**

- 能说出 QoS 的 offered/requested 兼容规则（例如 RELIABLE subscriber + BEST_EFFORT
  publisher 会怎样）。
- 能用“改一个 QoS → 观察一个现象”的方式复现上述至少 4 个实验。
- 能解释为什么 SHM 下 netem 不影响结果。

**产出**：`workspace/labs/04-qos/` 下的实验脚本 + `workspace/notes/week04-qos.md`
（每条 QoS 一行：配置、预期、实际、解释）。

---

### 第 5 周：IDL、类型系统与 XTypes

**目标**：掌握 DDS 的类型匹配规则，理解 keyed topic 和类型演进。

**阅读（约 2 h）**

- OMG IDL 4.2 基础语法；DDS-XTypes 概念（assignability、extensibility）。
- Cyclone `idlc` 文档。
- Fast DDS “Type System / XTypes” 文档。

**实验（约 4 h）**

1. 写一个带 key 的 IDL：

```idl
module sensor {
  @topic
  struct Reading {
    @key long id;
    double value;
    string label;
  };
};
```

```bash
idlc -l c sensor.idl
```

在 Cyclone 里创建两个不同的 key（`id=1/2`），观察 instance handle 的变化。
思考：key 的哈希如何影响 writer 侧历史缓存。

2. Fast DDS 的 keyed topic 示例：

```bash
find /opt/dds/fastdds/share/fastdds/examples/cpp/topic_instances -maxdepth 2 -type f
/opt/dds/fastdds/share/fastdds/examples/cpp/topic_instances/bin/topic_instances --help
```

3. XTypes 演进示例：

```bash
/opt/dds/fastdds/share/fastdds/examples/cpp/xtypes/bin/xtypes --help
```

对比 `xtypes_minimal_profile.xml` 与 `xtypes_complete_profile.xml` 的行为。

4. 故意制造类型不匹配：改字段名/字段类型但保留 topic 名，观察是否能匹配。
   - type name 相同、结构不同 → 是否匹配取决于 XTypes 的 assignability；
   - 不同实现之间，CDR 布局必须一致。

5. （可选）安装 `fastddsgen`：它需要 Java，镜像未安装。可以先
   `apt-get update && apt-get install -y openjdk-17-jre-headless`，再从 GitHub
   下载 Fast-DDS-Gen。网络受限时跳过，用 Cyclone 的 `idlc` + Fast DDS 示例里已生成的类型
   同样能完成本周目标。

**验收**：能解释 instance handle、key hash、type name 匹配、XTypes 兼容性分别解决什么问题。

**产出**：IDL + 生成代码 + `workspace/notes/week05-types.md`。

---

### 第 6 周：共享内存与零拷贝

**目标**：搞清三条 SHM 路径，并能用证据判断“到底走没走共享内存”。

**阅读（约 2 h）**

- iceoryx：RouDi、segment、mempool、chunk、loan/unloan、publisher history。
- Fast DDS：SHM transport、data-sharing、intra-process，以及默认传输选择顺序。
- Cyclone：PSMX 架构与 `psmx_iox` 插件。

**实验（约 5 h）**

1. **iceoryx 原生 API**：读
   `/build/src/iceoryx/iceoryx_examples/icedelivery/` 的 publisher/subscriber 源码，
   重点看 `loan()` → 写 payload → `publish()` → subscriber `take()`。
   运行已安装版本并对照源码：

```bash
iox-roudi &
iox-cpp-publisher-helloworld &
iox-cpp-subscriber-helloworld
```

2. **Fast DDS 传输选择**：

```bash
DM=/opt/dds/fastdds/share/fastdds/examples/cpp/delivery_mechanisms/bin/delivery_mechanisms
$DM --help

$DM subscriber -m SHM &
$DM publisher  -m SHM -s 100

$DM subscriber -m UDPv4 &
$DM publisher  -m UDPv4 -s 100

$DM subscriber -m DATA-SHARING &
$DM publisher  -m DATA-SHARING -s 100

# 同进程内共享 payload pool
$DM pubsub -m INTRA-PROCESS
```

每次运行后检查：

```bash
ls -lh /dev/shm
# 在进程存活期间
grep /dev/shm /proc/<pid>/maps
```

3. **Cyclone 的两条路径**：

```bash
# UDP
/workspace/experiments/run-cyclone-demo.sh udp
# iceoryx PSMX
/workspace/experiments/run-cyclone-demo.sh shm
```

对比日志里的 `Loading PSMX instance` 和 subscriber 的 `/proc/<pid>/maps`。

4. **量化对比**：至少测三档 payload（64 B、4 KiB、1 MiB），三种传输
   （Cyclone UDP、Cyclone PSMX、Fast DDS SHM），记录吞吐和延迟。可用：

```bash
ddsperf -T S4k -D 10 pub &
ddsperf -T S4k -D 12 sub

BENCH=/opt/dds/fastdds/share/fastdds/examples/cpp/benchmark/bin/benchmark
$BENCH subscriber -m SMALL -t SHM -s 10000 &
$BENCH publisher  -m SMALL -t SHM -s 10000
```

`benchmark` 的 `-m` 可选 `NONE / SMALL(16K) / MEDIUM(512K) / BIG(8M)`，
`-t` 可选 `DEFAULT / SHM / UDPv4`。

**关键问题**

- 零拷贝发生在哪一步？publisher 的 `loan` 和 subscriber 的 `take` 分别有没有 memcpy？
- Fast DDS 什么时候从 SHM 回退到 UDP？（跨主机、段不存在、payload 超过阈值等）
- 为什么 SHM 不能跨实现互通？
- Cyclone PSMX 与 iceoryx 原生 API 的抽象层级差在哪？

**验收**：能用 `/proc/maps` + `/dev/shm` + 代码路径三方面证明一次传输是否走 SHM，
并解释是否零拷贝。

**产出**：三档 payload × 三种传输的 benchmark 表 + `workspace/notes/week06-shm.md`。

---

### 第 7 周：性能、故障与排障

**目标**：形成一套“症状 → 检查点 → 结论”的排障路径。

**阅读（约 1–2 h）**

- `ddsperf` 帮助（`ddsperf -h`）与 Cyclone 性能文档。
- Fast DDS 的 flow control、async publish、fragmentation 文档。
- Cyclone tracing 配置（`<Tracing><Verbosity>`）。

**实验（约 5 h）**

```bash
BENCH=/opt/dds/fastdds/share/fastdds/examples/cpp/benchmark/bin/benchmark
```

1. **吞吐与延迟基线**

```bash
# Cyclone，不同 payload
for T in S16 S4k S32k; do
  ddsperf -T $T -D 8 pub &
  ddsperf -T $T -D 10 sub | tail -3
  wait
done

# 延迟
ddsperf -D 6 pong &
ddsperf -l -D 5 ping
```

2. **Fast DDS 大样本与传输**

```bash
$BENCH subscriber -m BIG -t UDPv4 -s 2000 &
$BENCH publisher  -m BIG -t UDPv4 -s 2000
```

观察 UDP 分片（8 MiB 样本会远超 MTU），再换 `-t SHM` 对比。记录吞吐差异和 CPU。

3. **故障注入**

```bash
# Cyclone SHM 运行中杀掉 RouDi
/workspace/experiments/run-cyclone-demo.sh shm &
sleep 3
pkill -x iox-roudi
# 观察两端日志：已建立的连接如何表现？重新启动 RouDi 后能否恢复？
```

对 Fast DDS 重复“强杀进程”实验，检查 `/dev/shm/fastdds_*` 是否残留，以及新 participant
是否受影响。

4. **发现风暴**：同时启动 20 个 participant（可以循环启动 `hello_world`），用
   `top` / `ss` 观察 CPU 和发现流量。思考 `initial_peers`、静态发现、Discovery Server
   分别解决什么问题。

5. **日志与追踪**

```bash
# Cyclone：把 cyclonedds-shm.xml 的 Verbosity 改成 finest，观察发现细节
# Fast DDS：用 XML 配置 log（参考 configuration 示例的 profile）
# iceoryx：用 iox-introspection-client 观察 mempool 是否耗尽
```

6. **写排障手册**，至少覆盖以下症状：
   - 两端都启动了但收不到数据；
   - 收到了数据但序号有空洞；
   - deadline missed 持续触发；
   - 预期走 SHM 但 `/dev/shm` 里没有对应段；
   - 进程退出后 `/dev/shm` 残留；
   - RouDi 不在时 Cyclone PSMX 启动失败。

**验收**：给出任一症状，能在 10 分钟内定位到 domain/topic/type/QoS/传输层中的哪一层。

**产出**：`workspace/notes/week07-troubleshooting.md`。

---

### 第 8 周：综合项目与对比报告

**目标**：把前 7 周的能力合成一个可展示的成果。

任选一个题目（推荐 A）：

**A. 多传感器数据管道**

三个话题、三种 QoS 需求：

| 话题 | 载荷 | 频率 | QoS 设计 |
| --- | --- | --- | --- |
| camera | 1 MiB | 10 Hz | best-effort + SHM，允许丢帧 |
| lidar | 64 KiB | 20 Hz | reliable + SHM |
| control | 64 B | 100 Hz | reliable + deadline 20 ms |

要求：

- 用 Fast DDS 和 Cyclone DDS 各实现一版；
- 记录 CPU、内存、端到端延迟、吞吐；
- 解释每个 QoS 选择的理由；
- 故意制造一次故障（丢包/杀 RouDi/慢订阅者），展示系统行为。

**B. 跨实现网关**

Fast DDS ↔ Cyclone 通过 UDP 互通，本地再用 SHM 接一个监控进程。
重点解释类型匹配、QoS 兼容和 SHM 不可跨实现的原因。

**C. 共享内存故障恢复**

围绕 RouDi 生命周期做实验：启动顺序、崩溃、残留段、恢复策略。
产出一份“生产环境部署注意事项”。

**报告模板（2–3 页）**

1. 实验拓扑与进程图
2. 类型与 QoS 选型理由
3. 性能数据（表格 + 结论）
4. 遇到的问题与定位过程
5. Fast DDS vs Cyclone DDS：API、配置方式、工具链、性能、生态（ROS 2 默认 RMW 是 Fast DDS，Cyclone 是常用替代）
6. 如果要做产品选型，你会选谁，为什么

---

## 4. 学习资源

**规范**

- OMG DDS 1.4：<https://www.omg.org/spec/DDS/1.4/>
- DDSI-RTPS 2.5：<https://www.omg.org/spec/DDSI-RTPS/2.5/>
- IDL 4.2：<https://www.omg.org/spec/IDL/4.2/>

**实现文档**

- Fast DDS：<https://fast-dds.docs.eprosima.com/>
- Cyclone DDS：<https://cyclonedds.io/docs/>
- iceoryx：<https://iceoryx.io/>

**本机已有的“离线资料”**

- Fast DDS 示例与 README：`/opt/dds/fastdds/share/fastdds/examples/cpp/`
- Fast DDS 示例源码：`/build/src/Fast-DDS/examples/cpp/`
- Cyclone 示例源码：`/build/src/cyclonedds/examples/`（helloworld、roundtrip、throughput、dynsub、dyntype、listtopics）
- iceoryx 示例源码：`/build/src/iceoryx/iceoryx_examples/`（icedelivery、iceperf、waitset、request_response、introspect）
- 规范/文档源文件也在各自的 `/build/src` 里，可全文搜索。

**工具**

- Wireshark RTPS dissector（分析第 3 周的 pcap）
- `ddsperf`、Fast DDS `benchmark`、iceoryx `iceperf`
- `iox-introspection-client`、`/proc/<pid>/maps`、`strace`

---

## 5. 环境速查

```bash
# 宿主：进入容器
cd /e/Code/dds-lab
docker compose up -d
MSYS_NO_PATHCONV=1 docker exec -it dds-lab bash

# 容器：加载环境（交互式 shell 已自动加载）
source /usr/local/bin/ddslab/env.sh

# 安装自检 / 冒烟
/usr/local/bin/ddslab/verify-install.sh
/workspace/experiments/run-all-smoke.sh

# 共享内存状态
/usr/local/bin/ddslab/shm-status.sh

# 重新构建（改过源码或版本后）
/usr/local/bin/ddslab/build-all.sh iceoryx
/usr/local/bin/ddslab/build-all.sh fastdds cyclonedds
JOBS=4 /usr/local/bin/ddslab/build-all.sh

# 日志位置（Windows 也能直接看）
# E:\Code\dds-lab\workspace\logs\
```

注意：

- 宿主 Git Bash 里 `docker exec` 带容器路径时要加 `MSYS_NO_PATHCONV=1`。
- 实验源码放 `/workspace`，构建树放 `/build`，不要反过来。
- `/dev/shm` 只有 2 GiB；大样本压测前先 `shm-status.sh`。
- 清残留段前先确认没有 `iox-roudi` / `ddsperf` / `hello_world` 在跑。

---

## 6. 进度清单

- [ ] 第 1 周：跑通全部 demo，画出进程/共享内存关系图
- [ ] 第 2 周：独立写出 Fast DDS 与 Cyclone 的 pub/sub
- [ ] 第 3 周：抓到并解释 SPDP/SEDP/DATA/HEARTBEAT/ACKNACK
- [ ] 第 3 周（进阶）：Fast DDS ↔ Cyclone 跨实现互通
- [ ] 第 4 周：完成 durability / history / reliability / deadline / ownership / partition 实验
- [ ] 第 4 周：用 Cyclone XML 复现至少 2 个 QoS 行为
- [ ] 第 5 周：完成 keyed topic 与 XTypes 实验
- [ ] 第 6 周：用映射和代码路径证明一次零拷贝
- [ ] 第 6 周：完成三档 payload × 三种传输的 benchmark
- [ ] 第 7 周：写出排障手册并复现至少 4 个故障场景
- [ ] 第 8 周：完成综合项目与对比报告

---

## 7. 学习建议

1. **每个实验只改一个变量**，把命令、预期、实际、解释写进 notes。DDS 的问题大多来自
   “多个因素同时变了”。
2. **先 Cyclone 后 Fast DDS**：Cyclone 是 C API，层次少，更容易看清实体关系；
   Fast DDS 的 C++ API 更工程化，适合学 QoS 配置和 SHM 策略。
3. **不要通读 RTPS 规范**：第 8 章 + 实际抓包足够建立直觉，遇到细节再查。
4. **把“不匹配”当成最好的老师**：topic/type/domain/QoS 四层各制造一次不匹配，
   比读十页文档记得牢。
5. **每两周做一次回顾**：不看笔记，画一遍数据路径，讲清 QoS 兼容规则；
   讲不出来的地方就是下一周要补的。
