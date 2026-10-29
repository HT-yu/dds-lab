# 深入 DDS：发现机制与内存管理（源码级学习路线）

> 面向已经用过 Fast DDS / Cyclone DDS、看过部分源码，正在自研类 ROS 2 框架的中间件开发者。
> 入门内容见 `LEARNING_PLAN.md`；本文不重复 API 用法，只讨论机制、源码路径和可复现实验。

**版本与行号约定**

| 组件 | 版本 | 源码根 |
| --- | --- | --- |
| Fast DDS | v3.6.2 | `/build/src/Fast-DDS` |
| Cyclone DDS | 11.0.1 | `/build/src/cyclonedds` |
| iceoryx | v2.0.8 | `/build/src/iceoryx` |

文中 `文件:行号` 都基于上述 tag。换版本或重新解压源码后用函数名重新定位，例如：

```bash
grep -n "PDPSimple::announceParticipantState" \
    /build/src/Fast-DDS/src/cpp/rtps/builtin/discovery/participant/PDPSimple.cpp
grep -n "topickind_qos_match_p_lock" \
    /build/src/cyclonedds/src/core/ddsi/src/ddsi_endpoint_match.c
```

---

## 0. 这份文档怎么用

不要把它当"读完就会"的教程。它是一组**问题 + 实验 + 源码坐标**。正确用法是：

1. 每周挑一个问题；
2. 先写下你的预测（报文数量、耗时、内存曲线、哪一行拒绝匹配）；
3. 做实验验证；
4. 预测错了，才去读对应源码，把错的原因写进结论；
5. 每周产出一张时序图或状态机图。

六周日程见第 6 节。每周 6–8 小时足够，前提是**只追一条调用链**。

---

## 1. 学完之后应该能回答的问题

这些是自研框架真正会踩到的问题。第 7 节有对应自测题。

**发现**

1. 一个 participant 从创建到第一个 reader 收到数据，报文序列是什么？时间花在哪几段？
2. lease 到期由哪个线程、哪个函数发现？删除一个远端 participant 会级联删除哪些对象？
3. QoS 不匹配时，是发现阶段还是匹配阶段拒绝？拒绝原因如何在代码里表示、如何通知应用？
4. 100 个 participant 同域时，发现报文量级是多少？组播、initial peers、Discovery Server 各自差多少？
5. 为什么"进程还活着但 CPU 被占满"也会导致对端认为它掉线？lease 和 heartbeat 分别管什么？

**内存**

6. 一个 sample 从 `write()` 到对端 `read()` 经过几次拷贝？每次拷贝的所有者是谁？
7. `PREALLOCATED` / `PREALLOCATED_WITH_REALLOC` / `DYNAMIC_REUSABLE` 分别在什么条件下 malloc？
8. loan 出去的 buffer 什么时候可以安全回收？跨进程 loan 的归还责任在谁？
9. 慢订阅者 + RELIABLE + KEEP_ALL 时，writer 的内存如何增长？阻塞点在哪一行？
10. Fast DDS 的 SHM transport、data-sharing、Cyclone 的 PSMX/iceoryx 三者，哪些是零拷贝，哪些只是"把拷贝挪到共享内存"？

---

## 2. 方法：四步闭环

每一轮只回答**一个**具体问题：

| 步骤 | 时间 | 产出 |
| --- | --- | --- |
| 1. 规范建模 | 1–2 h | 读 DDSI-RTPS 2.5 / DDS 1.4 的对应小节，写下预测 |
| 2. 报文观测 | 1 h | pcap + 时间线，先看现象再看代码 |
| 3. 源码纵向追读 | 2–3 h | 从 API 入口沿一条调用链走到出口，画时序图 |
| 4. 扰动实验 | 2 h | 改一个参数或注入故障，验证/推翻第 3 步的结论 |

**规范只读需要的章节**，不要通读：

- DDSI-RTPS 2.5 §8.4（builtin endpoints、SPDP/SEDP 的 PID 列表）、§8.4.12–8.4.15（liveliness）、§9.3（writer/reader 行为）、§9.6.1（端口）。
- DDS 1.4 §2.2（QoS）、§2.3（listener/status）、§2.2.3（RxO 兼容性规则）。

**反模式**（会浪费你两周）：

- 从 `src/` 第一行开始读；
- 同时读两个实现；
- 只读代码不画图 —— 一周后什么都不剩；
- 把 Release 构建里的性能数字当成机制结论。

**一个完整的推演示例（lease 过期）**

1. 预测：订阅进程被 `SIGSTOP` 后不再发 SPDP，发布端在 lease（Fast DDS 20 s）后删除远端 participant，匹配数降为 0；恢复后重新发现。
2. 观测：`tcpdump` 看 SPDP 停止时刻；应用层看 matched 状态；`gdb` 断在 `PDP::remove_remote_participant`。
3. 源码：`PDP::check_remote_participant_liveliness` → 超时 → `remove_remote_participant` → 级联删除 proxy endpoints → 通知 listener。
4. 扰动：把 lease 改成 5 s，重复；再改成 `DURATION_INFINITY`，观察永不掉线。

---

## 3. 实验环境：可调试构建与观测工具

### 3.1 现有构建不够用

`build-*.sh` 默认 `Release`，没有 `-g`：gdb 只能看到导出符号，**不能按行下断点、看不到局部变量**。所有源码级实验都需要一份带调试信息的并行构建。

### 3.2 并行构建（不破坏现有环境）

构建脚本现在支持 `DDSLAB_BUILD_TYPE`，配合独立的构建目录和安装前缀即可并存：

```bash
# 容器内：先激活调试前缀，再构建
source /usr/local/bin/ddslab/env-debug.sh
/usr/local/bin/ddslab/build-all.sh fastcdr fastdds cyclonedds
```

说明：

- **不能只 `export DDS_PREFIX=/opt/dds-debug` 就构建**：镜像的 `ENV` 已显式导出
  `FASTCDR_PREFIX` / `FASTDDS_PREFIX` / `CYCLONEDDS_PREFIX`，`build-*.sh` 只认这三个
  变量，不会从 `DDS_PREFIX` 推导。只改 `DDS_PREFIX` 的结果是调试构建被装进 Release
  前缀 `/opt/dds`，覆盖掉冒烟测试用的库。`env-debug.sh` 已经显式设置三者，所以先
  `source` 它再构建。
- `RelWithDebInfo` 有 `-g` 且保留优化，适合 95% 的断点/回溯；某些模板代码变量会被优化掉时，再单独用 `Debug` 重建对应组件。
- iceoryx 不必重建：RouDi 很少需要单步，且 Debug 版体积大。
- **性能数字只从 Release 构建取**；调试构建只用于看行为。
- 如果误把调试库装进了 `/opt/dds`，用与上面对应的 Release 构建树重新安装即可
  （`source env.sh && build-all.sh fastcdr fastdds cyclonedds`，只需几秒）。

激活与切回：

```bash
source /usr/local/bin/ddslab/env-debug.sh     # DDS_PREFIX=/opt/dds-debug
# 回到 Release
unset DDS_PREFIX BUILD_DIR ICEORYX_PREFIX FASTCDR_PREFIX FASTDDS_PREFIX CYCLONEDDS_PREFIX DDSLAB_ENV_LOADED
source /usr/local/bin/ddslab/env.sh
```

验证调试信息（本环境两套实现都已验证）：

```bash
gdb -batch -ex 'info line dds_write_impl' /opt/dds-debug/cyclonedds/lib/libddsc.so.11
# Line 809 of "/build/src/cyclonedds/src/core/ddsc/src/dds_write.c" ...

gdb -batch -ex 'info line EDPSimple::initEDP' \
    -ex 'info line PDP::announceParticipantState' \
    /opt/dds-debug/fastdds/lib/libfastdds.so
# Line 129 of ".../EDPSimple.cpp"
# Line 588 / Line 598 of ".../PDP.cpp"   （两个重载各一行）
```

### 3.3 工具矩阵

| 工具 | 本环境 | 用途 |
| --- | --- | --- |
| gdb | 有 | 断点、调用链、线程栈、条件断点计数 |
| tcpdump | 有 | RTPS 报文时间线（发现主要靠它） |
| strace / ltrace | 有 | 系统调用、malloc/free 计数 |
| valgrind / heaptrack | 需安装 | 堆曲线、分配火焰图 |
| tshark | 需安装 | pcap 结构化分析；没有就用 tcpdump + Wireshark 图形界面 |
| perf | 不可用 | 容器内核与 `linux-tools` 不匹配，不要在这上面浪费时间 |

