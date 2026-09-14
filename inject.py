"""
Inject libxrcdemo.dylib + libellekit.dylib into Arc-mobile.app.

Two independent stages:

1. dylib injection (default): copy dylibs, insert LC_LOAD_DYLIB / LC_RPATH
   into the existing load-command padding.
2. judge stub (--stub): patch sub_1009D9ED8 entry -> trampoline in __TEXT tail
   zero-padding -> slot in __DATA tail zero-padding. No Mach-O header surgery;
   both regions lie inside the existing segment filesizes. Re-sign afterwards
   (the user signs the result).

Stub facts (Arcaea iOS 7.0.255):
  entry      vm 0x1009D9ED8  (fileoff 0x9D9ED8)
  trampoline vm 0x10146800C  (fileoff 0x146800C, __TEXT tail zero-run 0x146800a..0x146c000)
  slot       vm 0x10164AB28  (fileoff 0x164AB28, __DATA tail zero-run 0x164ab25..0x164c000)
  distance entry->tramp = 177MB > B range -> ADRP+ADD+BR absolute (12 bytes,
  replays first 3 insns of the entry prologue).
"""
import os
import shutil
import struct
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(ROOT, "ios", "Payload", "Arc-mobile.app")
MAIN = os.path.join(APP, "Arc-mobile")
FW_DIR = os.path.join(APP, "Frameworks")
DYLIB_NAMES = ["libxrcdemo.dylib", "libellekit.dylib"]
INJECT_NAME = "@rpath/libxrcdemo.dylib"

LC_LOAD_DYLIB = 0x8000000C
LC_RPATH = 0x8000001C

# ---- judge stub constants (7.0.255, corrected 2026-09-10) ----
# 判定核心 = sub_10091E684（整数 CMP 级联；与 6.13 sub_100870FD0 入口及 CMP
# 站点字节级同构——跨版本可直接按字节指纹重定位，见 README §4）。
# 注意：sub_1009D9ED8 是特效显示链，不是判定核。
STUB_ENTRY_VA   = 0x10091E684
STUB_ENTRY_FILE = 0x91E684
STUB_TRAMP_VA   = 0x10146800C
STUB_TRAMP_FILE = 0x146800C
STUB_SLOT_VA    = 0x10164AB28
STUB_SLOT_FILE  = 0x164AB28
STUB_INFO_VA    = 0x10164AB40   # slot + 24（slot v2 由 16B 扩为 24B）
STUB_INFO_FILE  = 0x164AB40
# expected first 3 insns at entry (file byte order; IDA dwords
# a9bc5ff8=a90157f6=a9024ff4 as STP X24,X23 / STP X22,X21 / STP X20,X19):
STUB_ENTRY_EXPECT = bytes.fromhex("f85fbca9f65701a9f44f02a9")

XRC_MAGIC = 0x58424331  # 'XRC1'
XRC_INFO_VERSION = 2  # blob 版本：v2 = slot 24B + 判定链 ABI

