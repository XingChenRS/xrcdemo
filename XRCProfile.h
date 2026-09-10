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
// ABI: X0 = note_group, X1 = note, X2 = ts（判定时刻 ms）；返回 1 = 消费该 note，
// 0 = Miss（不消费）。handler 另收 X3 = caller X6（跳板 v2 的 MOV X3,X6）。
#define XRC_HAS_JUDGE_STUB          1
#define XRC_JUDGE_STUB_ENTRY_OFF    (0x91E684ULL)   // sub_10091E684（判定核心，2 处直接 BL 调用）
#define XRC_OFF_JUDGE_COMMIT_FN     (0xACB880ULL)   // sub_100ACB880（grade 落账，6 参，首指令是门）
#define XRC_OFF_JUDGE_COMMIT_LN_FN  (0xACB6A4ULL)   // sub_100ACB6A4（近失/长条落账，3 参）
#define XRC_OFF_JUDGE_FX_OBJ        (64)            // note_group+64 = 特效对象
#define XRC_OFF_JUDGE_COMMIT_OBJ    (56)            // note_group+56 = 判定计数对象
// 桩跳板（inject.py 生成，跳板 v2 = 40B：分发 + MOV X3,X6 + native 重放 3 条）
// 布局：ADRP/ADD(8) LDR(4) CBZ(4) MOV X3,X6(4) BR(4) → native 重放 3 条原指令
// + B 回 entry+12。handler 从 X3 拿 caller 的 X6（判定核从不写、落账函数需要）。
// 直通（slot.handler==0）= CBZ 跳 native，行为与未注入完全一致。
#define XRC_STUB_TRAMP_OFF          (0x146800CULL)  // trampoline 静态偏移
#define XRC_STUB_TRAMP_NATIVE_OFF   (XRC_STUB_TRAMP_OFF + 24)

// 判定函数的 8 个 CMP 阈值站点（CMP Wn,#imm12）。
// 2026-09-10 定案：**handler + 运行时阈值**取代立即数改写（dylib 写 __TEXT 会撞
// CT/PAC，见功能矩阵形态 4）。这些偏移保留用于：(a) 跨版本指纹校验；
// (b) 静态烘焙路线（重打包版把 imm12 直接写成目标值 → 无需桩点）。
// 分支 B（分段钟，clk+45==1）：26/51/101/121
#define XRC_CMP_B_PURE              (0x91E720ULL)
#define XRC_CMP_B_FAR               (0x91E728ULL)
#define XRC_CMP_B_LOST              (0x91E730ULL)
#define XRC_CMP_B_MISS              (0x91E738ULL)
// 分支 A（普通钟）：25/50/100/120
#define XRC_CMP_A_PURE              (0x91E788ULL)
#define XRC_CMP_A_FAR               (0x91E7CCULL)
#define XRC_CMP_A_LOST              (0x91E810ULL)
#define XRC_CMP_A_MISS              (0x91E848ULL)
// 注入器在 __DATA 零填充尾部写入 slot v2（24B）+ info blob（120B，紧邻其后）。
#define XRC_JUDGE_SLOT_OFF          (0x164AB28ULL)
#define XRC_INFO_OFF                (0x164AB40ULL)   // slot + 24

// note 字段（改判 handler 读；replay-chain 笔记 §3.2）
#define XRC_NOTE_TYPE_OFF           28
#define XRC_NOTE_TIME_OFF           24
#define XRC_NOTE_PURE_OFF           32
#define XRC_NOTE_FAR_OFF            36
#define XRC_NOTE_LOST_OFF           40

// ---------------- 转场 / 循环 ----------------
// 出处: research/notes/ios-7.0.255-replay-chain.md §6 + 诊断笔记 §7
// 状态（2026-09-10 真机 + 定案）：直调转场必崩——sub_100CA9590 内部先构造新场景、
// 之后才读旧场景 note group（sub_10091BBB8(v3[116])），该指针已被拆为 NULL
// → far=0x30 空指针（两次真机崩溃确认）。
// 定案：**replay 不再走转场**。seek 平移（音频 seek + 谱面钟 base 平移）即
// 重播路线；循环 = 到 B 点 deferred 回 A。已判 note 不重现、计分不回滚，
// 属"练习定位"语义；需要完整重播时用户在暂停菜单自行 retry 后再 seek。
// XRC_HAS_TRANSITION 仅控制"直调转场"这条已废弃的路线，保持 0。
#define XRC_HAS_TRANSITION          0
#define XRC_TRANSITION_VTABLE_SLOT  178     // 仅探针引用（槽存在性探测）
#define XRC_TRANSITION_FLAG_OFF     1144  // a2=1 转场标志（历史记录）
#define XRC_RESUME_POS_OFF          1140  // 新场景恢复位置（历史记录）

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