可选安装：

```bash
DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y valgrind heaptrack tshark
```

### 3.4 观测面与盲区

| 观测面 | 怎么做 | 能看到什么 / 盲区 |
| --- | --- | --- |
| UDP 报文 | `tcpdump -i eth0 -nn -tt 'udp portrange 7400-7600'` | SPDP 一定可见；SEDP/用户数据在 Fast DDS 默认配置下可能走 SHM，看不见 |
| 强制 UDP | `FASTDDS_BUILTIN_TRANSPORTS=UDPv4` | 让 Fast DDS 只走 UDP，便于对照（源码：`RTPSParticipantImpl.cpp:98`） |
| Cyclone 内建 pcap | `<Tracing><PacketCaptureFile>` | 不需要 tcpdump，且带 Cyclone 自己的收发视角 |
| Cyclone 日志 | `<Tracing><Verbosity>finest</Verbosity><OutputFile>` | `discovery` / `plist` / `whc` / `rhc` 分类非常有用 |
| Fast DDS 日志 | 代码里 `Log::SetVerbosity(Log::Info)` | 3.6 没有日志级别的环境变量，只能改程序或用断点 |
| 共享内存 | `/dev/shm`、`/proc/<pid>/maps`、`smaps_rollup` | 段名、映射大小；看不到 chunk 内部状态 |
| iceoryx 内部 | `iox-introspection-client --mempool` | 每个 mempool 的 chunk 使用量，M6 的核心工具 |
| 线程与栈 | `gdb -p`、`thread apply all bt` | 发现回调跑在哪个线程，是否是 DDS 内部线程 |
| 应用状态 | matched / incompatible QoS status | 最终事实，但看不到原因 |

**关键盲区**：单容器内所有进程共享网络命名空间，组播走同一个接口；Fast DDS 默认优先 SHM。**任何"报文数量"结论都要先写明传输配置**，否则不可比。

### 3.5 gdb 常用套路

```bash
# 例子：观察发现通告
gdb -q --args /opt/dds/fastdds/share/fastdds/examples/cpp/hello_world/bin/hello_world publisher
(gdb) set pagination off
(gdb) set breakpoint pending on
(gdb) break PDPSimple::announceParticipantState
(gdb) commands
> silent
> bt 3
> continue
> end
(gdb) run
```

- 断点计数：`ignore 1 4` 跳过前 4 次；或 `commands` 里 `printf` 计数。
- 条件断点：Cyclone 的 `reason` 是 `dds_qos_policy_id_t*`，可以写
  `break ddsi_endpoint_match.c:252 if *reason != 0`；Fast DDS 的 `reason` 是
  `MatchingFailureMask`（bitset），用 `finish` 返回后 `p reason` / `p incompatible_qos` 更直观。
- 多线程：`set scheduler-locking step` 只让自己线程跑；`thread apply all bt` 看全局。
- 共享库断点：进程启动前库未加载，务必 `set breakpoint pending on`。
- 打印 GUID：Fast DDS 用 `PGUID` 宏风格，Cyclone 有 `PGUIDFMT`，gdb 里按字段打印即可。

---

## 4. 发现机制

### 4.1 先建立可验证的模型

RTPS 发现分两层，任何实现都一样：

```
SPDP (participant discovery)
  └─ 通告：GUID prefix、lease、builtin endpoint 集合、locator
       ↓ 建立 proxy participant
SEDP (endpoint discovery)
  └─ 通告：每个 writer/reader 的 topic、type、QoS、locator
       ↓ 逐对做 QoS/类型匹配，建立 writer-reader 关联
用户数据
```

必须先记住的四个事实：

1. **GUID = prefix(12B) + entityId(4B)**。participant 的 entityId 固定；builtin writer/reader 有固定的 well-known entityId（SPDP/SEDP/PMD）。
2. **发现是"通告 + 租约"**，不是请求-响应。新 participant 靠初始突发通告被发现，之后靠周期通告续租。
3. **端口由 domain 和 participant index 决定**：`7400 + 250*domain` 是 SPDP 组播；`+10` 是元流量单播基数（再加 `2*participantId`）；`+1/+11` 是用户流量组播/单播。
4. **匹配是两两的、双向的**：writer 的 offered QoS 必须满足 reader 的 requested QoS（RxO），类型必须兼容。

### 4.2 报文与时间线

一次典型的首次发现（单机、组播可用）：

```
t=0ms     A: SPDP DATA(p)  -> 239.255.0.1:7400      (初始通告 #1)
t=0ms     B: SPDP DATA(p)  -> 239.255.0.1:7400
t=~1ms    A: SPDP DATA(p)  -> B:7410 (单播)          (回应/定向通告)
t=100ms   A: SPDP #2, B: SPDP #2
...
t=400ms   初始通告结束（Fast DDS 默认 5 次 × 100ms）
t=~500ms  A/B: SEDP DATA(w)/DATA(r) 通告端点
t=~500ms  匹配完成 -> writer 可能发 HEARTBEAT
t=3s      Fast DDS 周期通告（leaseDuration_announcementperiod）
```

抓包与统计：

```bash
mkdir -p /workspace/logs/adv
tcpdump -i eth0 -nn -tt -w /workspace/logs/adv/e1.pcap 'udp portrange 7400-7600' &
# 跑实验
sleep 15; kill %1

# 不装 tshark 也能看时间线
tcpdump -nn -tt -r /workspace/logs/adv/e1.pcap | head -n 50

# 统计每秒包数（按源地址）
tcpdump -nn -tt -r /workspace/logs/adv/e1.pcap 2>/dev/null \
  | awk '{print $2, $4}' | sed 's/:[0-9]*$//' | sort | uniq -c | sort -rn | head
```

**实测注意（本环境）**：`tcpdump -i any` 会把同一个组播包在 `lo` 和 `eth0` 上各抓一次，一个包变成三条记录
（`lo In`、`eth0 Out`、`eth0 M`）。本仓库实测 4 秒抓出 96 条记录，实际只有约 32 个包。
**统计包数时固定用 `-i eth0`**，或用 `-i any` 时按"源端口 + 时间戳"去重，否则结论会放大 3 倍。

### 4.3 Fast DDS 源码路线

**启动与通告**

| 阶段 | 入口 | 说明 |
| --- | --- | --- |
| 创建 participant | `BuiltinProtocols::initBuiltinProtocols` (`BuiltinProtocols.cpp:72`) | 按 `DiscoverySettings` 选择 SIMPLE/SERVER/CLIENT/BACKUP |
| PDP 初始化 | `PDPSimple::init` (`PDPSimple.cpp:156`) | 填 `ParticipantProxyData`、创建 builtin 端点 |
| 构造自身通告 | `PDPSimple::initializeParticipantProxyData` (`PDPSimple.cpp:107`) | builtin endpoint 集合、lease、locator 都在这里 |
| 创建 SPDP 端点 | `PDPSimple::createPDPEndpoints` (`PDPSimple.cpp:325`) | SPDP writer（best-effort，组播）+ SPDP reader |
| 发送通告 | `PDPSimple::announceParticipantState` (`PDPSimple.cpp:260/268`) → `PDP::announceParticipantState` (`PDP.cpp:585/593`) | 初始 5×100 ms，之后每 3 s；也可被"新 participant 出现"触发 |

**接收与建立远端 participant**

| 阶段 | 入口 | 说明 |
| --- | --- | --- |
| 收到 SPDP DATA | `PDPListener::on_new_cache_change_added` (`PDPListener.cpp:56`) | 在 receiver 线程的反序列化回调里 |
| 处理 alive | `PDPListener::process_alive_data` (`PDPListener.cpp:189`) | 创建/更新 `RTPSParticipantProxyData` |
| 初始化 EDP | `EDPSimple::initEDP` (`EDPSimple.cpp:127`) | 建立 SEDP builtin 端点，准备端点通告 |
| 远端 SEDP 数据 | `EDPSimple::assignRemoteEndpoints` (`EDPSimple.cpp:750`) | 把远端 writer/reader 变成 proxy |
| 匹配 | `EDP::pairingReader` (`EDP.cpp:1123`)、`EDP::pairing_writer_proxy_with_local_reader` (`EDP.cpp:1583`)、`EDP::pairing_remote_writer_with_local_reader_after_security` (`EDP.cpp:1652`) | 双向建立关联 |
| QoS 判定 | `EDP::valid_matching` (`EDP.cpp:856`) | 逐条策略检查；`incompatible_qos` 在这里填充 |

**租约**