# ---- BRK 桩（实验形态，2026-09-11）----
# 把目标指令原地改成 `BRK #0`（D4200000，4B 长度不变），dylib 用 SIGTRAP 处理器
# 接住并把 PC 指向重放跳板。跳板 = 原始指令 + B 回 site+4，共 8B。
# 与判定桩的 40B 跳板（fileoff 0x146800C..0x1468034）不重叠。
BRK_INSN = struct.pack("<I", 0xD4200000)
# (名称, site VA, replay VA, 原字节 hex 或 None) —— replay 必须落在 __TEXT 空白页且互不重叠。
# replay 区分配：judge 跳板 0x146800C..0x1468034；BRK 重放自 0x1468040 起，8B/桩。
# expect 非 None 时做"原字节断言"（防版本漂移；已打桩的二进制跳过断言）。
BRK_HOOKS = [
    ("applog_send", 0x100623AEC, 0x101468040, None),   # sub_100623AEC 入口（OnlineManager 槽 72）
    # log_blob 组装处（密文出口）：待发送的 std::string 在 sp+0x290。
    # 选 0x1006399E4（add x0,sp,#var_428）而非前一条 ADRL —— ADRL 是 PC 相对指令，
    # 重放跳板在别处执行会算错目标，这里只收 SP 相对/绝对寻址的指令。
    ("applog_blob", 0x1006399E4, 0x101468050, None),
    # ---- 拥有/解锁链（功能账 §1.1，2026-09-14 重定位）----
    # 层1 取第 2 条指令：首条 CBZ X1 是 PC 相关指令、不可重放；本条 LDR X9,[X0,#0x268] 安全。
    ("unlock_l1",  0x100BE46AC, 0x101468058, "093441f9"),  # 层1 sub_100BE46A8 +4（拥有表线性扫描）
    ("unlock_l2",  0x100BE46EC, 0x101468060, "ff0302d1"),  # 层2 sub_100BE46EC 入口（SUB SP,#0x80）
    ("unlock_l3",  0x100BE4D38, 0x101468068, "fd7bbfa9"),  # 层3 sub_100BE4D38 入口（STP X29,X30,[SP,#-0x10]!）
    ("story_gate", 0x1009346E0, 0x101468070, "ffc301d1"),  # 故事门 sub_1009346E0 入口（SUB SP,#0x70）
    # ---- cb 验证链（功能账 §3，2026-09-14 重定位）----
    ("cb_ready",    0x100F43274, 0x101468078, "00a04039"),  # 就绪位 getter（LDRB W0,[X0,#0xA];RET）
    ("cb_verify",   0x100F43FFC, 0x101468080, "fc6fbaa9"),  # 全树校验入口（STP X28,X27,[SP,#-0x60]!）
    ("cb_dispatch", 0x10013C5E8, 0x101468088, "ff0304d1"),  # 更新错码分发入口（SUB SP,#0x100）
    # ---- 解锁条件"内部计数"判定（功能账 §1.2）----
    ("judge107", 0x100AB300C, 0x101468090, "080840b9"),  # SpellMagnolia 判定（LDR W8,[X0,#8]）
    ("judge110", 0x100184064, 0x101468098, "080c40b9"),  # ArghenaCourse 判定（LDR W8,[X0,#0xC]）
    ("judge112", 0x100184084, 0x1014680A0, "080c40b9"),  # AlterEgoPuzzle 判定
    ("judge108", 0x100183FDC, 0x1014680A8, "f44fbea9"),  # ArghenaStories 判定（STP X20,X19,[SP,#-0x20]!）
]
# 重放跳板必须避免 PC 相关指令（ADRP/ADR/B/BL/CBZ/TBZ/LDR-literal）——
# 跳板在别处执行，PC 相对寻址会算错。这里只做"显然安全"的粗筛并提示。
_PC_REL_MASK_HINT = (
    0x1F000000,  # B / BL 族（0x14000000 / 0x94000000）
)

# 静态偏移（VA - image base 0x100000000）
GP_VTABLE_OFF   = 0x151D8C0   # GameScene vtable
GP_UPDATE_OFF   = 0xCA7160    # 槽 103 每帧函数
MTP_VTABLE_OFF  = 0x14B75B0   # MTP vtable
MTP_GETPOS_OFF  = 0x8E24F0    # 槽 7


def encode_adrp_add_br(pc_addr: int, dst: int, reg: int = 16) -> bytes:
    """ADRP reg, dst_page; ADD reg, reg, #pgoff; BR reg (12 bytes)."""
    pc_page = pc_addr & ~0xFFF
    dst_page = dst & ~0xFFF
    imm = (dst_page - pc_page) >> 12
    imm &= 0x1FFFFF  # 21-bit 符号扩展
    adrp = 0x90000000 | ((imm & 3) << 29) | (((imm >> 2) & 0x7FFFF) << 5) | reg
    add = 0x91000000 | ((dst & 0xFFF) << 10) | (reg << 5) | reg
    br = 0xD61F0000 | (reg << 5)
    return struct.pack("<III", adrp, add, br)


def encode_b(pc_addr: int, dst: int) -> int:
    off = (dst - pc_addr) >> 2
    assert -0x2000000 <= off < 0x2000000, "B out of range"
    return 0x14000000 | (off & 0x3FFFFFF)


