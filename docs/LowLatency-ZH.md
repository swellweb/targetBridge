# TargetBridge 5K 低延迟与输入跟手（中文说明）

> **English abstract.** When the receiver cannot decode 5K as fast as the sender
> captures, the single ordered TCP stream lets the kernel send buffer grow to
> megabytes, so every keystroke and cursor position packet waits behind
> 100–300 ms of queued video. This change adds a receiver→sender
> frame-consumption ACK (`0x39`) and a small sender credit window, so the
> backlog is bounded instead of hidden in socket buffers. Documented here in
> Chinese for readers of the existing Chinese docs.

本文对应同一分支上的提交：

- `receiver/sender: frame-consumption ACK with sender credit window`
- `receiver: disable SDL presentation vsync`
- `sender: longer 5K GOP and data-rate ceiling`

## 1. 问题现象

在 5K（5120×2880）接收端上，鼠标指针一跳一跳、键盘回显慢、拖动窗口有拖影；
同一套设置在 4K 上却顺畅。发送端和接收端的 CPU、GPU 都没有跑满，链路也不是瓶颈。

## 2. 根因

TargetBridge 的显示流是**一条有序的 TCP 连接**：视频帧、光标位置（`0x32`）、输入事件
（`0x33`）全部共用同一条字节流。当接收端解码 5K 的速度跟不上发送端采集时：

1. 发送端继续写 socket，内核发送缓冲区一路涨到自动调优上限
   （`net.inet.tcp.autosndbufmax`，本机为 4 MB）；
2. 实测该连接出现过 **1,103,479 字节的常态积压**、峰值 **4,194,304 字节**；
3. 按 5K/120 Mbps ≈ 15 MB/s 计算，这相当于 **100–300 ms 的画面字节排在光标和按键前面**。

4K 下接收端跟得上，队列几乎不积压，所以看不出问题。

## 3. 改动内容

### 3.1 新增 `0x39` 帧消费回传（接收端 → 发送端）

接收端每处理完一帧就回一个 `{"consumed":N}`，空闲时每 2 秒补一个保活包。
TCP 可靠且有序，所以：

```
在途帧数 = 已发送帧数 - 已消费帧数
```

这个计数是精确的；而且回传走的是**反方向**，不会被正向的视频拥塞堵住。

### 3.2 发送端信用窗口

发送端只允许少量帧在途（默认 2 帧），超过就**在采集处丢帧**，不再写进 socket：

- 丢弃发生在编码前，不会破坏参考帧链；
- 回传中断 1.5 秒后改为**停发**，避免接收端卡顿时反而把队列灌满；
- 接收端如果是旧版本（从不回传），发送端**不做限流**，行为与旧版一致。

### 3.3 接收端的两处细节

- `TCP_NODELAY`：每帧的 ACK 只有约 40 字节，不关 Nagle 会被延迟最多 40 ms，直接给
  信用窗口引入抖动；
- `SO_RCVBUF` 限制为 1 MiB：即使呈现端卡住（窗口缩放、GPU 抖动），也不会在接收队列里
  积出几百毫秒的 5K 视频。

### 3.4 关闭呈现 vsync

接收端代码注释本来就写着 "No VSYNC — lets us present as fast as decode produces
frames"，但 SDL 仍会把 present 对齐到面板刷新。5K 下单是这一次等待实测就有 **约 16 ms/帧**，
把整条流水线压在 30 fps 附近。

### 3.5 5K 预设：GOP 与码率上限

- `native5k` 的关键帧间隔从 1 秒改成 **4 秒**（`5K60` 预设早就因为同样的原因改成 4 秒）：
  一个 5K IDR 是 P 帧的数倍大，每秒一个会形成肉眼可见的周期性顿挫；
- 给 `native5k` 增加 **1.5× 码率上限**（`DataRateLimits`），避免硬件编码器长时间超发，
  把 socket 队列瞬间灌满。

## 4. 调参

| 环境变量 | 默认 | 作用 |
|---|---|---|
| `TB_FLOW_CREDIT` | 2 | 允许在途的帧数（1–4 较合理）；0 或未设置时按默认 |
| `TB_FLOW_GATE` | 未设置 | 设为 `0` 完全关闭限流，退回旧行为 |

**经验值**：直连雷雳时 2 帧即可；经过雷雳拓展坞时 ACK 往返时序会变，2 帧可能太紧
（实测接收端掉到 24–26 fps），此时用 **3 帧**可以恢复到 33–34 fps，而队列峰值仍只有
几十 KB。

## 5. 兼容性

| 组合 | 行为 |
|---|---|
| 新发送端 + 新接收端 | 启用信用窗口（默认 2 帧） |
| 新发送端 + 旧接收端 | 收不到 `0x39`，不限流，等同旧行为 |
| 旧发送端 + 新接收端 | 旧版解析器会跳过未知包类型（已有单测覆盖），不受影响 |

## 6. 实测结果

环境：Mac mini（Apple M6）→ 雷雳桥接 → Intel iMac 5K，`native5k` 扩展桌面。

| 指标 | 改造前 | 改造后 |
|---|---|---|
| 发送端 Send-Q（常态 / 峰值） | 1.1 MB / 4.2 MB | 0–30 KB（关键帧瞬时约 0.9 MB） |
| 折算排队延迟 | 74–270 ms | < 1 ms |
| 接收端解码 | — | 9.6 ms/帧 |
| 接收端呈现 | 约 16 ms（Metal + vsync） | 6.6 ms（OpenGL，无 vsync） |

## 7. 自检方法

**发送端**（Mac mini）：

```bash
netstat -an -p tcp | awk '/\.54321/ && /ESTABLISHED/ {print "Send-Q =", $3}'
```

Send-Q 长期维持在几十 KB 以内，说明限流生效；如果长期接近 1 MB 以上，说明回传没有工作
（检查两端版本是否都包含本改动）。

**接收端**（iMac）日志里每秒会打印一行：

```
[main] 33 fps decode=9.0ms present=6.6ms
```

`decode` 和 `present` 分别是解码和呈现耗时；两者之和明显小于帧间隔时，瓶颈就不在接收端。

## 8. 已知限制

- 信用窗口目前把"已发出未确认"和"正在编码"的帧都算进去，直连雷雳时 2 帧足够，
  拓展坞等往返稍长的链路需要调大。更彻底的方案是让窗口只统计线上帧，编码并发交给
  `maxInFlightEncodeFrames` 单独约束（尚未实现）。
- 5K 下发送端的采集/编码上限约 33 fps，这部分不由本改动解决。
