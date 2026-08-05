#!/usr/bin/env bash

# This script contains the logic to fetch and patch KernelSU into the boot image.
# It is sourced by util_functions.sh when FLAVOR="kernelsu".

# Function to download ksud and the required kernel module
function download_kernelsu_tools() {
  local ksudBin="${WORKDIR}/tools/ksud"
  local ksuVer="${VERSION[KSUD]#v}"
  local ksuOriginalVer="${VERSION[KERNELSU]#v}"
  
  if [ "${ksuVer}" == "latest" ]; then
    ksuVer=$(curl -sL -I -o /dev/null -w '%{url_effective}' "https://github.com/tiann/KernelSU/releases/latest" 2>/dev/null | sed 's/.*\/tag\/v\?//;')
    VERSION[KSUD]="${ksuVer}"
  fi
  
  if [ "${ksuOriginalVer}" == "latest" ]; then
    ksuOriginalVer=$(curl -sL -I -o /dev/null -w '%{url_effective}' "https://github.com/tiann/KernelSU/releases/latest" 2>/dev/null | sed 's/.*\/tag\/v\?//;')
    VERSION[KERNELSU]="${ksuOriginalVer}"
  fi

  if [ ! -f "${ksudBin}" ]; then
    echo "Downloading ksud..."
    local ksudUrl="https://github.com/tiann/KernelSU/releases/download/v${ksuVer}/ksud-x86_64-unknown-linux-musl"
    
    local http_code=$(curl -sL -I -o /dev/null -w "%{http_code}" "${ksudUrl}")
    if [ "${http_code}" != "200" ] && [ "${http_code}" != "302" ]; then
      echo "KSU v${ksuVer} does not have Linux ksud binary. Falling back to v3.2.1..."
      ksuVer="3.2.1"
      ksudUrl="https://github.com/tiann/KernelSU/releases/download/v${ksuVer}/ksud-x86_64-unknown-linux-musl"
    fi

    curl --fail -sLo "${ksudBin}" "${ksudUrl}"
    chmod +x "${ksudBin}"
    echo "ksud downloaded successfully."
  fi
}

function extract_magiskboot() {
  local magiskbootBin="${WORKDIR}/tools/magiskboot"
  local magiskApk="${WORKDIR}/modules/magisk.apk"

  if [ -f "${magiskbootBin}" ]; then
    return
  fi

  echo "Extracting magiskboot from Magisk APK..."
  if [ ! -f "${magiskApk}" ]; then
    echo "Magisk APK not found! Please ensure it is downloaded."
    exit 1
  fi

  python3 -c "
import zipfile, os, stat
with zipfile.ZipFile('${magiskApk}') as z:
    z.extract('lib/x86_64/libmagiskboot.so', '.')
os.rename('lib/x86_64/libmagiskboot.so', '${magiskbootBin}')
os.chmod('${magiskbootBin}', stat.S_IRWXU)
import shutil; shutil.rmtree('lib', ignore_errors=True)
"
  echo "magiskboot extraction complete."
}