def build_trampoline() -> bytes:
    """Full-takeover trampoline v2 (2026-09-10)。

    v1 只保 X0/X1/X2；判定核 sub_10091E684 的第 6 参 X6 由调用方透传进落账
    函数 sub_100ACB880（judge 自身从不写 X6），handler 重排参数后必须原样
    转发。v2 在 BR 前插一条 `MOV X3, X6`，把 a6 作为 handler 的第 4 参传入——
    无需动 SP、无需保存区，跳板只做分发与一次寄存器搬移。

    handler 签名（与 xrc_abi.h 一致）：
        uint64_t handler(ng /*x0*/, note /*x1*/, ts /*x2*/, a6 /*x3=X6*/)
    handler 用普通 C 函数（BR 不改 LR，其 RET 直接回到判定核的调用方）。

    布局（40B，< 64B 上限）：
      0  ADRP X9, slot_page
      4  ADD  X9, X9, #pgoff
      8  LDR  X9, [X9]        (slot+0 = handler)
      12 CBZ  X9, native
      16 MOV  X3, X6
      20 BR   X9
      24 native: replay 3 insns (12B) + B entry+12
    """
    out = bytearray()
    pc_page = STUB_TRAMP_VA & ~0xFFF
    slot_page = STUB_SLOT_VA & ~0xFFF
    imm = (slot_page - pc_page) >> 12
    adrp = 0x90000000 | ((imm & 3) << 29) | (((imm >> 2) & 0x7FFFF) << 5) | 9
    add = 0x91000000 | ((STUB_SLOT_VA & 0xFFF) << 10) | (9 << 5) | 9
    out += struct.pack("<II", adrp, add)             # ADRP/ADD X9, slot
    out += struct.pack("<I", 0xF9400129)             # LDR X9, [X9]
    native_va = STUB_TRAMP_VA + 24
    off = (native_va - (STUB_TRAMP_VA + 12)) >> 2
    out += struct.pack("<I", 0xB4000000 | ((off & 0x7FFFF) << 5) | 9)  # CBZ X9, native
    out += struct.pack("<I", 0xAA0603E3)             # MOV X3, X6
    out += struct.pack("<I", 0xD61F0120)             # BR X9
    out += STUB_ENTRY_EXPECT                         # native: 重放前 3 条
    out += struct.pack("<I", encode_b(native_va + 12, STUB_ENTRY_VA + 12))
    return bytes(out)

def build_info_blob() -> bytes:
    """xrc_info 结构：magic + version + 6 个静态偏移 + reserved[8]。
    dyld 不 rebase 零填充区（不在 rebase 列表），dylib 手动重定位。"""
    fields = [
        XRC_MAGIC, 2,   # version 2: slot 24B + 判定链 ABI（v1 为 1）

        STUB_ENTRY_VA - 0x100000000,   # judge_entry_off
        STUB_SLOT_VA - 0x100000000,    # judge_slot_off
        GP_VTABLE_OFF,
        GP_UPDATE_OFF,
        MTP_VTABLE_OFF,
        MTP_GETPOS_OFF,
    ] + [0] * 8
    return struct.pack("<II6Q8Q", *fields)


def patch_judge_stub(data: bytearray) -> list[str]:
    logs = []
    base = fat_arm64_slice_offset(bytes(data))
    entry_file = base + STUB_ENTRY_FILE
    cur = bytes(data[entry_file:entry_file + 12])
    if cur != STUB_ENTRY_EXPECT:
        raise RuntimeError(
            f"stub entry bytes mismatch at {entry_file:#x}: {cur.hex()} "
            f"(expected {STUB_ENTRY_EXPECT.hex()}) — wrong binary version?"
        )
    tramp = build_trampoline()
    tramp_file = base + STUB_TRAMP_FILE
    if len(tramp) > 0x40:
        raise RuntimeError("trampoline too large")
    # verify zero region
    if bytes(data[tramp_file:tramp_file + len(tramp)]) != b"\0" * len(tramp):
        raise RuntimeError(f"trampoline region not zero @ {tramp_file:#x}")
    data[tramp_file:tramp_file + len(tramp)] = tramp
    logs.append(f"trampoline ({len(tramp)}B) @ fileoff {tramp_file:#x} (vm {STUB_TRAMP_VA:#x})")

    # slot v2: 24 bytes {handler=0, orig=STUB_ENTRY_VA, reserved=0}
    slot_file = base + STUB_SLOT_FILE
    if bytes(data[slot_file:slot_file + 24]) != b"\0" * 24:
        raise RuntimeError(f"slot region not zero @ {slot_file:#x}")
    data[slot_file:slot_file + 24] = struct.pack("<QQQ", 0, STUB_ENTRY_VA, 0)
    logs.append(f"slot v2 (24B) @ fileoff {slot_file:#x} (vm {STUB_SLOT_VA:#x})")

    # info blob: 桩点回报信息（运行时锚点清单，dylib 手动重定位）
    info = build_info_blob()
    info_file = base + STUB_INFO_FILE
    if bytes(data[info_file:info_file + len(info)]) != b"\0" * len(info):
        raise RuntimeError(f"info region not zero @ {info_file:#x}")
    data[info_file:info_file + len(info)] = info
    logs.append(f"info blob ({len(info)}B) @ fileoff {info_file:#x} (vm {STUB_INFO_VA:#x})")

    # entry patch: ADRP/ADD/BR X16 -> trampoline
    patch = encode_adrp_add_br(STUB_ENTRY_VA, STUB_TRAMP_VA)
    data[entry_file:entry_file + 12] = patch
    logs.append(f"entry patched ({12}B) @ vm {STUB_ENTRY_VA:#x} -> tramp")
    return logs


