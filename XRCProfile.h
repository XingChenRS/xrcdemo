// XRCProfile.h — 版本契约（Arcaea iOS 7.0.255）。
// 跨版本迁移只改本文件（+ 注入器侧 profiles/<version>.json）。
// 纪律：每个偏移必须有出处注释（逆向结论/实测记录）；禁止只改代码不加出处。
// 跨版本锚点：判定核/每帧更新/谱面钟/音频链/转场恢复在 6.13.10 与
// 7.0.255 均已定位（判定核入口与 CMP 站点字节级同构）——新版本按
// 同一指纹重定位后，只改本文件的偏移宏。
#pragma once

#include <stdint.h>
#include <stdbool.h>

// ---------------- 谱面钟对象布局 ----------------
// 出处: 逆向笔记 §4
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
// 出处: 逆向笔记 §2/§3
// （vtable RTTI 名 9GameScene 已验；本文件所有值均为 image 偏移，
//   运行时地址 = image_base + offset）
#define XRC_OFF_GP_VTABLE          (0x151D8C0ULL)   // 绝对 VA 0x10151D8C0
// 每帧更新 = vtable 槽 103 sub_100CA7160（帧去重模式与 6.13 gp.update 同源：
// 全局时间 +308 == self+1168 走快路径；否则 tick note group + 判定分发）。
// 真机验证 2026-09-06：槽 155（sub_100CA118C）是场景初始化函数（只跑一次），
// 不是每帧更新——已纠正。
#define XRC_OFF_GP_UPDATE_FN       (0xCA7160ULL)    // 五参 (self,a2,a3,a4,a5)，同 6.13

// ---------------- 桩点（改判） ----------------
// 出处: 逆向笔记// 判定核心 = sub_10091E684（与 6.13 sub_100870FD0 逐行同构的整数 CMP 级联；
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

// ---------------- retry 触发链（研究记录；**已停用，禁止调用**） ----------------
// 出处: 逆向笔记 §11（retry 三层链路逆向）
// 结论（2026-09-10，三次真机尝试）：程序化 retry 不可行——直调
// triggerAction(GameModel, 13, 1) 及"建暂停层+推进度"组合全部被游戏静默
// 忽略（Retry 回调首校验 PauseLayer+0x298==1），且重复触发会污染 GameModel
// action 队列，导致玩家手动 retry 卡死在转场界面（v8.9.8 实测）。
// 相关偏移（qword_101673DD8 服务定位器 +0x10=GameModel、sub_100B69644
// 触发函数、sub_100BACD34/sub_100947C20 暂停层工厂与 setup）**不落入 profile**
// ——此处只留研究指针，代码不得引用。手动 retry 由玩家操作，插件仅做
// "音频回跳检测 → 回循环 A"（见 XRCGameplay.m retry watchdog）。

// note 字段（改判 handler 读；replay-chain 笔记 §3.2）
#define XRC_NOTE_TYPE_OFF           28
#define XRC_NOTE_TIME_OFF           24
#define XRC_NOTE_PURE_OFF           32
#define XRC_NOTE_FAR_OFF            36
#define XRC_NOTE_LOST_OFF           40

// ---------------- 转场 / 循环 ----------------
// 出处: 逆向笔记 §6 + 诊断笔记 §7
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

// ---------------- BRK 桩（实验：第二种插桩形态，替代 trampoline）----------------
// 出处: 2026-09-11 机制验证。原理：注入器把目标指令原地改成 `BRK #0`（4B，长度
// 不变），dylib 用 SIGTRAP 处理器接住，跑完自己的逻辑后把 ucontext 的 PC 指到
// 预建的"重放跳板"（原始指令 + B 回 site+4），执行流无感继续。
//
// 与既有 trampoline v2 的取舍：
//   trampoline v2 = 改函数入口前 12B 为 ADRP/ADD/BR，跳板重放前 3 条 —— 仅适用
//                   函数入口，且要吃满入口 12 字节。
//   BRK 桩        = 任意单条指令可打，补丁长度不变、不动入口结构；代价是引入
//                   SIGTRAP 处理器（必须正确 chain 给前一个处理器，否则会吞掉
//                   Swift 运行时 / Crashlytics 的陷阱）。
//
// 验证目标刻意选在 **applog 发送函数入口**（OnlineManager 槽 72）——既证明机制，
// 又顺带回答"applog 何时触发"，且不碰改判/seek/循环/变速四项。
#define XRC_HAS_BRK_HOOK            1
#define XRC_BRK_APPLOG_SITE_OFF     (0x623AECULL)   // sub_100623AEC 入口（VA 0x100623AEC）
#define XRC_BRK_APPLOG_REPLAY_OFF   (0x1468040ULL)  // 重放跳板（__TEXT 空白页，VA 0x101468040）
#define XRC_BRK_MAX_SLOTS           8

