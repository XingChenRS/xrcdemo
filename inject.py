"""
Inject libArcDemo.dylib + libellekit.dylib into Arc-mobile.app.

Two independent stages:

1. dylib injection (default): copy dylibs, insert LC_LOAD_DYLIB / LC_RPATH
   into the existing load-command padding.
2. judge stub (--stub): patch sub_1009D9ED8 entry -> trampoline in __TEXT tail
   zero-padding -> slot in __DATA tail zero-padding. No Mach-O header surgery;
   both regions lie inside the existing segment filesizes. Re-sign afterwards
   (the user signs the result).

Stub facts (Arcaea iOS 7.0.255, research/notes/ios-7.0.255-judgement-chain.md):
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
DYLIB_NAMES = ["libArcDemo.dylib", "libellekit.dylib"]
INJECT_NAME = "@rpath/libArcDemo.dylib"

LC_LOAD_DYLIB = 0x8000000C
LC_RPATH = 0x8000001C

# ---- judge stub constants (7.0.255, corrected 2026-09-10) ----
# 判定核心 = sub_10091E684（整数 CMP 级联，与 6.13 sub_100870FD0 逐行同构）。
# 此前误用 sub_1009D9ED8（特效显示链）——见
# research/notes/ios-7.0.255-judgement-correction-2026-09-10.md
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
    candidates = [ROOT, os.path.join(ROOT, "ci-artifacts", "libArcDemo-sideload")]
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


def main():
    do_stub = "--stub" in sys.argv
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


if __name__ == "__main__":
    main()
