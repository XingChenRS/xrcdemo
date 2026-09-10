# xrcdemo（xrc · runtime-ios）

Arcaea iOS 侧载 dylib：无越狱运行时插件。xrc 工作区 `projects/runtime-ios/` 层的活跃项目。

> 仓库：`XingChenRS/xrcdemo`（新仓；本仓为旧 ArcDemo 的规范化重构，历史提交不迁移）
> 版本：**beta1.0**（2026-09-10）
> 基线版本：**Arcaea iOS 7.0.255**（6.13.10 定位方法见跨版本手册，功能实现以 7.0.255 为准）
> 证据与能力状态：以 [能力账本](../../../research/notes/xrc-arcaea-capability-ledger-2026-08-31.md) 为准；本文档只描述本仓库的定位、功能、结构与纪律。

## 1. 功能

| 功能 | 状态 | 实现层 | 说明 |
|---|---|---|---|
| **Seek（任意时刻跳转）** | 已实现/真机验证 | 外置 dylib | 拖动进度条或 ±5s：音频 seek + 谱面钟基准平移，从目标时刻继续播放。已判定音符**不重现**、计分不回滚（练习定位语义） |
| **循环片段播放** | 已实现/真机验证 | 外置 dylib | 面板设「起点」/「终点」后开启循环：到终点自动跳回起点往复。**注意**：已判定段落需**手动暂停 → Retry** 才能重新游玩（判定计数随重建归零）；Retry 后插件会自动跳回循环起点并继续。插件对 Retry 的检测 = 音频位置回跳（循环开启时生效） |
| **变速** | 已实现/真机验证 | 外置 dylib | 改变谱面事件流速（0.05×–2.0×），**音频速度不变**。原理：每帧 hook `gp.update` 平移谱面时钟基准 + `gettimeofday` 时间域注入 |
| **改判** | 已实现/真机验证 | **主程序插桩 + dylib** | 判定窗口四档任意调整（默认 25/50/100/120ms）。依赖二进制插桩：`inject.py` 把 trampoline 写入主程序 `__TEXT` 尾部空白页并覆盖判定核入口；**无越狱下修改 iOS 运行时 `__TEXT` 不可行（CT/PAC 拒绝），插桩发生在打包签名前**——这是本功能必须侵入主程序的原因 |

## 2. 使用

### 安装（侧载）

1. 用 `inject.py --stub` 对原始 `Arc-mobile` 打桩（写入跳板 + slot + info blob），产出打桩主程序；
2. 将 `libxrcdemo.dylib` 与 `libellekit.dylib` 放入 `Payload/Arc-mobile.app/Frameworks/`；
3. 重签名并安装；
4. 验证：日志首行出现 `==== xrcdemo beta1.0 build <stamp>`，且 `[probe] summary: stub=1 judge=1 gp=1 mtp=1`。

### 面板

- **单击悬浮球**开/关练习面板（可拖动位置）。
- **时间轴**：单击/拖动 = seek（松手执行）。
- **循环**：`起点`（取当前播放位置）→ 播放到终点 → `终点` → `循环 开`。面板右上角 `重置循环` 清除区间（唯一的清除入口；换歌/Retry 都不会动它）。
- **速度**：滑杆 0.05×–2.0×，snap 0.05。
- **判定窗口**：Max/Pure/Far/Lost 四档（毫秒），输入后立即生效（需主程序已打桩）。

### 日志

`Documents/xrcdemo.log`（同时走 NSLog 前缀 `[xrcdemo]`）。配置：`Documents/xrcdemo.plist`。

## 3. 架构

```
┌─ dylib（跨版本逻辑不变）────────────────────────────┐
│  Tweak.x         bootstrap + 悬浮球/面板挂接          │
│  XRCClock.m      时间域（真实时间单一实现 + warp/freeze）│
│  XRCPlayer.m     音频（registry/player/进度/曲长/seek） │
│  XRCGameplay.m   gp.update hook + retime + seek + 循环 │
│  XRCJudge.m      改判 handler（slot 注册 + 判定复刻）   │
│  XRCConfig.m     plist 配置                          │
│  XRCFloatButton.m / XRCPracticePanel.m    UI          │
│  XRCProbe.m      运行时能力探针（日志自证）             │
│  XRCLog.h        统一日志（xrc_log）                  │
├─ 版本契约（跨版本唯一改动点）─────────────────────────┤
│  XRCProfile.h    偏移/vtable 槽/字段布局（每项带出处）   │
│  xrc_abi.h       slot 布局 + info blob + handler 签名  │
├─ 注入器（inject.py，与 profiles 对齐）───────────────┤
│  dylib 打包 + LC_LOAD_DYLIB 注入（现有 load command 填充内）│
│  改判桩：跳板 v2（40B）+ slot v2（24B）+ info blob（120B）│
└──────────────────────────────────────────────────┘
```

**原则**：跨版本只改 `XRCProfile.h`；逻辑文件全部版本无关。侵入主二进制的**唯一**理由是改判（判定核是直接 BL 调用，无间接层可用）。

**两种已证伪/放弃的路线**（防止复活，详见 DEVLOG）：
- dylib 运行时改主程序 `__TEXT`（mprotect/COW）→ 被 CT/PAC 页签名拒绝，**永久死刑**；
- 程序化触发游戏 retry（triggerAction / 暂停层工厂）→ 三次尝试全部失败且污染 action 队列致卡死，**永久放弃**。

## 4. 跨版本移植

- **手册**：[arcdemo-crossversion-anchors-6.13-vs-7.0.255.md](../../../research/notes/arcdemo-crossversion-anchors-6.13-vs-7.0.255.md)——五大功能在 6.13.10 与 7.0.255 上的完整锚点对照表 + 每功能"5 步定位法"。新版本适配从这份手册开始。
- **纪律**：新增/修改偏移 = 先更新 research/notes 的语义笔记 → 再同步 `XRCProfile.h`（每项必须带出处注释）→ 两者同 commit。
- **探针自证**：`[probe] summary` 一行给出全部 hook 状态；跨版本适配后先看这行。

## 5. 证据纪律（xrc 约定）

- 所有偏移可回溯至 `research/notes/` 的语义笔记（判定链、时钟、音频链、retry 链、网络链）。
- 真机验证记录写 DEVLOG（日期、现象、结论）；能力状态标记对齐能力账本（XRC-R/XRC-V/XRC-S/PROTO/OPEN）。
- 打桩产物与注入前基线哈希成对登记（见 workspace MANIFEST 流程）。

## 6. 构建

- 本地：Theos（`make`），产物 `.theos/obj/xrcdemo.dylib`。
- CI：GitHub Actions（[build-tweak.yml](.github/workflows/build-tweak.yml)），三级缓存（Theos / iOS SDK / ellekit），产物 `libxrcdemo.dylib` + `libellekit.dylib`。
