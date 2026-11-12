#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify-firmware.py —— OpenWrt / LibWrt 固件镜像完整性校验（纯标准库，无依赖）

用途：
  在刷机前检查一份 .bin 镜像是否被改坏。同时校验两件事：
    1) fwtool 元数据 trailer 的 CRC（能精确发现 payload 任意位置的改动）
    2) 可选的期望 sha256（与 release 里 sha256sums 对比）

原理（已在 OpenWrt 镜像上实测标定）：
    [payload ...][8×0x00][metadata JSON]["FWx0"][crc BE][version LE][len BE]
    len = 8 + len(JSON) + 16
    crc = (~zlib.crc32(file[0:trailer_offset])) & 0xFFFFFFFF
          # 标准 CRC-32（poly 0xEDB88320, init 0xFFFFFFFF），省略最后的取反

用法：
    python3 verify-firmware.py <镜像.bin> [更多镜像.bin ...] [--expect <sha256>]
    python3 verify-firmware.py fw.bin --expect 44faf9f3....
    python3 verify-firmware.py fw.bin --json      # 机器可读输出

Windows 提示：
    脚本会把 stdout 切到 UTF-8，避免 GBK 控制台因 ✅/❌ 直接崩溃。
    如果仍然乱码，用 `python -X utf8 verify-firmware.py <镜像>`。

退出码：
    0 = 全部通过
    1 = 有文件校验失败
    2 = 用法错误 / 文件不可读
"""

import sys
import os
import json
import zlib
import struct
import hashlib

MAGIC = b"FWx0"
TRAILER_SIZE = 16          # magic(4) + crc(4) + version(4) + len(4)


def raw_crc32(data: bytes) -> int:
    """fwtool 使用的 CRC：标准 CRC-32 但省略最终取反。"""
    return (~zlib.crc32(data)) & 0xFFFFFFFF


def find_trailer(data: bytes):
    """返回 (trailer_offset, crc, version, length) 或 None。"""
    off = data.rfind(MAGIC)
    if off < 0 or off + TRAILER_SIZE > len(data):
        return None
    crc, version_raw, length = struct.unpack(">III", data[off + 4:off + 16])
    version = struct.unpack("<I", data[off + 8:off + 12])[0]
    return off, crc, version, length


def extract_metadata(data: bytes, off: int, length: int):
    """从 trailer 前取出 JSON 文本（去掉 8 字节对齐填充）。"""
    start = off - length
    if start < 0:
        return None
    block = data[start:off]
    i = block.find(b"{")
    if i < 0:
        return None
    return block[i:]


def check_file(path: str, expect_sha256: str = None, as_json: bool = False) -> bool:
    result = {"file": path, "ok": False}
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        result["error"] = f"无法读取：{e}"
        print(json.dumps(result, ensure_ascii=False) if as_json
              else f"[x] {path}: 无法读取（{e}）")
        return False

    sha256 = hashlib.sha256(data).hexdigest()
    result.update({"size": size, "sha256": sha256})

    trailer = find_trailer(data)
    if not trailer:
        result["error"] = "找不到 FWx0 trailer（这不一定是错误：factory.bin 之外的某些镜像可能没有元数据）"
        ok = True
        if expect_sha256:
            ok = (sha256 == expect_sha256.strip().lower())
            result["sha256_match"] = ok
            result["error"] = None if ok else "sha256 与期望值不一致"
        result["ok"] = ok
        if not as_json:
            print(f"{'[OK]' if ok else '[FAIL]'} {os.path.basename(path)}")
            print(f"   大小   : {size:,} 字节")
            print(f"   sha256 : {sha256}")
            if expect_sha256:
                print(f"   期望   : {expect_sha256.strip().lower()}"
                      f"{'  [OK]' if ok else '  [FAIL]'}")
            print(f"   元数据 : 无 trailer（{result['error'] or '跳过 CRC 校验'}）")
        else:
            print(json.dumps(result, ensure_ascii=False))
        return ok

    off, stored_crc, version, length = trailer
    calc_crc = raw_crc32(data[:off])
    crc_ok = (stored_crc == calc_crc)

    meta = extract_metadata(data, off, length)
    meta_text = meta.decode("utf-8", "replace") if meta else None
    meta_obj = None
    if meta_text:
        try:
            meta_obj = json.loads(meta_text)
        except Exception:
            pass

    sha_ok = True
    if expect_sha256:
        sha_ok = (sha256 == expect_sha256.strip().lower())

    ok = crc_ok and sha_ok
    result.update({
        "ok": ok,
        "trailer_offset": off,
        "trailer_version": version,
        "trailer_len": length,
        "crc_stored": f"0x{stored_crc:08x}",
        "crc_calc": f"0x{calc_crc:08x}",
        "crc_ok": crc_ok,
        "metadata": meta_obj if meta_obj else meta_text,
    })
    if expect_sha256:
        result["sha256_match"] = sha_ok

    if as_json:
        print(json.dumps(result, ensure_ascii=False))
        return ok

    print(f"{'[OK]' if ok else '[FAIL]'} {os.path.basename(path)}")
    print(f"   大小     : {size:,} 字节")
    print(f"   sha256   : {sha256}")
    if expect_sha256:
        print(f"   期望值   : {expect_sha256.strip().lower()}  "
              f"{'[OK] 一致' if sha_ok else '[FAIL] 不一致'}")
    print(f"   trailer  : offset={off}  version={version}  len={length}")
    if meta_obj:
        v = meta_obj.get("version", {})
        print(f"   元数据   : {meta_obj.get('metadata_version')} / "
              f"compat={meta_obj.get('compat_version')} / "
              f"{v.get('dist')} {v.get('version')} {v.get('revision')} / "
              f"{v.get('target')} / board={v.get('board')}")
        print(f"   适配设备 : {meta_obj.get('supported_devices')}")
    print(f"   CRC      : 存储 0x{stored_crc:08x} / 复算 0x{calc_crc:08x}  "
          f"{'[OK] 匹配' if crc_ok else '[FAIL] 不匹配（文件已损坏）'}")
    if not ok:
        print("   [!] 不要刷这个文件。请重新下载并再次校验。")
    return ok


def main(argv):
    # Windows 控制台默认 GBK，直接 print 非 ASCII 字符会 UnicodeEncodeError
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    if len(argv) < 2:
        print(__doc__)
        return 2
    args = [a for a in argv[1:] if not a.startswith("--")]
    as_json = "--json" in argv
    expect = None
    if "--expect" in argv:
        i = argv.index("--expect")
        if i + 1 >= len(argv):
            print("--expect 需要一个 sha256 值", file=sys.stderr)
            return 2
        expect = argv[i + 1]
        args = [a for a in args if a != expect]
    if not args:
        print("没有给出文件", file=sys.stderr)
        return 2

    all_ok = True
    for p in args:
        if not as_json:
            print("-" * 60)
        all_ok &= check_file(p, expect, as_json)
    if not as_json:
        print("-" * 60)
        print("总计：", "全部通过 [OK]" if all_ok else "存在失败项 [FAIL]")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