- 超时检查：`PDP::check_remote_participant_liveliness` (`PDP.cpp:1457`)
- 删除：`PDP::remove_remote_participant` (`PDP.cpp:1255`)

`remove_remote_participant` 是框架作者最该读的函数之一：它展示了"一个 participant 消失"如何级联删除 proxy endpoints、解除匹配、触发 listener/status，以及哪些操作不能在该线程里做。

**默认值**（`include/fastdds/rtps/attributes/RTPSParticipantAttributes.hpp`）：

- `leaseDuration = {20, 0}`（225–280 行区间）
- `leaseDuration_announcementperiod = {3, 0}`
- `InitialAnnouncementConfig { count = 5, period = 100 ms }`

### 4.4 Cyclone DDS 源码路线

**启动与通告**

| 阶段 | 入口 | 说明 |
| --- | --- | --- |
| 创建 participant | `ddsi_new_participant` (`ddsi_participant.c:759`) | 分配 GUID、创建网络端点 |
| 内置端点 | `add_builtin_endpoints` (`ddsi_participant.c:286`，调用点 `:920`) | SPDP/SEDP/PMD 的 writer/reader 在这里注册 |
| SPDP 发送 | `resend_spdp` / `ddsi_spdp_write` (`ddsi_spdp_schedule.c:612` 起) | 组播 + initial peers |
| 通告节奏 | `spdp_intv` (`ddsi_spdp_schedule.c:745`) | 默认 lease 的 80%；lease 10 s → 8 s；上限 30 s |
| 接收 SPDP | `ddsi_handle_spdp` (`ddsi_discovery_spdp.c:655`) | 子消息分发 |
| 处理 alive | `handle_spdp_alive` (`ddsi_discovery_spdp.c:545`) | 新建 proxy participant |
| 处理 dispose | `handle_spdp_dead` (`ddsi_discovery_spdp.c:326`) | 显式删除 |

**SEDP 与匹配**

| 阶段 | 入口 | 说明 |
| --- | --- | --- |
| 本地 writer/reader 通告 | `ddsi_sedp_write_writer` (`ddsi_discovery_endpoint.c:253`)、`ddsi_sedp_write_reader` (`:279`) | |
| 收到 SEDP | `ddsi_handle_sedp_endpoint` (`ddsi_discovery.c:116`) | 按 kind 分发 |
| 处理 alive endpoint | `ddsi_handle_sedp_alive_endpoint` (`ddsi_discovery_endpoint.c:416`) | 创建 proxy writer/reader |
| 匹配驱动 | `generic_do_match` (`ddsi_endpoint_match.c:510`) | 对每对 writer/reader 调用 |
| QoS/类型判定 | `topickind_qos_match_p_lock` (`ddsi_endpoint_match.c:168`) | 返回第一个不满足的策略 |
| 建立关联 | `connect_proxy_writer_with_reader` (`ddsi_endpoint_match.c:294`) | 建 `ddsi_reader`/`ddsi_writer` 的配对 |

**租约**

- `ddsi_gc_participant_lease` (`ddsi_participant.c:390`)
- 默认 lease 10 s；`SPDPInterval` 默认按 lease 的 80% 计算（`spdp_intv`），不是固定 30 s。

**注意**：Cyclone 没有 Discovery Server，也没有 Fast DDS 那种 `EDPStatic`。它靠"组播 + Peers 列表 + 自适应 SPDP 调度"解决发现问题；大规模部署要靠网络设计或 Peers 收敛，而不是中心化服务器。

### 4.5 两套实现的对照

| 维度 | Fast DDS 3.6 | Cyclone DDS 11 |
| --- | --- | --- |
| 发现入口 | C++ 类层次：`PDP` / `EDPSimple` | C 函数：`ddsi_discovery_*` / `ddsi_endpoint_match` |
| 默认 lease | 20 s | 10 s |
| 周期通告 | 3 s（`leaseDuration_announcementperiod`） | 80% lease，上限 30 s |
| 初始通告 | 5 次 × 100 ms，可配 | 自适应调度（启动期加密） |
| Discovery Server | 支持（SERVER/CLIENT/BACKUP） | 不支持 |
| 静态 EDP | 支持（`static_edp_xml_config`） | 无 |
| 初始 peer | `initialPeersList`（单播 locator） | `Discovery/Peers`（Address，可带端口） |
| 匹配函数 | `EDP::valid_matching` | `topickind_qos_match_p_lock` |
| 端口分配 | 标准 RTPS well-known ports；participant index 自动分配 | 同标准；`MaxAutoParticipantIndex` 默认 99 |
| 发现线程 | receiver + event 线程 | recv / tev / xmit 线程 |

### 4.6 实验组

每个实验都按"目的 → 步骤 → 观测 → 预期 → 结论"写进你的实验记录。

#### E1 首次发现的时间分解

**目的**：把"发现慢"拆成可测量的阶段。

```bash
cd /workspace/logs/adv
tcpdump -i any -nn -tt -w e1.pcap 'udp portrange 7400-7600' &
PUB=/opt/dds/fastdds/share/fastdds/examples/cpp/hello_world/bin/hello_world
$PUB subscriber -s 0 > sub.log 2>&1 &
sleep 1
$PUB publisher -s 200 > pub.log 2>&1 &
sleep 12
kill %1 %2 %3 2>/dev/null
```

观测：

- 第一条 SPDP 到最后一条 SEDP 的时间差；
- 首条用户数据的时间；
- 用 `tcpdump -r e1.pcap -nn -tt | grep -c 7400` 统计组播包数。

**预期**：SPDP 突发 < 1 s 完成；SEDP 在收到 SPDP 后立即触发；用户数据在匹配后 < 100 ms 开始。

**结论落点**：框架的"节点启动到可通信"延迟由哪几段构成，哪些可以并行化。

#### E2 lease 过期与恢复

**目的**：看清"进程活着但不再发通告"和"进程死了"两种情况。

```bash
PUB=.../hello_world
$PUB subscriber -s 0 > sub.log 2>&1 &
SUB=$!
$PUB publisher -s 0 > pub.log 2>&1 &
sleep 3
kill -STOP $SUB          # 进程还在，但不发任何包
# 观察 20 s（Fast DDS lease）
gdb -p <publisher_pid> -batch \
    -ex 'break PDP::remove_remote_participant' \
    -ex 'continue' -ex 'bt 8' 2>&1 | tee gdb-lease.log
kill -CONT $SUB
```

观测：

- `kill -STOP` 后最后一次 SPDP 的时间；
- `remove_remote_participant` 被命中的相对时间（应 ≈ lease）；
- 恢复后多久重新匹配；
- 优雅退出（Ctrl+C / `delete_participant`）是否发送 dispose，对端是否立即删除；
  `kill -9` 不会发任何包，只能等 lease 超时 —— 这是两者最关键的差别。

Cyclone 对照：`ddsperf -D 30 sub` 被 `SIGSTOP` 后，日志会出现 `participant ... gone`；断点换成 `ddsi_gc_participant_lease`。

**扰动**：把 lease 改为 5 s 和 `DURATION_INFINITY`，重复。注意 infinity 时对端永远不会因租约删除，只能靠显式 dispose 或进程退出。

#### E3 初始通告与通告周期

**目的**：验证你对"启动风暴"和"稳态流量"的直觉。

配置已经放在仓库里：`/workspace/config/fastdds-fast-spdp.xml`。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<dds xmlns="http://www.eprosima.com/XMLSchemas/fastRTPS_Profiles">
  <profiles>
    <participant profile_name="lab_fast_spdp" is_default_profile="true">
      <rtps>
        <builtin>
          <discovery_config>
            <discoveryProtocol>SIMPLE</discoveryProtocol>
            <leaseDuration><sec>30</sec></leaseDuration>
            <leaseAnnouncement><sec>1</sec></leaseAnnouncement>
            <initialAnnouncements>
              <count>20</count>
              <period><sec>0</sec><nanosec>50000000</nanosec></period>
            </initialAnnouncements>
          </discovery_config>
        </builtin>
      </rtps>
    </participant>
  </profiles>