def pc_relative_kind(w: int) -> str | None:
    """返回 PC 相关指令的名称（不能在别处重放），否则 None。"""
    if (w >> 26) in (0b000101, 0b100101):
        return "B/BL"
    if (w & 0x9F000000) in (0x10000000, 0x90000000):
        return "ADR/ADRP"
    if (w & 0x7E000000) == 0x34000000:
        return "CBZ/CBNZ"
    if (w & 0x7E000000) == 0x36000000:
        return "TBZ/TBNZ"
    if (w & 0x3B000000) == 0x18000000:
        return "LDR-literal"
    return None


def patch_brk_hooks(data: bytearray) -> list[str]:
    """把 BRK_HOOKS 里的每个 site 改成 `BRK #0`，并在 replay 处建重放跳板。

    跳板 = 原始 4 字节 + `B site+4`。原始指令若 PC 相关则拒绝（在别处重放会算错）。
    """
    logs = []
    base = fat_arm64_slice_offset(bytes(data))
    for name, site_va, replay_va, expect in BRK_HOOKS:
        site_file = base + (site_va - 0x100000000)
        replay_file = base + (replay_va - 0x100000000)
        orig = bytes(data[site_file:site_file + 4])
        if len(orig) != 4:
            raise RuntimeError(f"brk[{name}]: site {site_va:#x} out of range")
        if orig == BRK_INSN:
            logs.append(f"brk[{name}]: already patched @ {site_va:#x}")
            continue
        if expect is not None and orig.hex() != expect:
            raise RuntimeError(
                f"brk[{name}]: site {site_va:#x} bytes {orig.hex()} != expected "
                f"{expect} — wrong binary version?"
            )
        w = struct.unpack("<I", orig)[0]
        kind = pc_relative_kind(w)
        if kind:
            raise RuntimeError(
                f"brk[{name}]: site insn {orig.hex()} is {kind} — not replay-safe"
            )
        tramp = orig + struct.pack("<I", encode_b(replay_va + 4, site_va + 4))
        if bytes(data[replay_file:replay_file + len(tramp)]) != b"\0" * len(tramp):
            raise RuntimeError(f"brk[{name}]: replay region not zero @ {replay_file:#x}")
        data[replay_file:replay_file + len(tramp)] = tramp
        data[site_file:site_file + 4] = BRK_INSN
        logs.append(
            f"brk[{name}]: {site_va:#x} -> BRK#0 (orig {orig.hex()}), "
            f"replay @ {replay_va:#x}"
        )
    return logs


