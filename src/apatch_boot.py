#!/usr/bin/env python3
"""
Minimal Android boot image kernel extractor/replacer for APatch patching.
Supports boot image header v0, v1, v2, v3, v4.

On Android 13+ GKI devices:
  - boot.img     = kernel (this is what APatch/kptools patches)
  - init_boot.img = generic ramdisk only (no kernel — do NOT patch this)

Usage:
  python3 apatch_boot.py extract <boot.img> <kernel.bin>
  python3 apatch_boot.py repack  <boot.img> <patched_kernel.bin> <output.img>
"""
import struct
import sys
from pathlib import Path

BOOT_MAGIC = b"ANDROID!"


def parse_header(data: bytes) -> dict:
    if data[:8] != BOOT_MAGIC:
        raise ValueError(
            f"Not an Android boot image — unexpected magic bytes: {data[:8]!r}\n"
            f"Expected: b'ANDROID!'"
        )

    kernel_size = struct.unpack_from("<I", data, 8)[0]

    # Detect header version.
    # v0/v1/v2: page_size at offset 36, header_version at offset 40
    # v3/v4:    page_size is always 4096 (not stored), header_version at offset 40
    header_version = struct.unpack_from("<I", data, 40)[0]

    if header_version in (0, 1, 2):
        page_size = struct.unpack_from("<I", data, 36)[0]
    else:
        # v3, v4 — page size is hard-coded to 4096
        page_size = 4096

    return {
        "version": header_version,
        "page_size": page_size,
        "kernel_size": kernel_size,
    }


def round_to_page(n: int, page_size: int) -> int:
    """Round n up to the next multiple of page_size."""
    if n == 0:
        return 0
    return ((n + page_size - 1) // page_size) * page_size


def extract_kernel(boot_img_path: str, kernel_out_path: str) -> None:
    data = Path(boot_img_path).read_bytes()
    hdr = parse_header(data)

    page_size = hdr["page_size"]
    kernel_size = hdr["kernel_size"]

    if kernel_size == 0:
        raise ValueError(
            f"boot image reports kernel_size=0 — this image contains NO kernel.\n"
            f"This is likely init_boot.img (generic ramdisk only).\n"
            f"APatch must patch boot.img, not init_boot.img."
        )

    # The kernel always starts one page after the header page.
    kernel_offset = page_size
    kernel_data = data[kernel_offset : kernel_offset + kernel_size]

    if len(kernel_data) != kernel_size:
        raise ValueError(
            f"Truncated image: expected {kernel_size} kernel bytes, "
            f"got {len(kernel_data)}"
        )

    Path(kernel_out_path).write_bytes(kernel_data)
    print(
        f"Extracted {kernel_size:,} byte kernel "
        f"(header v{hdr['version']}) from {boot_img_path} → {kernel_out_path}"
    )


def repack_boot(
    orig_img_path: str, patched_kernel_path: str, out_img_path: str
) -> None:
    orig_data = Path(orig_img_path).read_bytes()
    hdr = parse_header(orig_data)
    new_kernel = Path(patched_kernel_path).read_bytes()

    page_size = hdr["page_size"]
    orig_kernel_size = hdr["kernel_size"]
    new_kernel_size = len(new_kernel)

    orig_kernel_pages = round_to_page(orig_kernel_size, page_size)
    new_kernel_pages = round_to_page(new_kernel_size, page_size)

    # Clone the original header page and update kernel_size.
    new_header = bytearray(orig_data[:page_size])
    struct.pack_into("<I", new_header, 8, new_kernel_size)

    # Everything after the original kernel block is untouched (ramdisk, sig, etc.)
    rest_offset = page_size + orig_kernel_pages
    rest = orig_data[rest_offset:]

    # Pad new kernel to page boundary (zero-fill).
    padded_new_kernel = new_kernel + b"\x00" * (new_kernel_pages - new_kernel_size)

    output = bytes(new_header) + padded_new_kernel + rest
    Path(out_img_path).write_bytes(output)
    print(
        f"Repacked {orig_img_path}: kernel {orig_kernel_size:,} → {new_kernel_size:,} bytes "
        f"→ {out_img_path}"
    )


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__)
        return 1

    cmd = sys.argv[1]
    try:
        if cmd == "extract":
            extract_kernel(sys.argv[2], sys.argv[3])
        elif cmd == "repack":
            if len(sys.argv) < 5:
                print(__doc__)
                return 1
            repack_boot(sys.argv[2], sys.argv[3], sys.argv[4])
        else:
            print(f"Error: unknown command {cmd!r}", file=sys.stderr)
            return 1
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