</dds>
```

运行：

```bash
export FASTDDS_DEFAULT_PROFILES_FILE=/workspace/config/fastdds-fast-spdp.xml
# hello_world 用 create_participant_with_default_profile 读取默认 profile
```

**预期**：前 1 s 内 20 个 SPDP，然后每 1 s 一个。用 `tcpdump` 的时间戳验证，误差应在调度抖动范围内。

**本环境已实测**：给 publisher 设置该 profile、subscriber 不设置，抓包 4 s，同一个
`239.255.0.1:7400` 上能看到两种节奏 —— 一个源端口每 50 ms 一个包，另一个每 100 ms 一个包。
这正好是"参数 → 行为"的直接证据，也说明 profile 确实被加载了。

Cyclone 对照（已放在 `/workspace/config/cyclonedds-fast-spdp.xml`）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CycloneDDS xmlns="https://cdds.io/config">
  <Domain id="any">
    <Discovery>
      <LeaseDuration>30s</LeaseDuration>
      <SPDPInterval>2s</SPDPInterval>
    </Discovery>
  </Domain>
</CycloneDDS>
```

```bash
CYCLONEDDS_URI=file:///workspace/config/cyclonedds-fast-spdp.xml ddsperf -D 20 pub
```

#### E4 发现放大：N 个 participant

**目的**：得到自己环境下的"规模曲线"，而不是背结论。

```bash
PUB=/opt/dds/fastdds/share/fastdds/examples/cpp/hello_world/bin/hello_world
for i in $(seq 1 20); do
  $PUB subscriber -s 0 > /tmp/sub$i.log 2>&1 &
done
```

观测（记得用 `-i eth0`，理由见 E1）：

- 每 3 s 的 SPDP 包数 ≈ N（每个 participant 一个组播通告）+ 定向回应；
- SEDP 包数随端点数增长；匹配计算是每 participant O(E²)；
- 启动时间、CPU、`/dev/shm` 段数量（`ls /dev/shm | wc -l`）。

**结论落点**：你的框架如果每个 node 一个 participant，N 个 node 的发现成本是多少；改成每进程/每 context 一个 participant 能省多少。

#### E5 QoS 不匹配发生在哪一层

**目的**：区分"没发现"和"发现了但不匹配"。

```bash
BENCH=/opt/dds/fastdds/share/fastdds/examples/cpp/benchmark/bin/benchmark
$BENCH subscriber -n qos_lab -r -s 100 &   # reader 要求 RELIABLE
$BENCH publisher  -n qos_lab -s 100        # writer 提供 BEST_EFFORT
```

观测：

- 应用层是否有 matched / incompatible QoS 状态；
- `gdb` 断在 `EDP::valid_matching`，`finish` 后打印 `reason` 与 `incompatible_qos`；
  `MatchingFailureMask` 的位定义在 `EDP.h:70–88`：
  `0=different_topic`、`1=inconsistent_topic`、`2=incompatible_qos`、`3=partitions`、`4=different_typeinfo`；
- 抓包：SEDP 通告照常，但没有后续 HEARTBEAT/数据。

这五个位就是你的框架做诊断时应该暴露给用户的"不匹配原因"，比一句 "no match" 有用得多。

Cyclone 对照：`ddsperf -u pub`（best-effort）+ `ddsperf sub`（reliable），并开启 `discovery` 追踪分类，观察匹配失败日志。

**结论落点**：框架的 QoS 兼容性检查不能只在本地做，必须把不匹配作为可观测事件暴露给用户。

#### E6 Discovery Server 与组播的代价对比

**目的**：量化中心化发现的收益和风险。

Fast DDS 自带示例可以直接跑（不需要写 XML）：

```bash
DS=/opt/dds/fastdds/share/fastdds/examples/cpp/discovery_server/bin/discovery_server
$DS server --listening-address 127.0.0.1 --listening-port 16166 > ds.log 2>&1 &
$DS publisher  -c 127.0.0.1 -p 16166 -s 200 > ds-pub.log 2>&1 &
$DS subscriber -c 127.0.0.1 -p 16166 -s 200 > ds-sub.log 2>&1
```

观测：

- 抓包对比：默认组播模式 vs DS 模式的 SPDP/SEDP 包数；
- DS 单点故障：杀掉 server 后，新 participant 能否发现彼此；已有匹配是否继续工作（数据面不依赖 server）；
- 备份/级联：`fastdds discovery -b` 支持备份 server，多 server 拓扑需要额外 XML；
  示例程序只覆盖最简单的单 server。

Cyclone 没有 DS；用 `Peers` 做全互联单播对照：

```xml
<CycloneDDS xmlns="https://cdds.io/config">
  <Domain id="any">
    <General><AllowMulticast>false</AllowMulticast></General>
    <Discovery>
      <Peers>
        <Peer Address="127.0.0.1"/>
        <Peer Address="127.0.0.2"/>
      </Peers>
    </Discovery>
  </Domain>
</CycloneDDS>
```

（`127.0.0.0/8` 整个网段默认就在 `lo` 上，`127.0.0.2` 可直接用；要模拟跨主机，
用 `ip netns`，或给 `eth0` 加别名地址。容器有 `NET_ADMIN`。）

#### E7 静态发现（可选）

Fast DDS 支持 `static_edp_xml_config` 与静态 endpoint XML，冷启动不需要 SEDP。读源码时关注 `EDPStatic`，并对比"静态 + 动态混合"时 SEDP 是否仍然发送。Cyclone 没有等价物，跳过。

#### E8 安全发现（可选，需重建）

当前 `SECURITY=OFF`（`/build/build/Fast-DDS/CMakeCache.txt`）。要做需要单独构建：

```bash
cmake -S /build/src/Fast-DDS -B /build/build/Fast-DDS-sec -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_INSTALL_PREFIX=/opt/dds-sec/fastdds \
  -DCMAKE_PREFIX_PATH=/opt/dds/fastcdr \
  -DSECURITY=ON -DBUILD_SHARED_LIBS=ON -DCOMPILE_EXAMPLES=ON
```

观察重点：认证握手发生在 SPDP 之前还是之后；失败时对端看到的是"不存在"还是"不匹配"；密钥交换对首次发现延迟的影响。这个实验成本高，放在最后。

### 4.7 框架层结论（做完实验再写）

把你的结论填进这张表，它就是自研框架的选型依据：

| 场景 | 默认组播 | initial peers 单播 | Discovery Server | 静态发现 |
| --- | --- | --- | --- | --- |
| 启动收敛时间（N=10/50/100） | | | | |
| 稳态发现带宽 | | | | |
| 对单点故障的敏感性 | | | | |
| 跨网段/云环境可行性 | | | | |
| 实现复杂度（你的框架要维护什么） | | | | |

框架代码通常需要：

- **graph cache**：订阅 `DCPSParticipant` / `DCPSPublication` / `DCPSSubscription` 内置主题，或使用 RMW 的 graph API；注意内置主题的 QoS 和事件风暴。
- **发现事件去抖**：一次启动会产生大量 endpoint 变更，直接逐条回调 executor 会打爆上层。
- **QoS 不匹配的可观测性**：把 `on_offered_incompatible_qos` / `on_requested_incompatible_qos` 映射到框架的告警，而不是只打日志。
- **participant 粒度**：每进程一个 vs 每 node 一个，直接决定发现规模；这是 ROS 2 生态里最容易被忽视的架构决策。
- **domain 隔离**：所有实验默认 domain 0，多个框架实例会互相发现。

---

## 5. 内存管理

### 5.1 主线：数清拷贝次数和所有者

不要一上来读内存池实现。先对一条路径数清楚：

```
应用 buffer
  → 序列化 buffer / loaned buffer      (谁分配？)
  → writer history (cache change)      (谁持有？引用计数？)
  → 传输层 buffer (UDP / SHM segment)  (拷贝还是映射？)
  → reader history (RHC)               (拷贝还是引用？)
  → 应用取走 (read/take/loan)          (谁释放？)
```

对每条路径回答三个问题：

1. 有几次 `memcpy`？
2. 每个 buffer 的所有者是谁，生命周期由谁决定？
3. 背压时内存增长在哪里，上限由哪个 QoS 决定？

### 5.2 三套所有权模型

| 模型 | 代表 | 分配点 | 释放点 |
| --- | --- | --- | --- |
| payload pool + cache change | Fast DDS | `BasicPayloadPool::get_payload` | history 移除 change 时 `release_payload` |
| serdata 引用计数 | Cyclone DDS | `dds_serdata_default.c:207` `ddsrt_malloc` | `ddsi_serdata_unref` 归零时 |
| chunk 引用计数 | iceoryx | `MemoryManager::getChunk` | 每个订阅者 release，计数归零回 mempool |

理解这三套模型后，再看任何"零拷贝"宣传都能定位到具体实现。

### 5.3 Fast DDS 写路径

**普通 write（拷贝路径）**