def patch_ats() -> list[str]:
    """给 app 的 Info.plist 开 ATS 豁免，否则明文 HTTP 连自有服务端会被拦。

    ⚠️ 关键规则（2026-09-12 踩过的坑）：iOS 10+ 上，只要 NSAppTransportSecurity
    里存在 NSAllowsLocalNetworking / NSAllowsArbitraryLoadsInWebContent /
    NSAllowsArbitraryLoadsForMedia 中**任意一个**，系统就会**忽略**
    NSAllowsArbitraryLoads。而 NSAllowsLocalNetworking 只覆盖 .local 与无后缀
    主机名，**不覆盖数字 IP**——两者同时存在会导致 http://<内网IP> 仍被拦。

    因此这里只写 NSAllowsArbitraryLoads=true，并主动移除其它 Allows* 键。
    NSLocalNetworkUsageDescription 另加（iOS 14+ 本地网络权限说明；TrollStore
    安装的 app 因 platform-application entitlement 通常被豁免，不弹窗属正常）。
    """
    import plistlib
    logs = []
    plist_path = os.path.join(APP, "Info.plist")
    if not os.path.isfile(plist_path):
        raise RuntimeError(f"Info.plist not found: {plist_path}")
    with open(plist_path, "rb") as f:
        pl = plistlib.load(f)
    ats = dict(pl.get("NSAppTransportSecurity", {}))
    changed = False
    # 去掉会让 NSAllowsArbitraryLoads 失效的键
    for k in ("NSAllowsLocalNetworking",
              "NSAllowsArbitraryLoadsInWebContent",
              "NSAllowsArbitraryLoadsForMedia"):
        if k in ats:
            ats.pop(k)
            changed = True
            logs.append(f"ATS: removed {k} (it would disable NSAllowsArbitraryLoads)")
    if ats.get("NSAllowsArbitraryLoads") is not True:
        ats["NSAllowsArbitraryLoads"] = True
        changed = True
        logs.append("ATS: NSAllowsArbitraryLoads = true")
    pl["NSAppTransportSecurity"] = ats
    if not pl.get("NSLocalNetworkUsageDescription"):
        pl["NSLocalNetworkUsageDescription"] = "Connect to the local Arcaea test server"
        changed = True
        logs.append("added NSLocalNetworkUsageDescription")
    if changed:
        with open(plist_path, "wb") as f:
            plistlib.dump(pl, f)
    else:
        logs.append("ATS: already exempt")
    return logs


def fat_arm64_slice_offset(raw: bytes) -> int:
    if raw[:4] != b"\xca\xfe\xba\xbe":
        return 0
    nfat = struct.unpack(">I", raw[4:8])[0]
    off = 8
    for _ in range(nfat):
        cputype, _, so, _, _ = struct.unpack(">IIIII", raw[off:off + 20])
        off += 20
        if cputype in (0x0100000c, 0x00000012):
            return so
    return 0


def slice_range(raw: bytes) -> tuple[int, int]:
    base = fat_arm64_slice_offset(raw)
    if base:
        nfat = struct.unpack(">I", raw[4:8])[0]
        off = 8
        for _ in range(nfat):
            cputype, _, so, sz, _ = struct.unpack(">IIIII", raw[off:off + 20])
            off += 20
            if cputype in (0x0100000c, 0x00000012):
                return so, so + sz
    return 0, len(raw)


def parse_load_commands(raw: bytes, base: int):
    ncmds, sizeofcmds = struct.unpack_from("<II", raw, base + 16)
    pos = base + 32
    cmds = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", raw, pos)
        cmds.append((cmd, cmdsize, pos))
        pos += cmdsize
    return ncmds, sizeofcmds, cmds


def has_load_dylib(raw: bytes, base: int, name: str) -> bool:
    _, _, cmds = parse_load_commands(raw, base)
    for cmd, cmdsize, pos in cmds:
        if (cmd & 0xFFFFFF) != 0x0C:
            continue
        path_off = struct.unpack_from("<I", raw, pos + 8)[0]
        path = raw[pos + path_off:pos + cmdsize].split(b"\0")[0].decode()
        if path == name:
            return True
    return False


def has_rpath(raw: bytes, base: int, path: str) -> bool:
    _, _, cmds = parse_load_commands(raw, base)
    for cmd, cmdsize, pos in cmds:
        if (cmd & 0xFFFFFF) != 0x1C:
            continue
        path_off = struct.unpack_from("<I", raw, pos + 8)[0]
        rp = raw[pos + path_off:pos + cmdsize].split(b"\0")[0].decode()
        if rp == path:
            return True
    return False


def build_load_dylib_cmd(path: str) -> bytes:
    path_b = path.encode("ascii") + b"\0"
    cmdsize = (24 + len(path_b) + 7) & ~7
    cmd = bytearray(cmdsize)
    struct.pack_into("<II", cmd, 0, LC_LOAD_DYLIB, cmdsize)
    struct.pack_into("<IIII", cmd, 8, 24, 2, 0x10000, 0x10000)
    cmd[24:24 + len(path_b)] = path_b
    return bytes(cmd)


def build_rpath_cmd(path: str) -> bytes:
    path_b = path.encode("ascii") + b"\0"
    cmdsize = (12 + len(path_b) + 7) & ~7
    cmd = bytearray(cmdsize)
    struct.pack_into("<II", cmd, 0, LC_RPATH, cmdsize)
    struct.pack_into("<I", cmd, 8, 12)
    cmd[12:12 + len(path_b)] = path_b
    return bytes(cmd)