function detect_device_params() {
  local bootImg="${1}"
  local kernelVer=""
  
  local detectWorkDir="${WORKDIR}/extracted/device_detect"
  rm -rf "${detectWorkDir}"
  mkdir -p "${detectWorkDir}"
  
  local absBootImg="${bootImg}"
  if [[ "${bootImg}" != /* ]]; then
    absBootImg="$(pwd)/${bootImg}"
  fi
  
  (cd "${detectWorkDir}" && "$(pwd)/${WORKDIR}/tools/magiskboot" unpack "${absBootImg}" >/dev/null 2>&1) || true

  local kernelFile=""
  for f in kernel kernel_dtb kernel.gz Image Image.gz Image.lz4; do
    if [ -f "${detectWorkDir}/${f}" ]; then
      kernelFile="${detectWorkDir}/${f}"
      break
    fi
  done

  if [ -n "${kernelFile}" ]; then
    kernelVer=$(strings "${kernelFile}" | grep -m1 'Linux version [0-9]\+\.[0-9]\+')
  fi
  rm -rf "${detectWorkDir}"

  if [ -n "${kernelVer}" ]; then
    echo "Kernel version string: ${kernelVer}"
    local major=$(echo "${kernelVer}" | sed 's/.*Linux version //' | cut -d'.' -f1)
    local minor=$(echo "${kernelVer}" | sed 's/.*Linux version //' | cut -d'.' -f2)

    case "${major}.${minor}" in
      "5.10") DETECTED_KMI="android12-5.10";;
      "5.15") DETECTED_KMI="android13-5.15";;
      "6.1")  DETECTED_KMI="android14-6.1";;
      "6.6")  DETECTED_KMI="android15-6.6";;
      "6.12") DETECTED_KMI="android16-6.12";;
      *)
        echo "Unknown kernel version ${major}.${minor}. Will use fallback device detection." >&2
        DETECTED_KMI=""
        return 1;;
    esac
    return 0
  fi

  echo "Cannot detect KMI from boot.img, using device known defaults..." >&2
  case "${DEVICE_NAME}" in
    oriole|raven|bluejay|panther|cheetah|lynx|felix|tangorpro)
      DETECTED_KMI="android13-5.15"
      ;;
    shiba|husky|akita)
      DETECTED_KMI="android14-6.1"
      ;;
    tokay|caiman|komodo|comet)
      DETECTED_KMI="android15-6.6"
      ;;
    *)
      DETECTED_KMI="android14-6.1"
      ;;
  esac
}

function inject_kernelsu_into_boot() {
  local ota_zip="${WORKDIR}/${GRAPHENEOS[OTA_TARGET]}.zip"
  local ksuWorkDir="${WORKDIR}/extracted/ksu_work"
  local ksuOutDir="${ksuWorkDir}/patched"
  
  mkdir -p "${ksuWorkDir}/extracted"
  
  echo "Extracting boot.img from OTA..."
  avbroot ota extract \
    --input "${ota_zip}" \
    --directory "${ksuWorkDir}/extracted" \
    --boot-only

  local bootImgPath="${ksuWorkDir}/extracted/boot.img"
  if [ ! -f "${bootImgPath}" ]; then
    echo "boot.img could not be extracted!"
    exit 1
  fi
  
  detect_device_params "${bootImgPath}"
  local kmi="${DETECTED_KMI}"
  echo "Detected KMI: ${kmi}"

  # Download the specific .ko module for this KMI
  local koTarget="${WORKDIR}/modules/ksu_module.ko"
  local ksuOriginalVer="${VERSION[KERNELSU]#v}"
  echo "Downloading KernelSU module for KMI: ${kmi}..."
  curl -sLo "${koTarget}" "https://github.com/tiann/KernelSU/releases/download/v${ksuOriginalVer}/${kmi}_kernelsu.ko" || {
    echo "Warning: Failed to download .ko module, ksud might fail or use internal one."
    rm -f "${koTarget}"
  }

  mkdir -p "${ksuOutDir}"
  
  local ksudArgs=()
  ksudArgs+=("-b" "${bootImgPath}")
  ksudArgs+=("--kmi" "${kmi}")
  ksudArgs+=("--magiskboot" "${WORKDIR}/tools/magiskboot")
  ksudArgs+=("-o" "${ksuOutDir}")
  ksudArgs+=("--out-name" "ksu_patched_boot.img")

  if [ -f "${koTarget}" ]; then
    ksudArgs+=("--module" "${koTarget}")
  fi

  ksudArgs+=("--allow-shell")

  echo "Running ksud to patch boot.img..."
  "${WORKDIR}/tools/ksud" boot-patch "${ksudArgs[@]}"
  
  local patchedBoot=$(find "${ksuOutDir}" -maxdepth 1 -type f -name "ksu_patched_boot.img" 2>/dev/null | head -1)
  if [ -z "${patchedBoot}" ]; then
    echo "Failed to find patched boot image!"
    exit 1
  fi

  echo "KernelSU patched boot image successfully created at ${patchedBoot}"
  export KSU_PATCHED_BOOT="${patchedBoot}"
}
