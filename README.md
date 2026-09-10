# xrcdemo

Arcaea iOS 侧载运行时插件：无需越狱，为游戏提供练习向的运行时改造能力。

> 版本：**beta1.0**（2026-09-10）
> 基线：**Arcaea iOS 7.0.255**（当前示例版本；跨版本适配见 §4）

## 1. 功能

| 功能 | 实现层 | 说明 |
|---|---|---|
| **Seek** | 外置 dylib | 跳变到谱面的任意时刻，并从该时刻开始播放（音频 seek + 谱面钟基准平移）。已判定音符**不重现**、计分不回滚 |
| **循环片段播放** | 外置 dylib | 锁定时钟在特定区间：到终点自动跳回起点往复。**注意**：已判定段落需**手动暂停 → Retry** 才能重新游玩（判定计数随场景重建归零）；插件会在 Retry 后**自动跳转到循环起始点并继续播放**。Retry 检测 = 音频位置回跳（循环开启时生效）。**如需更换曲目使用该功能，请先点「重置循环」重置循环区段** |
| **变速** | 外置 dylib | 改变谱面事件的流速（0.05×–2.0×），但**不改变音频速度**。原理：每帧平移谱面时钟基准 + 时间域注入 |
| **改判** | **主程序插桩 + dylib** | 判定窗口四档动态调整（默认 25/50/100/120ms）。依赖二进制插桩：将 trampoline 放入主程序空白页，**以在无越狱的情况下修改 iOS 程序的运行时 text 段**。插桩在打包签名前完成；无越狱时运行时直接改写 `__TEXT` 不可行（CT/PAC 页签名拒绝）——这是本功能必须侵入主程序的原因 |

## 2. 使用

### 安装（侧载）

1. 用 `inject.py --stub` 对原始 `Arc-mobile` 打桩（写入跳板 + slot + info blob，产出打桩主程序）；
2. 将 `libxrcdemo.dylib` 与 `libellekit.dylib` 放入 `Payload/Arc-mobile.app/Frameworks/`；
3. 重签名并安装。

验证：日志首行 `==== xrcdemo beta1.0 build <stamp> ====`，以及 `[probe] summary: stub=1 judge=1 gp=1 mtp=1`。

### 练习面板

- **单击悬浮球**开/关面板（可拖动位置）。
- **时间轴**：单击/拖动 = seek（松手执行）。
- **循环**：`起点`（取当前播放位置）→ 播放到终点 → `终点` → `循环 开`；`重置循环` 清除区间（唯一的清除入口）。
- **速度**：滑杆 0.05×–2.0×，snap 0.05。
- **判定窗口**：Max/Pure/Far/Lost 四档（毫秒），输入后立即生效（需主程序已打桩）。

日志：`Documents/xrcdemo.log`。配置：`Documents/xrcdemo.plist`。

## 3. 架构

```
┌─ dylib（版本无关逻辑）──────────────────────────────┐
│  Tweak.x         bootstrap + 悬浮球/面板挂接          │
│  XRCClock.m      时间域（真实时间 + warp/freeze）      │
│  XRCPlayer.m     音频（player/进度/曲长/seek）         │
│  XRCGameplay.m   每帧 hook + 时钟平移 + seek + 循环    │
│  XRCJudge.m      改判 handler（slot 注册 + 判定复刻）   │
│  XRCConfig.m     plist 配置                          │
│  XRCProbe.m      运行时探针（启动日志自证各 hook 状态）  │
│  XRCFloatButton.m / XRCPracticePanel.m      UI        │
├─ 版本契约（跨版本唯一改动点）─────────────────────────┤
│  XRCProfile.h    偏移 / vtable 槽 / 字段布局（带出处注释）│
│  xrc_abi.h       slot 布局 + info blob + handler 签名  │
├─ 注入器（inject.py）────────────────────────────────┤
│  dylib 打包 + LC_LOAD_DYLIB 注入                     │
│  改判桩：跳板 40B + slot 24B + info blob 120B         │
└──────────────────────────────────────────────────┘
```

侵入主二进制的**唯一**理由是改判：判定核是直接 BL 调用，无间接层可用；dylib 与主程序通过 slot（跳板分发）配合。

## 4. 跨版本适配

- 架构按跨版本设计：**跨版本只动 `XRCProfile.h`**（每个偏移带出处注释），逻辑文件全部版本无关。
- 五大功能（判定核 / 每帧更新 / 谱面钟 / 音频链 / 转场恢复）的锚点已在 6.13.10 与 7.0.255 两版定位并留指纹（判定核入口与全部 CMP 站点字节级同构），新版本按指纹重定位。
- **探针自证**：`[probe] summary` 一行给出全部 hook 状态；适配后先看这行。

## 5. 构建

- 本地：Theos（`make`），产物 `.theos/obj/xrcdemo.dylib`。
  首次需准备依赖：

  ```bash
  git clone --depth 1 https://github.com/remember17/WHToast.git /tmp/whtoast && mkdir -p WHToast && cp -r /tmp/whtoast/WHToast WHToast/WHToast
  ```

- CI：GitHub Actions（`.github/workflows/build-tweak.yml`），三级缓存（Theos / iOS SDK / ellekit），产物 `libxrcdemo.dylib` + `libellekit.dylib`。