def padding_after_lc(raw: bytes, base: int, sizeofcmds: int) -> int:
    end = base + 32 + sizeofcmds
    i = end
    sl_end = slice_range(raw)[1]
    limit = min(sl_end, len(raw))
    while i < limit and raw[i] == 0:
        i += 1
    return i - end


def insert_load_commands_inplace(data: bytearray, base: int) -> list[str]:
    logs = []
    ncmds, sizeofcmds, _ = parse_load_commands(data, base)

    to_add = []
    if not has_load_dylib(data, base, INJECT_NAME):
        to_add.append(build_load_dylib_cmd(INJECT_NAME))
    if not has_rpath(data, base, "@executable_path/Frameworks"):
        to_add.append(build_rpath_cmd("@executable_path/Frameworks"))

    if not to_add:
        logs.append("already has LC_LOAD_DYLIB + LC_RPATH")
        return logs

    need = sum(len(c) for c in to_add)
    pad = padding_after_lc(data, base, sizeofcmds)
    if need > pad:
        raise RuntimeError(
            f"load command padding too small: need {need} bytes, have {pad}"
        )

    insert_at = base + 32 + sizeofcmds
    for cmd in to_add:
        data[insert_at:insert_at + len(cmd)] = cmd
        insert_at += len(cmd)
        sizeofcmds += len(cmd)
        ncmds += 1

    struct.pack_into("<II", data, base + 16, ncmds, sizeofcmds)
    logs.append(f"inserted {len(to_add)} load command(s) (+{need} bytes in padding)")
    return logs


def find_dylibs() -> list[str]:
    candidates = [ROOT, os.path.join(ROOT, "ci-artifacts", "libxrcdemo-sideload")]
    found = []
    for name in DYLIB_NAMES:
        path = None
        for d in candidates:
            p = os.path.join(d, name)
            if os.path.isfile(p):
                path = p
                break
        if not path:
            raise FileNotFoundError(f"dylib missing: {name} (ROOT or ci-artifacts/)")
        found.append(path)
    return found


def check_binary(path: str) -> int:
    """--check：报告任意 Arc-mobile 的桩/注入状态（签名前后都可自查）。"""
    raw = bytearray(open(path, "rb").read())
    base = fat_arm64_slice_offset(raw)
    entry = bytes(raw[base + STUB_ENTRY_FILE:base + STUB_ENTRY_FILE + 12])
    tramp = struct.unpack_from("<10I", raw, base + STUB_TRAMP_FILE)
    has_dylib = has_load_dylib(raw, base, INJECT_NAME)
    has_stub = entry[:4] != STUB_ENTRY_EXPECT[:4]
    stub_v2 = tramp[4] == 0xAA0603E3
    slot = struct.unpack_from("<QQQ", raw, base + STUB_SLOT_FILE) if has_stub else None
    ok = True
    print(f"file       : {path}")
    print(f"entry      : {'PATCHED (ADRP/ADD/BR)' if has_stub else 'original (STP ...)'}")
    print(f"trampoline : {'v2 (MOV X3,X6 present)' if stub_v2 else 'v1 or absent'}")
    print(f"slot       : {slot if slot else '-'}")
    for name, site_va, replay_va, _expect in BRK_HOOKS:
        sf = base + (site_va - 0x100000000)
        rf = base + (replay_va - 0x100000000)
        insn = struct.unpack_from("<I", raw, sf)[0]
        tramp_b = raw[rf:rf + 8]
        print(f"brk[{name}]: site {insn:#010x} "
              f"{'PATCHED' if insn == 0xD4200000 else 'original'}; "
              f"replay {tramp_b.hex() if any(tramp_b) else 'empty'}")
    print(f"dylib LC   : {'@rpath/libxrcdemo.dylib present' if has_dylib else 'MISSING'}")
    if has_stub and not has_dylib:
        print("=> INVALID: stub without dylib (features would be dead)")
        ok = False
    if has_stub and not stub_v2:
        print("=> STALE: v1 trampoline — new handler needs v2 (MOV X3,X6); regenerate stub")
        ok = False
    if has_stub and stub_v2 and has_dylib:
        print("=> OK: stub v2 + dylib — judge feature should report live on device")
    if not has_stub:
        print("=> NOT PATCHED: this main carries no stub (judge feature unavailable)")
    return 0 if ok else 2