| 步骤 | 入口 | 说明 |
| --- | --- | --- |
| API 入口 | `DataWriterImpl::write` (`DataWriterImpl.cpp:676/688`) | |
| 取 payload | `DataWriterImpl::get_free_payload_from_pool` (`DataWriterImpl.cpp:2411`) | 从 topic payload pool 取 buffer |
| 序列化 | Fast CDR 写入 payload | 这里发生用户数据 → 序列化数据的拷贝 |
| 入 history | `WriterHistory::add_change_` (`WriterHistory.cpp:212`) → `notify_writer` (`:200`) | history 满时按 `max_blocking_time` 阻塞 |
| 通知 writer | `StatefulWriter::unsent_change_added_to_history` (`StatefulWriter.cpp:333`) | 进入发送/流控 |
| 流控 | `FlowController` (`FlowController.hpp:16`) | 异步发送、限速、优先级 |
| 传输 | UDP / SHM / data-sharing | |

**Payload pool 变体**（`src/cpp/rtps/history/BasicPayloadPool_impl/`）：

- `Preallocated`：每个 payload 按类型最大序列化尺寸 `reserve`，永不 realloc；数据超过该尺寸时 write 失败（`Preallocated.hpp:30–40`）。
- `PreallocatedWithRealloc`：初始按最大尺寸，遇到更大数据时允许 realloc 扩容。
- `Dynamic`：每次按实际大小分配。
- `DynamicReusable`：按实际大小分配并回收复用，减少 malloc 次数，但不预分配。

注意两个不同的上限：**payload 尺寸**由 pool 的类型最大尺寸决定，**样本数量**由 history 的
`resourceLimitsQos.max_samples` / `allocated_samples` 决定（后者预分配 cache change，不预分配 payload）。
配置入口是 writer 的 `<historyMemoryPolicy>` 和 topic 的 `<resourceLimitsQos>`；源码里
`BasicPayloadPool.hpp:43` 的 `get_payload` / `release_payload` 是统一入口。

**loan 路径**

- `DataWriter::loan_sample` → `DataWriterImpl::loan_sample` (`DataWriterImpl.cpp:551`)
- 应用直接在池中 buffer 上构造数据，`write` 时不再拷贝用户数据
- `discard_loan` (`DataWriterImpl.cpp:644`) 归还未发布的 loan
- 关键约束：loan 出去后 writer 仍然是所有者；发布后所有权转移给中间件，应用不能再碰

**data-sharing / intra-process**

- data-sharing：writer 的 payload 放在自己的共享内存池（`DataSharing/DataSharingPayloadPool.cpp`），reader 直接映射读，**序列化数据不复制**（反序列化到用户对象仍有一次构造）；由 `DataSharingQosPolicy(AUTO)` 和同主机条件决定。
- intra-process：同 participant 内的 writer/reader 可以完全绕过序列化（XML 里是 `intraprocess_delivery`），语义与 DDS 线协议不同，**不能拿它验证跨进程行为**。
- SHM transport：把序列化后的 payload 拷贝进 `/dev/shm/fastdds_*` 段，省掉内核 UDP 栈，**仍然是一次拷贝**。

这三者经常被混为一谈，实验 M5 就是用来分开它们的。

### 5.4 Cyclone DDS 写路径

| 步骤 | 入口 | 说明 |
| --- | --- | --- |
| API 入口 | `dds_write_impl` (`dds_write.c:808`) | 处理普通写、loan、PSMX loan |
| 序列化 | `dds_serdata_default.c:207` `ddsrt_malloc` | 每次分配 `sizeof(serdata) + size`，数据内联在 serdata 尾部 |
| 引用计数 | `ddsi_serdata_ref` / `unref` | WHC、RHC、网络队列共享同一 serdata |
| 入 WHC | `whc_default_insert` (`dds_whc.c:1180`) | 满时按 QoS 丢旧或阻塞 |
| 发送 | `deliver_data_network` (`dds_write.c:297`) | 网络路径 |
| 本地投递 | `deliver_locally` (`dds_write.c:244`) | 同进程 reader 直接进 RHC |
| 顺序 | `deliver_data_any` (`dds_write.c:314`) | 先网络、后本地（`dds_write.c:322/324`） |

注意这个顺序：**同一进程的 reader 可能晚于网络发送才看到数据**。写框架的"发布后立即可读"假设需要验证。

**loan**

- `dds_request_loan` / `dds_loan_sample` (`dds_entity.c:1581` / `:1621`)
- `dds_return_loan` (`dds_entity.c:1624`)
- 11 里有 heap loan 和 PSMX loan 两条路径（`dds__heap_loan.h`、`dds_psmx.c`）；只有 PSMX 命中时才是真正的跨进程零拷贝。
- PSMX 路径：`psmx_iox_impl.cpp` 的 `iox_req_loan` (`:500`) / `iox_write` (`:520`) / `iox_take` (`:544`)。

### 5.5 读路径与背压

**Fast DDS**

- `ReaderHistory::add_change` (`ReaderHistory.cpp:88`) 把 change 放进 RHC
- `DataReaderImpl::on_data_available` (`DataReaderImpl.cpp:1068`) 触发 listener/condition
- `DataReaderImpl::read_or_take_next_sample` (`DataReaderImpl.cpp:733`)
- reader 侧资源上限同样由 `resourceLimitsQos` 决定；RELIABLE + KEEP_ALL 时，慢 reader 会通过 ACKNACK 让 writer 保留数据

**Cyclone**

- `dds_rhc_default_store` (`dds_rhc_default.c:1577`)
- `dds_rhc_default_take` (`dds_rhc_default.c:2824`)
- RHC 满时按 history QoS 丢最旧或阻塞；`ddsperf -Q rss/livemem` 可以直接做验收

**背压的三个层次**

1. history 层：`max_samples` / `max_samples_per_instance` / `depth`；
2. 传输层：UDP 发送缓冲、SHM 队列、iceoryx mempool；
3. 应用层：reader 取走速度。

任何一层满，表现都可能是"写阻塞"或"丢样本"，必须用实验区分。

### 5.6 iceoryx chunk 生命周期

```
publisher loanRequest
  → MemoryManager::getChunk (memory_manager.cpp:152)
  → MemPool::getChunk        (mem_pool.hpp:63)
  → 应用写入
  → ChunkSender::send        (chunk_sender.hpp:117)
  → ChunkDistributor 分发给每个订阅者队列（引用计数 +1）
  → 每个订阅者 ChunkReceiver 取走并 release（引用计数 -1）
  → 归零后 MemPool::freeChunk (mem_pool.hpp:70)，chunk 回池
```

关键结构：

- `ChunkManagement::m_referenceCounter` (`chunk_management.hpp:45`)，初始 1
- `MemPool::m_usedChunks` (`mem_pool.hpp:84`) —— `iox-introspection-client --mempool` 显示的就是它
- RouDi 配置示例：`/build/src/iceoryx/iceoryx_posh/etc/iceoryx/roudi_config_example.toml`
  - 默认 mempool 从 128 B 到 4 MiB 分档，每档 chunk 数量有限
  - 小 chunk 多、大 chunk 少：大消息容易在"池里还有空闲内存"时失败

### 5.7 实验组

#### M1 分配次数：同一负载，三种 history policy

**目的**：把"预分配"从宣传语变成数字。

```bash
BENCH=/opt/dds/fastdds/share/fastdds/examples/cpp/benchmark/bin/benchmark
# publisher 会等匹配，先起一个订阅者
$BENCH subscriber -s 2000 -m SMALL >/dev/null 2>&1 &
time ltrace -c -e malloc+calloc+realloc+free \
  $BENCH publisher -s 2000 -m SMALL -i 1 2>&1 | tail -n 10
```

**本环境实测**：`ltrace` 可用。即使 publisher 没匹配到订阅者、一个样本都没发，
进程启动本身也有约 5000 次 malloc/free（本机实测 2156 malloc + 2840 free + 269 calloc + 9 realloc）。
所以判断"预分配是否生效"要看**发送阶段的增量**，不要把启动开销算进去。

然后换 writer 的 `historyMemoryPolicy`（PREALLOCATED / PREALLOCATED_WITH_REALLOC / DYNAMIC_REUSABLE）重复。注意 `benchmark` 的 QoS 写在代码里，改 policy 需要你自己的小实验程序（放 `/workspace/labs/`，构建树放 `/build/labs/`）。

观测：

- malloc 次数随样本数是否线性增长；
- 稳态阶段（前 100 个样本之后）是否还有 malloc；
- RSS 曲线是否平台化。

`ltrace` 会明显拖慢程序，结论只看**相对次数**，不看吞吐。

