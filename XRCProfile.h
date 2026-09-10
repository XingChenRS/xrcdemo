// XRCProfile.h — 版本契约（Arcaea iOS 7.0.255）。
// 跨版本迁移只改本文件（+ 注入器侧 profiles/<version>.json）。
// 纪律：每个偏移必须有 research/notes 出处注释；禁止只改代码不加出处。
// 6.13 适配已废弃（见 DEVLOG 2026-09-06）；历史 6.13 偏移在 git 历史与
// research/notes/ios-6.13.10-stage1-patch-plan.md。
#pragma once

#include <stdint.h>
#include <stdbool.h>

// ---------------- 谱面钟对象布局 ----------------
// 出处: research/notes/ios-7.0.255-replay-chain.md §4
// （与 6.13 真机验证的布局逐字节一致；+45 标志/+40 base/+52 当前/-3000 前导）。
#define XRC_CLK_FLAG45_OFF        45   // =1 时走分段钟分支（读 +32）
#define XRC_CLK_BASE_OFF          40   // seek 平移目标（base_off）
#define XRC_CLK_ALT_START_OFF     32   // flag45=1 分支的起始值
#define XRC_CLK_CUR_OFF           52   // 非分段钟当前值（<=0 时 -3000 前导）
#define XRC_CLK_NEG_LEAD_MS       (-3000)

// gameplay 对象 → note group（6.13 称 logic）→ 谱面钟
#define XRC_GP_NOTEGROUP_OFF       928
#define XRC_CLOCK_IN_NOTEGROUP_OFF 48

// ---------------- GameScene ----------------
// 出处: research/notes/ios-7.0.255-replay-chain.md §2/§3
// （vtable RTTI 名 9GameScene 已验；本文件所有值均为 image 偏移，
//   运行时地址 = image_base + offset）
#define XRC_OFF_GP_VTABLE          (0x151D8C0ULL)   // 绝对 VA 0x10151D8C0
// 每帧更新 = vtable 槽 103 sub_100CA7160（帧去重模式与 6.13 gp.update 同源：
// 全局时间 +308 == self+1168 走快路径；否则 tick note group + 判定分发）。
// 真机验证 2026-09-06：槽 155（sub_100CA118C）是场景初始化函数（只跑一次），
// 不是每帧更新——已纠正。
#define XRC_OFF_GP_UPDATE_FN       (0xCA7160ULL)    // 五参 (self,a2,a3,a4,a5)，同 6.13

// ---------------- 桩点（改判） ----------------
// 出处: research/notes/ios-7.0.255-judgement-correction-2026-09-10.md
// 判定核心 = sub_10091E684（与 6.13 sub_100870FD0 逐行同构的整数 CMP 级联；
// 此前误把 sub_1009D9ED8/表B 当判定——那是特效显示链，已更正）。
// ABI: X0 = note_group, X1 = note；返回 1 = 消费该 note，0 = Miss
#define XRC_HAS_JUDGE_STUB          1
#define XRC_JUDGE_STUB_ENTRY_OFF    (0x91E684ULL)   // sub_10091E684（判定核心，2 处直接 BL 调用）
#define XRC_OFF_JUDGE_COMMIT_FN     (0xACB880ULL)   // sub_100ACB880（grade 落账）
// 注入器在 __DATA 零填充尾部写入 slot + info blob
#define XRC_JUDGE_SLOT_OFF          (0x164AB28ULL)
#define XRC_INFO_OFF                (0x164AB38ULL)

// note 字段（改判 handler 读；replay-chain 笔记 §3.2）
#define XRC_NOTE_TYPE_OFF           28
#define XRC_NOTE_TIME_OFF           24
#define XRC_NOTE_PURE_OFF           32
#define XRC_NOTE_FAR_OFF            36
#define XRC_NOTE_LOST_OFF           40

// ---------------- 转场重放 ----------------
// 出处: research/notes/ios-7.0.255-replay-chain.md §6
// 状态（2026-09-10 真机）：直调转场必崩——sub_100CA9590 内部先构造新场景、
// 之后才读旧场景 note group（sub_10091BBB8(v3[116])），该指针已被拆为 NULL
// → far=0x30 空指针。游戏自身从 pause 菜单走 retry 时有完整前置序。
// 正解 = 驱动游戏自己的 retry（pause 菜单 retryButton 回调），见
// research/notes/ios-7.0.255-arcdemo-diagnosis-2026-09-10.md。
// 在 retry 路线落地前，XRC_HAS_TRANSITION 关闭（UI 隐藏 replay/循环）。
#define XRC_HAS_TRANSITION          0
#define XRC_TRANSITION_VTABLE_SLOT  178
#define XRC_TRANSITION_FLAG_OFF     1144  // a2=1 转场标志
#define XRC_RESUME_POS_OFF          1140  // 新场景恢复位置（ms）

// ---------------- 音频链（seek/进度条） ----------------
// 出处: 2026-09-06 重定位（研究笔记 ios-7.0.255-replay-chain.md 未含本段，
// 锚点链：6.13 RTTI 名 20AudioProviderFMODiOS → 7.0 typeinfo 0x1014B7690
// → MTP vtable 0x1014B75B0；getpos 槽 7 与 seek 槽 8 形状与 6.13 逐条一致）
// 决策：不 hook FMOD 变速；只读位置 + seekTo。
#define XRC_OFF_MTP_VTABLE           (0x14B75B0ULL)   // 绝对 VA 0x1014B75B0（注意：偏移是 0x14B75B0）
#define XRC_OFF_MTP_GETPOS           (0x8E24F0ULL)    // vtable 槽 7，形状同 6.13
#define XRC_PLAYER_SEEK_SLOT_OFF     (0x40)           // vtable 槽 8，形状同 6.13
#define XRC_OFF_CH_GET_POSITION      (0x1033BBCULL)   // Channel::getPosition（内层同源）
#define XRC_OFF_GET_CURRENT_SOUND    (0x103415CULL)   // Channel::getCurrentSound（日志串已验）
// 未定位（进度条用 max_seen 兜底；P1 补）：get_sound_length
// 不再需要（getpos hook 直接缓存 player 实例）：get_registry
#define XRC_OFF_GET_REGISTRY        0
#define XRC_OFF_GET_SOUND_LENGTH    0
#define XRC_REG_PLAYER_OFF          (8)
#define XRC_PLAYER_CHANNELS_OFF     (0x38)
#define XRC_CHANNEL_ENTRY_PTR_OFF   (8)
