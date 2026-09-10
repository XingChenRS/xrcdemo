# DEVLOG — xrcdemo

演进记录。能力状态标记与 xrc 能力账本（工作区 `research/notes/xrc-arcaea-capability-ledger-2026-08-31.md`）对齐（XRC-R 运行中 / XRC-V 已验证 / XRC-S 静态闭环 / PROTO 失败原型 / OPEN 未闭合）。

> 本仓自旧 ArcDemo 规范化而来（历史提交不迁移）；**beta1.0 为功能稳定基线**。
> 早期演进细节见旧仓 git 历史与 workspace `research/notes/`。

## 2026-09-10 — beta1.0 基线（规范化重构）

**功能集**（全部真机验证）：seek（任意时刻跳转 + 继续播放）、循环片段播放（到终点回起点；已判段落需手动 Retry 重游，插件在 retry 后自动回起点）、变速（谱面事件 0.05–2.0×，音频不变）、改判（主程序插桩 + dylib handler，四档窗口）。

**本轮清理**：
- 命名统一：`xrc_log` 统一日志（`Documents/xrcdemo.log`）、`XRCMenuBridge`、`XRCLog.h`；删除遗留 `WQSuspendView/`、`libs/`、`control`、`Prefix.pch`。
- 死代码下线：`xrc_cfg_seek_replay`（无消费者）、`resume_ms` capture 空实现（被 v9.0.0"仅循环 A 回位"取代）。
- 循环状态的自动清除**全部移除**（唯一清除入口 = 面板「重置循环」）；Retry 回位仅在循环开启时生效。

**已证伪/放弃路线（禁止复活）**：
1. dylib 运行时写主程序 `__TEXT`（mprotect/COW）→ CT/PAC 页签名拒绝（真机 `mprotect FAILED` 实测）。
2. 程序化 retry：v8.9.6 直调 `triggerAction(13)` 被静默忽略；v8.9.7 建暂停层 + setup 仍被忽略（Retry 回调首校验 `PauseLayer+0x298==1`）；v8.9.8 补标志后仍忽略，且 9 次尝试污染 GameModel action 队列 → 手动 retry 卡死转场界面。**retry 与暂停流程深度耦合，外部驱动不可控。**
3. 转场直调 `sub_100CA9590`：槽 178 是 this 调整 thunk（`SUB X0,#0x2B0`），传 GameScene 指针即指针错位（UAF 的一半根因）；即使修正槽号，仍有"旧场景已拆/新场景未构造完"的时序窗口。

**跨版本**：6.13.10 × 7.0.255 锚点对照表落于工作区 `research/notes/arcdemo-crossversion-anchors-6.13-vs-7.0.255.md`。

## 2026-09-10 — v9.0.0（beta1.0 前的最后功能迭代）

- 自动清除全下线：换歌/曲长归零不再清循环——真机证明 retry 重建同样会重置曲长（`len=143896->0`），自动判据必然误伤；清除改为面板「重置循环」手动按钮。
- Retry 回位仅循环开启时回到 A；移除 capture 残留值（曾把进度锁到"随机位置"）。
- 悬浮球单击 = 开/关面板。

## 早期关键里程碑（旧 ArcDemo）

- **改判定案（v8.9.x，2026-09-10）**：判定核 `sub_10091E684` 五出口全复刻（commit/commit_ln/fx 调用形态逐条对齐）；跳板 v2（`MOV X3,X6` 转发 caller 的 a6）；真机验证生效。整谱不判的根因 = handler 门 2 方向写反（与门 1 同向：bit0==1 即 return 0）。
- **判定链解剖（2026-09-10）**：双分支时钟（flag45）；CMP 级联 26/51/101/121（B）与 25/50/100/120（A）；LN 近失落账 `sub_100ACB6A4`。见工作区笔记 `research/notes/ios-7.0.255-judgement-correction-2026-09-10.md`。
- **变速定位（2026-09-06→09）**：GameScene vtable 槽 103 = `sub_100CA7160`（帧去重模式确认）；槽 155 是场景初始化（只跑一次）——vtable 槽的"每帧性"必须用帧去重特征确认。
- **音频链重定位（2026-09-06）**：MTP vtable `0x14B75B0`、getpos 槽 7、seek 槽 8、`Channel::getPosition`、`getCurrentSound`；决策不 hook FMOD（音画同步 DNR）。
- **基准切换（2026-09-06）**：6.13 适配废弃，profile 单版本 7.0.255；6.13 知识转为跨版本手册。

## 历史教训（PROTO，保留供跨版本决策）

- 运行时改写主程序 `__TEXT`：普通侧载下不可行（页签名）。
- note 对象级 replay（清 active list / 重激活 / vtable 手术）导致 UAF——重放的正确设施是"游戏自己的场景重建（Retry）+ 时钟平移"。
- v7.3 graft（entry→trampoline→slot）概念可行；现代实现 = v2 跳板 + slot v2 + info blob（本仓 inject.py）。