#### M2 池耗尽

**目的**：看清"池满"时的错误路径，而不是猜。

- 把 `resourceLimitsQos.max_samples` 设得比发送速度快导致的积压小；
- 用 RELIABLE + KEEP_ALL，让 writer 无法丢样本；
- 观测 `write` 返回码、阻塞时长、日志、gdb 栈。

预期：`DataWriterHistory::prepare_change` (`DataWriterHistory.cpp:156`) 看到 `m_isHistoryFull` 后，
KEEP_ALL 会调 `try_remove_change(max_blocking_time, lock)` 等 ACK，KEEP_LAST 会调
`remove_min_change(max_blocking_time)` 等最旧样本可移除；到期仍不能腾出空间则返回 `false`，
`write` 拿到错误。用 gdb 断在这里，栈里能直接看到阻塞点和调用者。

Cyclone 对照：`-k all` + 慢 reader，观察 WHC 增长与 `dds_write` 返回码。

#### M3 loan 的边界

**目的**：把 loan 的生命周期写成框架可以执行的规则。

步骤（Fast DDS）：

1. `loan_sample` → 写数据 → `write`；
2. 另一路：`loan_sample` → `discard_loan`；
3. 再试：`loan_sample` → `write` → 立刻改 buffer（应该被禁止）；
4. 在 writer 的 listener 回调里释放 loan（验证回调线程与所有权）。

观测：用 gdb 断在 `get_free_payload_from_pool` / `release_payload`，看同一地址何时被复用；用 `strace` 看是否有额外分配。

Cyclone 对照：`dds_request_loan` → `dds_write` → `dds_return_loan`，以及 PSMX 模式下 `iox_req_loan` 的 chunk 来源。

**结论落点**：框架 API 必须在类型系统或文档里明确"publish 后不可再访问"；RMW 的 `rmw_publish_loaned_message` 语义就是这个约束的具体化。

#### M4 慢订阅者与背压

**目的**：找到你的框架在过载时的真实行为。

```bash
# Cyclone：发布端不限速，订阅端故意慢（用 -D 拉长观察窗口，配合 taskset/cgroup 限 CPU）
ddsperf -D 30 -k all pub &
ddsperf -D 30 -k all sub
# ddsperf 自带验收：RSS 增长上限、最少样本数
ddsperf -D 30 -Q rss:50% -Q samples:10000 sub
```

观测：

- writer 侧内存曲线（`/proc/<pid>/status` VmRSS，或 `smaps_rollup`）；
- 丢样本计数（`ddsperf` 的 `lost`）；
- CPU：是发送线程忙等，还是阻塞在条件变量。

Fast DDS 对照：`benchmark` 的 `-m BIG` + 小 history + reliable reader，观察写阻塞。

#### M5 三条"共享内存"路径的映射对比

**目的**：一次实验分清 SHM transport、data-sharing、iceoryx。

| 配置 | 命令 | 观察 |
| --- | --- | --- |
| UDP only | `benchmark publisher -t UDPv4` | 无 `/dev/shm` 段，tcpdump 能看到数据 |
| SHM transport | `benchmark publisher -t SHM` | `/dev/shm/fastdds_*` 段；tcpdump 看不到数据；仍有拷贝 |
| data-sharing | 需要自己的小实验程序设置 `DataSharingQosPolicy` | writer 池段被 reader 映射；`/proc/<pid>/maps` 中同一段出现在两个进程 |
| Cyclone PSMX | `CYCLONEDDS_URI=...cyclonedds-shm.xml` + RouDi | `/dev/shm/root`、`iceoryx_mgmt`；`iox-introspection-client` 看 chunk |

**注意**：`benchmark -t` 只改传输，不改 data-sharing QoS；data-sharing 默认是 `AUTO`，
可能在你以为是"纯 SHM transport"的实验里已经生效。要隔离三者，必须写自己的探针程序，
显式设置：

```xml
<data_sharing>
    <kind>OFF</kind>   <!-- 或 ON / AUTOMATIC -->
</data_sharing>
```

XML 元素定义见 `src/cpp/xmlparser/XMLElementParser.cpp:2192` 的注释。

```bash
# 对比两个进程的映射
grep -h '/dev/shm' /proc/<pub_pid>/maps | sort > /tmp/pub.maps
grep -h '/dev/shm' /proc/<sub_pid>/maps | sort > /tmp/sub.maps
comm -12 /tmp/pub.maps /tmp/sub.maps   # 两边都映射的段
```

**预期**：SHM transport 只有各自的端口段；data-sharing 会出现共享的 writer 池段；iceoryx 是 `root`/`iceoryx_mgmt` 加 per-process 映射。

#### M6 iceoryx mempool 参数敏感性

**目的**：理解"为什么还有空闲内存却分配失败"。

1. 复制 `roudi_config_example.toml` 到 `/workspace/config/roudi-lab.toml`；
2. 把某个尺寸档的 `chunk_count` 调小；
3. `iox-roudi -c /workspace/config/roudi-lab.toml`；
4. 用 `ddsperf -T S32k` 或 `benchmark -m BIG` 打流量；
5. 另开终端 `iox-introspection-client --mempool` 观察每档使用率；
6. 同时看发布端错误码（chunk 分配失败）。

**结论落点**：框架的消息大小分布决定了 mempool 配置；固定 4 MiB 大消息会迅速耗尽大 chunk 档，即使总量充足。

#### M7 长跑与碎片

**目的**：区分"泄漏"和"缓存增长后平台化"。

- 跑 30–60 分钟稳定负载；
- 每 5 s 采样 `VmRSS`、`smaps_rollup` 的 `Pss`/`Private_Dirty`；
- 结束后确认 `/dev/shm` 段被清理；
- 用 heaptrack 或 massif 对比首尾快照。

预期：DDS 实现会在启动后达到平台，不应线性增长；线性增长通常是框架层持有 sample/loan 未归还。

### 5.8 框架层结论（做完实验再写）

- **loan 生命周期**：publish 后所有权转移，take 后必须 return；框架的 executor 不能在回调返回后继续持有 loan。
- **序列化边界**：跨语言/跨进程必须序列化；只有同主机 + 同实现 + 满足条件的路径才可能零拷贝。
- **QoS 与内存的耦合**：RELIABLE + KEEP_ALL 把内存上限交给 history；BEST_EFFORT + KEEP_LAST 把丢弃交给中间件。框架必须把选择暴露给用户。
- **可观测性**：把 matched 数、丢样本数、history 深度、loan 未归还数做成指标，而不是等 OOM。
- **测试基线**：每加一条零拷贝路径，都要有"关闭该路径仍正确"的回归测试。

---

## 6. 六周日程（每周 6–8 h）

| 周 | 主题 | 阅读 | 实验 | 验收 / 产出 |
| --- | --- | --- | --- | --- |
| 1 | 可调试环境 + 发现基线 | RTPS §8.4、端口 §9.6.1 | 建 RelWithDebInfo；E1 | 一张首次发现时序图（含耗时分解） |
| 2 | Fast DDS 发现全程 | `PDP*` / `EDP*` / `PDPListener` | E2、E3 | lease 状态机 + 通告参数-行为表 |
| 3 | Cyclone 发现 + 对照 | `ddsi_discovery_*` / `ddsi_endpoint_match` | E4、E5 | 两实现发现对照表 + 匹配失败案例 |
| 4 | 部署形态 | Discovery Server、静态发现 | E6（E7 可选） | 规模/带宽/故障敏感性对比表 |
| 5 | 写路径与分配 | payload pool / WHC / serdata | M1、M2、M3 | 拷贝次数表 + 池耗尽调用栈 |
| 6 | 读路径、背压、零拷贝 | RHC / data-sharing / PSMX / iceoryx | M4、M5、M6（M7 长跑） | 三条 SHM 路径判定表 + 框架约束清单 |

每周结束时用 30 分钟写"本周结论"，只写**被实验验证过**的内容；未验证的标为假设。

---

## 7. 自测题

### 发现（8 题）

1. Fast DDS 的 SPDP 初始通告默认几次、间隔多少？之后多久一次？
   → 5 次 × 100 ms；之后 3 s（`RTPSParticipantAttributes.hpp:225–280`）。
2. Cyclone 的 SPDP 默认间隔怎么算？
   → lease 的 80%，上限 30 s；lease 默认 10 s（`ddsi_spdp_schedule.c:745`）。
3. 端口 `7411` 可能是什么？
   → domain 0 的用户流量单播端口（`7400 + 250*d + 11 + 2*participantId`）。