def main():
    # 独立入口：只给指定 app bundle 打 ATS 豁免（用于已经注入过二进制、只需补 plist 的场合）
    #   python inject.py --ats <Arc-mobile.app 路径>
    if "--ats" in sys.argv:
        i = sys.argv.index("--ats")
        if i + 1 >= len(sys.argv):
            print("usage: inject.py --ats <path/to/Arc-mobile.app>")
            sys.exit(1)
        global APP
        APP = sys.argv[i + 1]
        if not os.path.isdir(APP):
            print(f"[!] not a directory: {APP}")
            sys.exit(1)
        try:
            for line in patch_ats():
                print(f"[+] {line}")
        except Exception as e:
            print(f"[!] {e}")
            sys.exit(1)
        print("[i] re-sign the app before installing")
        sys.exit(0)

    if "--check" in sys.argv:
        i = sys.argv.index("--check")
        if i + 1 >= len(sys.argv):
            print("usage: inject.py --check <Arc-mobile path>")
            sys.exit(1)
        sys.exit(check_binary(sys.argv[i + 1]))
    do_stub = "--stub" in sys.argv
    do_brk = "--brk" in sys.argv
    if not os.path.isfile(MAIN):
        print(f"[!] main not found: {MAIN}")
        sys.exit(1)

    try:
        dylibs = find_dylibs()
    except FileNotFoundError as e:
        print(f"[!] {e}")
        sys.exit(1)

    os.makedirs(FW_DIR, exist_ok=True)
    for d in dylibs:
        dst = os.path.join(FW_DIR, os.path.basename(d))
        shutil.copy2(d, dst)
        print(f"[+] copied -> {dst}")

    # ATS 豁免：私服走明文 HTTP，必须放开（否则请求被静默拦截）
    try:
        for line in patch_ats():
            print(f"[+] {line}")
    except Exception as e:
        print(f"[!] ATS patch failed: {e}")
        sys.exit(1)

    with open(MAIN, "rb") as f:
        data = bytearray(f.read())

    base = fat_arm64_slice_offset(data)
    try:
        logs = insert_load_commands_inplace(data, base)
        for line in logs:
            print(f"[+] {line}")
    except RuntimeError as e:
        print(f"[!] {e}")
        sys.exit(1)

    if do_stub:
        try:
            logs = patch_judge_stub(data)
            for line in logs:
                print(f"[+] {line}")
        except RuntimeError as e:
            print(f"[!] stub: {e}")
            sys.exit(1)
        print("[i] stub patched — re-sign the app before installing")

    if do_brk:
        try:
            logs = patch_brk_hooks(data)
            for line in logs:
                print(f"[+] {line}")
        except RuntimeError as e:
            print(f"[!] brk: {e}")
            sys.exit(1)
        print("[i] brk hook patched — re-sign the app before installing")

    with open(MAIN, "wb") as f:
        f.write(data)

    size = os.path.getsize(MAIN)
    with open(MAIN, "rb") as f:
        raw = f.read()
    _, sl_end = slice_range(raw)
    print(f"[+] wrote {MAIN}")
    print(f"[i] size={size} (slice_end={sl_end})")
    if size < sl_end - 1000:
        print("[!] WARNING: file smaller than slice - possible corruption")
        sys.exit(1)

    # 组合守卫（2026-09-10 教训）：打桩的二进制必须同时载入 dylib，否则
    # 跳板会把判定核转发给 slot（handler=0 → 直通）——游戏能玩但功能全无；
    # 反向（载入 dylib 但没打桩）则由 dylib 侧降级（judge 区禁用）。
    with open(MAIN, "rb") as f:
        final = bytearray(f.read())
    fbase = fat_arm64_slice_offset(final)
    has_dylib = has_load_dylib(final, fbase, INJECT_NAME)
    # 打桩判据 = 入口首 4 字节已不是原始 STP（被 12 字节 ADRP/ADD/BR 覆盖）
    has_stub = bytes(final[fbase + STUB_ENTRY_FILE:fbase + STUB_ENTRY_FILE + 4]) != STUB_ENTRY_EXPECT[:4]
    print(f"[i] combination check: dylib={has_dylib} stub={has_stub}")
    if has_stub and not has_dylib:
        print("[!] INVALID COMBINATION: stub patched but LC_LOAD_DYLIB missing —")
        print("    the judge trampoline would dispatch to a NULL handler (features dead).")
        print("    Re-run without --stub for a clean injection, or keep both.")
        sys.exit(2)


if __name__ == "__main__":
    main()
