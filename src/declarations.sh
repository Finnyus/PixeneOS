#!/usr/bin/env bash

source src/logger.sh

# Declare associative arrays and variables
declare -A ADDITIONALS
declare -A APATCH
declare -A GRAPHENEOS
declare -A KEYS
declare -A MAGISK
declare -A OUTPUTS
declare -A VERSION

# Build Specifications
# `x86_64-unknown-linux-gnu` for Linux, `universal-apple-darwin` for macOS,
# `x86_64-pc-windows-msvc` for Windows. Override in env.toml.
ARCH="${ARCH:-x86_64-unknown-linux-gnu}"

# Initial setup environment variables
CLEANUP="${CLEANUP:-false}"                  # Clean up after the script finishes
DEVICE_NAME="${DEVICE_NAME:-}"               # Device name, passed from the CI environment
FORCE_UPDATE="${FORCE_UPDATE:-false}"        # Rebuild the current release when a module gets an update
INTERACTIVE_MODE="${INTERACTIVE_MODE:-true}" # Enable interactive mode
WORKDIR=".tmp"

# GitHub variables. Override GITHUB_USER and GITHUB_REPO in env.toml for forks.
DOMAIN="https://github.com"
GITHUB_REPO="${GITHUB_REPO:-PixeneOS}"    # GitHub repository name
GITHUB_USER="${GITHUB_USER:-Finnyus}" # GitHub username

# Application version variables
VERSION[AFSR]="${VERSION[AFSR]:-2.0.0}"
VERSION[ALTERINSTALLER]="${VERSION[ALTERINSTALLER]:-2.4}"
VERSION[APATCH]="${VERSION[APATCH]:-}"
VERSION[AVBROOT]="${VERSION[AVBROOT]:-3.34.1}"
VERSION[AVBROOT_SETUP]="9161b3e13416790d7e6da21d9dac5a14bc724504" # Commit hash
VERSION[BCR]="${VERSION[BCR]:-3.9}"
VERSION[CUSTOTA]="${VERSION[CUSTOTA]:-6.6}"
VERSION[GRAPHENEOS]="${VERSION[GRAPHENEOS]:-}"
VERSION[KERNELPATCH]="${VERSION[KERNELPATCH]:-0.13.9}"
VERSION[MAGISK]="${VERSION[MAGISK]:-}"
VERSION[MSD]="${VERSION[MSD]:-2.5}"
VERSION[OEMUNLOCKONBOOT]="${VERSION[OEMUNLOCKONBOOT]:-1.4}"

# APatch / KernelPatch
APATCH[REPOSITORY]="${APATCH_REPOSITORY:-bmax121/APatch}"
# Optional SuperKey; when empty, APatch 11219+ uses signature-authorized manager mode
APATCH[SUPERKEY]="${APATCH_SUPERKEY:-}"
# Fork of bmax121/KernelPatch carrying GrapheneOS MTE & ramdisk/DTB reservation fixes
APATCH[KERNELPATCH_REPO]="${APATCH_KERNELPATCH_REPO:-david568303/KernelPatch}"
APATCH[KERNELPATCH_COMMIT]="${APATCH_KERNELPATCH_COMMIT:-280d32d967feb7ddc0fd1848aa1d1388807945d5}"
APATCH[TOOLCHAIN_URL]="${APATCH_TOOLCHAIN_URL:-https://armkeil.blob.core.windows.net/developer/Files/downloads/gnu/12.2.rel1/binrel/arm-gnu-toolchain-12.2.rel1-x86_64-aarch64-none-elf.tar.xz}"
APATCH[TOOLCHAIN_SHA256]="${APATCH_TOOLCHAIN_SHA256:-62d66e0ad7bd7f2a183d236ee301a5c73c737c886c7944aa4f39415aab528daf}"

# Magisk
MAGISK[PREINIT]="${MAGISK_PREINIT:-}"
# The default fork carries Zygisk fixes for GrapheneOS.
# Set to `topjohnwu/Magisk` for upstream Magisk.
MAGISK[REPOSITORY]="${MAGISK_REPOSITORY:-pixincreate/Magisk}"

# Keys
KEYS[AVB]="${KEYS[AVB]:-avb.key}"
KEYS[AVB_BASE64]="${KEYS[AVB_BASE64]:-''}"
KEYS[CERT_OTA]="${KEYS[CERT_OTA]:-ota.crt}"
KEYS[CERT_OTA_BASE64]="${KEYS[CERT_OTA_BASE64]:-''}"
KEYS[OTA]="${KEYS[OTA]:-ota.key}"
KEYS[OTA_BASE64]="${KEYS[OTA_BASE64]:-''}"
KEYS[PKMD]="${KEYS[PKMD]:-avb_pkmd.bin}"

# GrapheneOS
GRAPHENEOS[OTA_BASE_URL]="https://releases.grapheneos.org"
GRAPHENEOS[UPDATE_CHANNEL]="${GRAPHENEOS_UPDATE_CHANNEL:-stable}"
GRAPHENEOS[UPDATE_TYPE]="${GRAPHENEOS[UPDATE_TYPE]:-ota_update}" # avbroot supports only `ota_update` and not `install` (factory images)
GRAPHENEOS[OTA_URL]="${GRAPHENEOS[OTA_URL]:-}"                   # Will be constructed from the latest version
GRAPHENEOS[OTA_TARGET]="${GRAPHENEOS[OTA_TARGET]:-}"             # Will be constructed from the latest version

# Additionals

# Modules
ADDITIONALS[AFSR]="${ADDITIONALS[AFSR]:-true}"                       # Android File system repack
ADDITIONALS[ALTERINSTALLER]="${ADDITIONALS[ALTERINSTALLER]:-true}"   # Spoof Android package manager installer fields
ADDITIONALS[BCR]="${ADDITIONALS[BCR]:-true}"                         # Basic Call Recorder
ADDITIONALS[CUSTOTA]="${ADDITIONALS[CUSTOTA]:-true}"                 # Custom OTA Updater app
ADDITIONALS[MSD]="${ADDITIONALS[MSD]:-true}"                         # Mass Storage Device on USB
ADDITIONALS[OEMUNLOCKONBOOT]="${ADDITIONALS[OEMUNLOCKONBOOT]:-true}" # toggle OEM unlock button on boot
# Tools
ADDITIONALS[AVBROOT]="${ADDITIONALS[AVBROOT]:-true}"                   # Android Verified Boot Root
ADDITIONALS[CUSTOTA_TOOL]="${ADDITIONALS[CUSTOTA_TOOL]:-true}"         # Custom OTA Tool
ADDITIONALS[MY_AVBROOT_SETUP]="${ADDITIONALS[MY_AVBROOT_SETUP]:-true}" # My AVBRoot setup

ADDITIONALS[ROOT]="${ADDITIONALS_ROOT:-apatch}"  # Supported values: `apatch`, `magisk`, `rootless`
ADDITIONALS[RETRY]="${ADDITIONALS[RETRY]:-true}" # Auto download signatures

# Outputs
OUTPUTS[PATCHED_OTA]="${OUTPUTS[PATCHED_OTA]:-}"