4. 一个 participant 的 GUID prefix 和 entityId 各多少字节？由谁生成？
   → 12 + 4；participant 创建时生成 prefix，entityId 按实体类型分配。
5. Fast DDS 中 QoS 不匹配的判定函数？Cyclone 呢？
   → `EDP::valid_matching` (`EDP.cpp:856`)；`topickind_qos_match_p_lock` (`ddsi_endpoint_match.c:168`)。
6. lease 超时后 Fast DDS 在哪个函数删除远端 participant？
   → `PDP::remove_remote_participant` (`PDP.cpp:1255`)，由 `check_remote_participant_liveliness` (`:1457`) 触发。
7. 为什么 Discovery Server 能降低发现流量？它的数据面是否依赖 server？
   → 客户端只与 server 建立发现关系，server 转发/汇总；已匹配的端点数据面直接通信，server 挂了不影响已有连接，但影响新发现。
8. Cyclone 没有 Discovery Server，大规模部署有哪些替代手段？
   → 减少 participant 数、Peers 定向单播、网络分段/domain 隔离、应用层服务发现。

### 内存（8 题）

9. Fast DDS 一次普通 `write` 至少几次拷贝？
   → 用户数据 → 序列化 payload（1 次）；SHM transport 再拷入共享段（+1）；data-sharing/intra-process 可省掉。
10. `PREALLOCATED` 和 `PREALLOCATED_WITH_REALLOC` 的区别？
    → 都按类型最大尺寸预留；前者遇到更大数据直接失败，后者允许 realloc 扩容。
    样本数量上限由 history 的 `max_samples` 决定，与 payload 尺寸是两件事。
11. Cyclone 的 serdata 在哪里分配？引用计数归零后谁释放？
    → `dds_serdata_default.c:207`；`ddsi_serdata_unref` 归零时释放。
12. iceoryx 的 chunk 引用计数初值是多少？谁会增加？
    → 1；每个订阅者队列分发时 +1。
13. 为什么 `iox-introspection-client` 显示还有空闲 chunk，发布端却分配失败？
    → 需要的是特定尺寸档；该档耗尽，其他档不满足大小。
14. RELIABLE + KEEP_ALL 时 writer 内存由什么决定？
    → history 的 `max_samples` / `max_samples_per_instance` 与 ACK 进度；未确认样本不能释放。
15. Fast DDS 的 SHM transport 是零拷贝吗？data-sharing 呢？
    → 前者不是（序列化数据拷贝进共享段）；后者序列化数据不复制（reader 映射 writer 池），
    但反序列化到用户对象仍有一次构造。
16. loan 出去的内存在什么时刻转移所有权？
    → `write`/`publish` 成功后归中间件；之前归应用，可用 `discard_loan` 归还。

### 框架（8 题）

17. 你的框架每 node 一个 participant，100 个 node 时发现成本怎么估？
    → 先测 E4 的 N 曲线，再按 participant 数线性/超线性外推；不要凭直觉。
18. graph cache 应该订阅哪些内置主题？为什么不能逐条回调 executor？
    → `DCPSParticipant` / `DCPSPublication` / `DCPSSubscription`；启动期事件量大，需要去抖/批量。
19. QoS 不匹配应该如何在框架层暴露？
    → 监听 incompatible QoS status，转成诊断事件，而不是只打日志。
20. loan 生命周期如何与 executor 回调配合？
    → 回调内消费/归还；禁止跨回调持有；框架 API 明确所有权转移点。
21. 为什么"发布后立即可读"在同一进程内不一定成立？
    → Cyclone 先网络后本地投递（`dds_write.c:322/324`）；Fast DDS 也有异步路径。
22. 零拷贝路径需要哪些前提？
    → 同主机、传输支持、类型/大小满足、QoS 允许；跨语言/跨主机必须序列化。
23. 过载时你希望框架阻塞、丢弃还是报错？对应哪些 QoS？
    → RELIABLE+KEEP_ALL 阻塞/失败；BEST_EFFORT+KEEP_LAST 丢弃；用 status 暴露。
24. 如何验证一条零拷贝路径没有引入生命周期 bug？
    → 关闭该路径做对照回归 + 长跑 RSS/loan 计数 + ASAN/valgrind。

---

## 8. 源码锚点索引

### Fast DDS

| 主题 | 文件:行 | 符号 |
| --- | --- | --- |
| 发现协议选择 | `src/cpp/rtps/builtin/BuiltinProtocols.cpp:72` | `initBuiltinProtocols` |
| PDP 初始化 | `src/cpp/rtps/builtin/discovery/participant/PDPSimple.cpp:156` | `PDPSimple::init` |
| 自身通告数据 | `.../PDPSimple.cpp:107` | `initializeParticipantProxyData` |
| SPDP 端点 | `.../PDPSimple.cpp:325` | `createPDPEndpoints` |
| 发送通告 | `.../PDPSimple.cpp:260/268` → `PDP.cpp:585/593` | `announceParticipantState` |
| SPDP 接收 | `.../PDPListener.cpp:56`、`:189` | `on_new_cache_change_added`、`process_alive_data` |
| 租约检查 | `.../PDP.cpp:1457` | `check_remote_participant_liveliness` |
| 删除远端 | `.../PDP.cpp:1255` | `remove_remote_participant` |
| SEDP 端点 | `.../endpoint/EDPSimple.cpp:416` | `createSEDPEndpoints` |
| 远端端点 | `.../EDPSimple.cpp:750` | `assignRemoteEndpoints` |
| QoS 匹配 | `.../EDP.cpp:856` | `valid_matching` |
| 配对 reader | `.../EDP.cpp:1123`、`:1583`、`:1652` | `pairingReader` 等 |
| write | `src/cpp/fastdds/publisher/DataWriterImpl.cpp:676/688` | `DataWriterImpl::write` |
| loan | `.../DataWriterImpl.cpp:551`、`:644` | `loan_sample`、`discard_loan` |
| 取 payload | `.../DataWriterImpl.cpp:2411` | `get_free_payload_from_pool` |
| history 入队 | `src/cpp/rtps/history/WriterHistory.cpp:200/212` | `notify_writer`、`add_change_` |
| 发送通知 | `src/cpp/rtps/writer/StatefulWriter.cpp:333` | `unsent_change_added_to_history` |
| 流控 | `src/cpp/rtps/flowcontrol/FlowController.hpp:16` | `FlowController` |
| payload pool | `src/cpp/rtps/history/BasicPayloadPool.hpp:43` | `BasicPayloadPool` |
| pool 变体 | `.../BasicPayloadPool_impl/*.hpp` | Preallocated / Dynamic / … |
| data-sharing | `src/cpp/rtps/DataSharing/DataSharingPayloadPool.cpp:30` | `release_payload` |
| SHM 传输 | `src/cpp/rtps/transport/shared_mem/SharedMemManager.hpp:43` | `SharedMemManager` |
| reader 入队 | `src/cpp/rtps/history/ReaderHistory.cpp:88` | `add_change` |
| reader 读取 | `src/cpp/fastdds/subscriber/DataReaderImpl.cpp:733`、`:1068` | `read_or_take_next_sample`、`on_data_available` |
| 传输环境变量 | `src/cpp/rtps/participant/RTPSParticipantImpl.cpp:98` | `FASTDDS_BUILTIN_TRANSPORTS` |

### Cyclone DDS