// 第二个桩点：log_blob 组装处（密文出口）。
// 出处: 2026-09-12 静态定位 + 2026-09-13 真机验证。
//   sub_100623AEC 在 0x1006399B0..0x1006399D8 把待发送的 std::string 从
//   sp+0x290(var_380) 拷到 **sp+0x240(var_410)**，紧随其后 0x1006399DC
//   `adrl x1, "log_blob"` 就把这个值当成表单字段的值 —— 所以 **sp+0x240 处就是
//   log_blob 的值（密文）**。（0x290 是它的源，同一份数据；取 0x240 更贴近语义。）
//   桩点选 0x1006399E4（`add x0, sp, #var_428`）而不是 0x1006399DC：
//   后者是 ADRL（PC 相对），重放跳板在别处执行会算错目标；前者是 SP 相对，重放安全
//   （已用 capstone 核对：site 处指令就是 `add x0, sp, #0x1e8`）。
//   命中时 handler 从 ucontext 取 SP，按 libc++ std::string 布局解出密文并捕获。
#define XRC_BRK_APPLOG_BLOB_SITE_OFF   (0x6399E4ULL)
#define XRC_BRK_APPLOG_BLOB_REPLAY_OFF (0x1468050ULL)  // 紧邻上一个跳板，8B，已核对为全零
#define XRC_APPLOG_BLOB_STR_OFF        (0x240ULL)      // SP + 该值 = log_blob 值 std::string

// ---------------- 私服接入（XRCNet）----------------
// 出处: 2026-09-12 真机内存转储分析（incoming/xrcdemo-net/mem，277MB）。
// 7.0 的 API base 多了一层 codename + 版本号：
//     https://arcapi-v4.lowiro.com/coordinatedballetclock/42/<endpoint>
// **codename 不存在于静态二进制**（明文/UTF-16/片段均无），只出现在运行时拼好的
// URL 里（以 NSURLRequest 的 bplist 形式驻留内存）——来源未定，可能服务端下发。
// 因此 XRCNet 只改写 scheme/host/port，**保留 path 与 query**，服务端按版本段之后
// 的 suffix 路由即可，与该前缀解耦。
// pin：pin 表按域名查询，换到自有域名后返回 DomainNotPinned → 放行；故无需绕 pin。
#define XRC_NET_DEFAULT_MATCH \
    "arcapi-v4.lowiro.com,arcapi-v3.lowiro.com,auth-v2.lowiro.com,auth.lowiro.com"

// applog 明文的来源（2026-09-11 定位）：
//   sub_100623AEC 内 0x100625434 处 `LDR X8,[SP,#var_5F8]`（= 入口 X0，OnlineManager）
//   紧接 `LDP X19,X21,[X8,#0x128]` —— X19/X21 即 payload 缓冲区的 begin/end，
//   随后用它们算区间长度并做内联 XXTEA。因此**入口处就能读到整段明文**，
//   无需在函数体内部另设桩点。
#define XRC_APPLOG_BUF_BEGIN_OFF    (0x128)   // OnlineManager → uint8* 明文起点
#define XRC_APPLOG_BUF_END_OFF      (0x130)   // OnlineManager → uint8* 明文终点
#define XRC_BRK_CAP_MAX             (1u << 20)  // 单次捕获上限 1MB（超出只记长度）

// ---------------- OnlineManager 探针 / applog 强发（XRCOMLog）----------------
// 出处: 2026-09-12 真机内存转储（incoming/xrcdemo-net-new/mem, 276MB, 972 区域）
//       + 静态复核（IDA 8745）。
//   vtable: 0x10149C100 起（[0]=offset-to-top=0、[8]=typeinfo、0x10149C110 起为槽 0）；
//           对象的 vptr 指向**地址点** 0x10149C110（= _ZTV + 0x10，与 lambda 那套同构）。
//   typeinfo 名实测 "13OnlineManager"；槽 72 = sub_100623AEC = applog 发送。
//   单例定位：真机 dump 里 vptr 值全进程**唯一命中**（对象在堆上、每次启动地址变，
//             所以运行时按值扫描，不写死地址）。
//   载荷: +0x128/+0x130 = begin/end —— sub_100623AEC 在 0x100625438 处
//         `LDP X19,X21,[X8,#0x128]` 实证（X8 = 入口 X0）。
//         注意：**该区间只在调用期间有效**（空闲态 dump 里是非指针垃圾），
//         所以空闲期转储看不到载荷，只有入口桩能抓。
//   累加器候选: dump 实测 +0xf0=250 / +0xf8,+0x100,+0x108 = ptr,ptr,30，
//         (end-begin)/24 = 24 → 疑似 std::vector<std::string>（元素 24B），
//         capacity 30 ≥ size 24。语义待 XRCOMLog 探针实测确认。
#define XRC_OM_VTABLE_OFF           (0x149C110ULL)  // vtable 地址点（vptr 值）
#define XRC_OM_APPLOG_SLOT          (72)            // applog 发送（虚槽）
#define XRC_OM_OFF_ACC_COUNT        (0xf0)          // 疑似累计计数
#define XRC_OM_OFF_VEC_BEGIN        (0xf8)          // 疑似 vector<string> begin
#define XRC_OM_OFF_VEC_END          (0x100)         // 同上 end
#define XRC_OM_OFF_VEC_CAP          (0x108)         // 同上 capacity
#define XRC_OM_OFF_USER_ID          (0x140)         // 账号 user_id（dump 实测 2000002）
#define XRC_OM_OFF_FIFTY            (0x148)         // dump 实测 50（= sub_10000A7F0 的 0x32）