| 主题 | 文件:行 | 符号 |
| --- | --- | --- |
| 创建 participant | `src/core/ddsi/src/ddsi_participant.c:759` | `ddsi_new_participant` |
| 内置端点 | `.../ddsi_participant.c:286`（调用 `:920`） | `add_builtin_endpoints` |
| 租约回收 | `.../ddsi_participant.c:390` | `ddsi_gc_participant_lease` |
| SPDP 发送 | `.../ddsi_spdp_schedule.c:612` | `resend_spdp` |
| SPDP 间隔 | `.../ddsi_spdp_schedule.c:745` | `spdp_intv` |
| SPDP 接收 | `.../ddsi_discovery_spdp.c:655`、`:545`、`:326` | `ddsi_handle_spdp`、`handle_spdp_alive`、`handle_spdp_dead` |
| SEDP 通告 | `.../ddsi_discovery_endpoint.c:253`、`:279` | `ddsi_sedp_write_writer/reader` |
| SEDP 接收 | `.../ddsi_discovery.c:116` → `.../ddsi_discovery_endpoint.c:416` | `ddsi_handle_sedp_endpoint`、`ddsi_handle_sedp_alive_endpoint` |
| 匹配驱动 | `.../ddsi_endpoint_match.c:510` | `generic_do_match` |
| QoS/类型匹配 | `.../ddsi_endpoint_match.c:168` | `topickind_qos_match_p_lock` |
| 建立关联 | `.../ddsi_endpoint_match.c:294` | `connect_proxy_writer_with_reader` |
| write | `src/core/ddsc/src/dds_write.c:808` | `dds_write_impl` |
| 本地投递 | `.../dds_write.c:244` | `deliver_locally` |
| 网络投递 | `.../dds_write.c:297` | `deliver_data_network` |
| serdata 分配 | `.../dds_serdata_default.c:207` | `ddsrt_malloc` |
| WHC 入队 | `.../dds_whc.c:1180` | `whc_default_insert` |
| RHC 存储 | `.../dds_rhc_default.c:1577` | `dds_rhc_default_store` |
| RHC 取出 | `.../dds_rhc_default.c:2824` | `dds_rhc_default_take` |
| 收包 | `.../ddsi_receive.c:2624`、`:2693` | `handle_Data`、`handle_DataFrag` |
| loan API | `src/core/ddsc/src/dds_entity.c:1581`、`:1624` | `dds_request_loan`、`dds_return_loan` |
| PSMX/iox | `src/psmx_iox/src/psmx_iox_impl.cpp:500/520/544` | `iox_req_loan`、`iox_write`、`iox_take` |

### iceoryx

| 主题 | 文件:行 | 符号 |
| --- | --- | --- |
| chunk 分配 | `iceoryx_posh/source/mepoo/memory_manager.cpp:152` | `MemoryManager::getChunk` |
| mempool 取/还 | `.../internal/mepoo/mem_pool.hpp:63/70/84` | `getChunk`、`freeChunk`、`m_usedChunks` |
| 引用计数 | `.../internal/mepoo/chunk_management.hpp:45` | `m_referenceCounter` |
| 发送 | `.../internal/popo/building_blocks/chunk_sender.hpp:103/117` | `tryAllocate`、`send` |
| 接收/分发 | `.../chunk_receiver.hpp`、`.../chunk_distributor.hpp` | `ChunkReceiver`、`ChunkDistributor` |
| 配置示例 | `iceoryx_posh/etc/iceoryx/roudi_config_example.toml` | mempool 分档 |

---

## 9. 参考资料

**规范**（优先级最高，遇到实现差异时以规范为准）

- OMG DDS 1.4: <https://www.omg.org/spec/DDS/1.4/>
- OMG DDSI-RTPS 2.5: <https://www.omg.org/spec/DDSI-RTPS/2.5/>
- OMG IDL 4.2 / XTypes 1.3（类型兼容性、type object，做跨厂商互通时必读）

**Fast DDS**

- Fast DDS 文档：<https://fast-dds.docs.eprosima.com/>
- Discovery Server：<https://fast-dds.docs.eprosima.com/en/latest/fastdds/discovery/discovery_server.html>
- 源码内示例：`/opt/dds/fastdds/share/fastdds/examples/cpp/`（`hello_world`、`benchmark`、`discovery_server`）

**Cyclone DDS**

- 文档：<https://cyclonedds.io/docs/>
- 配置参考：`/build/src/cyclonedds/etc/cyclonedds.xsd`（比在线文档更准确）
- PSMX/iceoryx：`src/psmx_iox/`，配置见 `workspace/config/cyclonedds-shm.xml`

**iceoryx**

- 文档：<https://iceoryx.io/>
- 配置：`/build/src/iceoryx/iceoryx_posh/etc/iceoryx/roudi_config_example.toml`

**框架层**

- ROS 2 RMW 实现：`rmw_fastrtps` / `rmw_cyclonedds` 源码（loan、graph cache、waitset 的实际用法）
- ROS 2 QoS 文档（理解 RxO 的工程含义）

---

## 附录 A：命令速查

```bash
# ---- 环境 ----
source /usr/local/bin/ddslab/env.sh          # Release
source /usr/local/bin/ddslab/env-debug.sh    # RelWithDebInfo

# ---- 抓包 ----
tcpdump -i eth0 -nn -tt -w /workspace/logs/adv/x.pcap 'udp portrange 7400-7600'
tcpdump -nn -tt -r /workspace/logs/adv/x.pcap | head -n 50

# ---- Fast DDS 示例 ----
FD=/opt/dds/fastdds/share/fastdds/examples/cpp
$FD/hello_world/bin/hello_world publisher -s 100
$FD/benchmark/bin/benchmark publisher -m SMALL -s 1000 -i 1
$FD/benchmark/bin/benchmark subscriber -r -m SMALL -s 1000
$FD/discovery_server/bin/discovery_server server --listening-port 16166

# ---- Cyclone ----
ddsperf -D 20 pub
ddsperf -D 20 sub
CYCLONEDDS_URI=file:///workspace/config/cyclonedds-trace.xml ddsperf -D 20 sub
# finest + pcap 会显著拖慢程序（本机实测 pub 速率从 ~2.4M/s 降到 ~2.7k/s），只用短时间实验

# ---- iceoryx ----
iox-roudi -c /workspace/config/roudi-lab.toml &
iox-introspection-client --mempool
iox-introspection-client --port

# ---- 内存观测 ----
grep -E 'VmRSS|VmSize' /proc/<pid>/status
cat /proc/<pid>/smaps_rollup
ltrace -c -e malloc+calloc+realloc+free <cmd>
valgrind --tool=massif --massif-out-file=/tmp/massif.out <cmd>
heaptrack <cmd>

# ---- gdb ----
gdb -q --args <cmd>
(gdb) set pagination off
(gdb) set breakpoint pending on
(gdb) break EDP::valid_matching
(gdb) thread apply all bt
```

## 附录 B：本次为深潜路线做的环境改动

| 改动 | 位置 | 说明 |
| --- | --- | --- |
| 构建类型可覆盖 | `scripts/env.sh`、四个 `build-*.sh` | `DDSLAB_BUILD_TYPE` 默认 `Release`，可设 `RelWithDebInfo`/`Debug` |
| 调试环境激活脚本 | `scripts/env-debug.sh` | 切换到 `/opt/dds-debug` + `/build/build-debug` |
| `python3-psutil` | `Dockerfile` | 修复 `fastdds` CLI/`fast-discovery-server` 的启动错误；旧镜像需重建 |
| 发现实验配置 | `workspace/config/fastdds-fast-spdp.xml` | Fast DDS 初始通告/租约调参（E3） |
| 发现实验配置 | `workspace/config/cyclonedds-fast-spdp.xml` | Cyclone SPDPInterval/LeaseDuration（E3） |
| 追踪配置 | `workspace/config/cyclonedds-trace.xml` | `finest` 日志 + 内建 pcap（E1、E5） |
| 已验证 | `/opt/dds-debug/cyclonedds` | RelWithDebInfo 构建 + `ddsperf` 冒烟通过，gdb 可按行定位 |
| 已验证 | `/opt/dds-debug/fastcdr`、`/opt/dds-debug/fastdds` | RelWithDebInfo；gdb 定位 `EDPSimple::initEDP` / `PDP::announceParticipantState`；`hello_world` 15 条收发通过 |
| 已验证 | 三个 XML | `ddsperf` / `hello_world` 加载无报错；E3 的通告节奏差异已抓包确认 |

注意：调试构建只用于**行为观察**，性能结论一律用 Release 构建。

---

## 附：第一个练习（今天就做）

目标：45 分钟内产出你的第一张发现时序图。

1. 先按 3.2 构建调试版（`fastcdr fastdds cyclonedds`，首次约 10–20 分钟），然后
   `source /usr/local/bin/ddslab/env-debug.sh`。
2. 开两个终端：
   ```bash
   tcpdump -i eth0 -nn -tt -w /workspace/logs/adv/first.pcap 'udp portrange 7400-7600'
   ```
   ```bash
   ddsperf -D 15 sub
   sleep 1; ddsperf -D 5 pub
   ```
3. 用 `tcpdump -r` 打印前 30 个包，标出：SPDP 组播、SPDP 单播、SEDP、第一条用户数据。
4. 在图上写出每一段的时间差，并回答：如果把 SPDP 初始通告从默认值改成 20 次 × 50 ms，哪一段会变短，哪一段不变？
5. 把图存到 `workspace/labs/discovery/first-timeline.md`，下周 E3 时回来验证你的预测。

下一周开始读 `PDPSimple::announceParticipantState` / `spdp_intv`，你会带着一个具体问题进源码，而不是从第一行开始。
