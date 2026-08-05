#!/usr/bin/env bash

# This script is a part of the main script and is responsible for the utility functions used in the main script.

source src/declarations.sh
source src/exchange.sh
source src/fetcher.sh
source src/kernelsu.sh
source src/verifier.sh

# Function to check and download the dependencies
# This function checks for the required tools and downloads them if not found depending on the configuration done in the declarations file
function check_and_download_dependencies() {
  make_directories

  # Check for Python requirements
  if ! command -v python3 &>/dev/null; then
    echo -e "Python 3 is required to run this script.\nExiting..."
    exit 1
  fi

  # Check if retry config is enabled
  if [[ "${ADDITIONALS[RETRY]}" == "true" ]]; then
    RETRY="true"
  else
    RETRY="false"
  fi

  # Check for required tools
  # If they're present, continue with the script
  # Else, download them by checking version from declarations
  tools=$(supported_tools "cdd") # Call the function and capture its output

  # Convert the space-separated string back into an array
  IFS=' ' read -r -a tools_array <<<"${tools}"

  for tool in "${tools_array[@]}"; do
    local flag=$(flag_check "${tool}")

    if [[ "${flag}" == 'false' ]]; then
      echo -e "\`${tool}\` is **NOT** enabled in the configuration.\nSkipping...\n"
      continue
    fi

    if [ -f "${WORKDIR}/modules/${tool}.zip" ]; then
      echo -e "\`${tool}.zip\` file already exists in \`${WORKDIR}/modules\`."
      continue
    fi

    if [ -d "${WORKDIR}/tools/${tool}" ]; then
      echo -e "\`${tool}\` file already exists in \`${WORKDIR}/tools\`."
      continue
    fi

    RETRY_COUNT=0 # Reset retry count for each tool
    while true; do
      # Download the tool and verify the download
      download_dependencies "${tool}"
      verify_downloads "${tool}"
      [[ "${ADDITIONALS[RETRY]}" == "true" ]] && [[ "${RETRY}" == "true" ]] || break
    done
  done

  # Retry logic for magisk
  if [[ "${FLAVOR}" == 'magisk' ]] || [[ "${FLAVOR}" == 'magisk-pixincreate' ]] || [[ "${FLAVOR}" == 'magisk-nomodules' ]] || [[ "${FLAVOR}" == 'kernelsu' ]] || [[ "${FLAVOR}" == 'kernelsunext' ]] || [[ "${FLAVOR}" == 'adbroot' ]]; then
    RETRY_COUNT=0 # Reset retry count for magisk
    while true; do
      # Magisk is an exception as it is an APK and hence we do the get call directly and verify
      URL="${MAGISK[URL]}/releases/download/${VERSION[MAGISK]}/app-debug.apk"
      echo "URL for \`magisk\`: ${URL}"
      get "magisk" "${URL}"
      verify_downloads "magisk"

      [[ "${ADDITIONALS[RETRY]}" == "true" ]] && [[ "${RETRY}" == "true" ]] || break
    done
  fi

  if [[ "${FLAVOR}" == 'kernelsu' ]] || [[ "${FLAVOR}" == 'kernelsunext' ]]; then
    download_kernelsu_tools
  elif [[ "${FLAVOR}" == 'apatch' ]]; then
    local kp_version="${VERSION[KERNELPATCH]}"
    local kp_base_url="${APATCH[URL]}/releases/download/${kp_version}"
    mkdir -p "${WORKDIR}/tools/apatch"
    for kp_asset in "kptools-linux" "kpimg-android"; do
      if [[ -f "${WORKDIR}/tools/apatch/${kp_asset}" ]]; then
        echo -e "\`${kp_asset}\` already exists in \`${WORKDIR}/tools/apatch/\`."
        continue
      fi
      echo "Downloading ${kp_asset} for APatch..."
      curl --fail -sLo "${WORKDIR}/tools/apatch/${kp_asset}" "${kp_base_url}/${kp_asset}"
      chmod +x "${WORKDIR}/tools/apatch/${kp_asset}"
      if [[ -f "${WORKDIR}/tools/apatch/${kp_asset}" && -s "${WORKDIR}/tools/apatch/${kp_asset}" ]]; then
        echo -e "\`${kp_asset}\` verified.\n"
      else
        echo -e "Error: \`${kp_asset}\` download failed or is empty."
        exit 1
      fi
    done
  fi
}

# Function to check the flag status
# If flag for a tool is disabled, it is not downloaded
function flag_check() {
  local tool="${1}"
  local tool_upper_case=$(echo "${tool}" | tr '[:lower:]' '[:upper:]')

  if [[ "${tool}" == "my-avbroot-setup" ]]; then
    FLAG="${ADDITIONALS[MY_AVBROOT_SETUP]}"
  elif [[ "${tool}" == "custota-tool" ]]; then
    FLAG="${ADDITIONALS[CUSTOTA_TOOL]}"
  else
    FLAG="${ADDITIONALS[$tool_upper_case]}"
  fi

  if [[ "${FLAG}" == 'true' ]]; then
    echo 'true'
  else
    echo 'false'
  fi
}

# Function to create and make the release called by main script
function create_and_make_release() {
  if [[ ! -d $WORKDIR ]]; then
    echo -e "Error: $WORKDIR is non-existent. Downloading the tools..."

    # Check for requirements and download them accordingly
    check_and_download_dependencies
  fi

  # Calls the download_ota function to download the OTA if not found
  download_ota
  # Calls the create_ota function to create the OTA
  create_ota
}

function create_ota() {
  [[ "${CLEANUP}" != 'true' ]] && trap cleanup EXIT ERR

  # Generate output file names
  generate_ota_info
  # Setup environment variables and paths
  env_setup
  # Patch OTA with avbroot and afsr by leveraging my-avbroot-setup
  patch_ota
}

# Function to cleanup the temporary files and unset the keys when not in interactive mode
function cleanup() {
  if [[ "${CLEANUP}" != 'true' ]]; then
    echo -e "Cleanup is disabled. Exiting...\n"
    return
  fi

  echo "Cleaning up..."
  rm -rf "${WORKDIR}"
  unset "${KEYS[@]}"
  echo "Cleanup complete."
}

# Generate the AVB and OTA signing keys.
# Has to be called manually.
function generate_keys() {
  local public_key_metadata='avb_pkmd.bin'

  # Generate the AVB and OTA signing keys
  avbroot key generate-key -o "${KEYS[AVB]}"
  avbroot key generate-key -o "${KEYS[OTA]}"

  # Convert the public key portion of the AVB signing key to the AVB public key metadata format
  # This is the format that the bootloader requires when setting the custom root of trust
  avbroot key extract-avb -k "${KEYS[AVB]}" -o "${public_key_metadata}"

  # Generate a self-signed certificate for the OTA signing key
  # This is used by recovery to verify OTA updates when sideloading
  avbroot key generate-cert -k "${KEYS[OTA]}" -o "${KEYS[CERT_OTA]}"

  # Convert the keys to base64 which can be used in CI/CD pipeline environment
  base64_encode
}

# Function to patch the Android kernel with APatch using kptools.
function patch_kernel_with_apatch() {
  local abs_workdir
  abs_workdir="$(realpath "${WORKDIR}")"
  local apatch_dir="${abs_workdir}/tools/apatch"
  local kptools="${apatch_dir}/kptools-linux"
  local kpimg="${apatch_dir}/kpimg-android"
  local extracts_dir="${abs_workdir}/extracted/extracts"
  local boot_dir="${abs_workdir}/apatch_boot"

  echo -e "Preparing APatch kernel patch environment..."
  mkdir -p "${boot_dir}"

  if [[ -z "${APATCH[SUPERKEY]}" ]]; then
    echo -e "::error::APATCH_SUPER_KEY is not set. Please add it as a GitHub Secret."
    exit 1
  fi
  if [[ ${#APATCH[SUPERKEY]} -lt 8 || ${#APATCH[SUPERKEY]} -gt 63 ]]; then
    echo -e "::error::APATCH_SUPERKEY must be between 8 and 63 characters."
    exit 1
  fi
  if [[ ! "${APATCH[SUPERKEY]}" =~ ^[a-zA-Z0-9]+$ ]]; then
    echo -e "::error::APATCH_SUPERKEY must only contain alphanumeric characters (no special chars)."
    exit 1
  fi

  if [[ ! -f "${extracts_dir}/boot.img" ]]; then
    echo -e "::error::Could not find boot.img in ${extracts_dir}."
    exit 1
  fi

  cp "${extracts_dir}/boot.img" "${boot_dir}/boot.img"
  pushd "${boot_dir}" > /dev/null

  echo -e "Unpacking boot.img with kptools (decompresses kernel automatically)..."
  "${kptools}" unpack boot.img

  if [[ ! -f "kernel" ]]; then
    echo -e "::error::kptools unpack did not produce a 'kernel' file."
    popd > /dev/null
    exit 1
  fi

  echo -e "Patching kernel with kptools ${VERSION[KERNELPATCH]}..."
  "${kptools}" -p \
    --image kernel \
    --skey "${APATCH[SUPERKEY]}" \
    --kpimg "${kpimg}" \
    --out kernel-patched

  if [[ ! -f "kernel-patched" || ! -s "kernel-patched" ]]; then
    echo -e "::error::kptools -p did not produce a patched kernel."
    popd > /dev/null
    exit 1
  fi
  
  mv kernel-patched kernel

  echo -e "Repacking boot.img with kptools..."
  "${kptools}" repack boot.img

  popd > /dev/null

  local patched_boot="${boot_dir}/new-boot.img"
  if [[ ! -f "${patched_boot}" || ! -s "${patched_boot}" ]]; then
    echo -e "::error::kptools repack did not produce new-boot.img."
    exit 1
  fi

  echo -e "APatch patching complete. Patched boot image: ${patched_boot}"
  export APATCH_PATCHED_BOOT="${patched_boot}"
}

# Function to patch the OTA with the AVB and OTA keys
# Leverages `my-avbroot-setup` to patch the OTA
# This function does a lot of things before patching the OTA
function patch_ota() {
  if [[ "${INTERACTIVE_MODE}" != 'true' ]]; then
    base64_decode
  fi

  # Set the paths
  local ota_zip="${WORKDIR}/${GRAPHENEOS[OTA_TARGET]}"
  local pkmd="${KEYS[PKMD]}"
  local grapheneos_pkmd="${WORKDIR}/extracted/avb_pkmd.bin"
  local grapheneos_otacert="${WORKDIR}/extracted/ota/META-INF/com/android/otacert"
  local magisk_path="${WORKDIR}/modules/magisk.apk"
  local my_avbroot_setup="${WORKDIR}/tools/my-avbroot-setup"

  # Activate the virtual environment
  if [ -z "${VIRTUAL_ENV}" ]; then
    enable_venv
  fi

  # Extract the official public keys and certificates if not found
  if [[ ! -e "${grapheneos_pkmd}" || ! -e "${grapheneos_otacert}" ]]; then
    echo "Extracting official keys..."
    extract_official_keys
  fi

  # At present, the script lacks the ability to disable certain modules.
  # Everything is hardcoded to be enabled by default.
  if ls "${ota_zip}.patched*.zip" 1>/dev/null 2>&1; then
    echo -e "File ${ota_zip}.pathed.zip already exists in local. Patch skipped."
  else
    echo -e "Patching OTA..."
    local args=()

    # OTA input and output
    args+=("--input" "${ota_zip}.zip")
    args+=("--output" "${OUTPUTS[PATCHED_OTA]}")

    # GrapheneOS public key metadata and certificate
    args+=("--verify-public-key-avb" "${grapheneos_pkmd}")
    args+=("--verify-cert-ota" "${grapheneos_otacert}")

    # PixeneOS decoded keys and certificates
    args+=("--sign-key-avb" "${KEYS[AVB]}")
    args+=("--sign-key-ota" "${KEYS[OTA]}")
    args+=("--sign-cert-ota" "${KEYS[CERT_OTA]}")

    # Passphrases for AVB and OTA keys
    args+=("--pass-avb-env-var" "PASSPHRASE_AVB")
    args+=("--pass-ota-env-var" "PASSPHRASE_OTA")

    # Modules
    args+=("--module-custota" "${WORKDIR}/modules/custota.zip")
    args+=("--module-msd" "${WORKDIR}/modules/msd.zip")
    args+=("--module-bcr" "${WORKDIR}/modules/bcr.zip")
    args+=("--module-oemunlockonboot" "${WORKDIR}/modules/oemunlockonboot.zip")
    args+=("--module-alterinstaller" "${WORKDIR}/modules/alterinstaller.zip")

    # Module signatures
    args+=("--module-custota-sig" "${WORKDIR}/signatures/custota.zip.sig")
    args+=("--module-msd-sig" "${WORKDIR}/signatures/msd.zip.sig")
    args+=("--module-bcr-sig" "${WORKDIR}/signatures/bcr.zip.sig")
    args+=("--module-oemunlockonboot-sig" "${WORKDIR}/signatures/oemunlockonboot.zip.sig")
    args+=("--module-alterinstaller-sig" "${WORKDIR}/signatures/alterinstaller.zip.sig")

    # Add support for Magisk, KernelSU, or APatch
    if [[ "${FLAVOR}" == 'magisk' ]] || [[ "${FLAVOR}" == 'magisk-pixincreate' ]]; then
      echo -e "Magisk is enabled. Modifying the setup script...\n"
      args+=("--patch-arg=--magisk" "--patch-arg" "${magisk_path}")
      args+=("--patch-arg=--magisk-preinit-device" "--patch-arg" "${MAGISK[PREINIT]}")
    elif [[ "${FLAVOR}" == 'magisk-nomodules' ]]; then
      echo -e "Magisk (no-modules) is enabled. Patching boot ramdisk to disable all modules...\n"
      patch_magisk_nomodules
      if [[ -n "${MAGISK_NOMODULES_PATCHED_BOOT}" ]]; then
        args+=("--patch-arg=--prepatched" "--patch-arg" "${MAGISK_NOMODULES_PATCHED_BOOT}")
      fi
    elif [[ "${FLAVOR}" == 'kernelsu' ]] || [[ "${FLAVOR}" == 'kernelsunext' ]]; then
      echo -e "${FLAVOR} is enabled. Modifying the setup script...\n"
      
      extract_magiskboot
      inject_kernelsu_into_boot
      if [ -n "${KSU_PATCHED_BOOT}" ]; then
        args+=("--patch-arg=--prepatched" "--patch-arg" "${KSU_PATCHED_BOOT}")
      fi
    elif [[ "${FLAVOR}" == 'adbroot' ]]; then
      echo -e "adbroot flavor is enabled. Patching ramdisk properties for root adb...\n"
      patch_adbroot
      if [[ -n "${ADBROOT_PATCHED_BOOT}" ]]; then
        args+=("--patch-arg=--prepatched" "--patch-arg" "${ADBROOT_PATCHED_BOOT}")
      fi
    elif [[ "${FLAVOR}" == 'apatch' ]]; then
      echo -e "APatch is enabled. Pre-patching kernel and embedding into OTA...\n"
      if [[ ! -f "${WORKDIR}/tools/apatch/kptools-linux" || ! -f "${WORKDIR}/tools/apatch/kpimg-android" ]]; then
        echo -e "::error::APatch tools not found. Run check_and_download_dependencies first."
        exit 1
      fi
      patch_kernel_with_apatch
      args+=("--patch-arg=--prepatched" "--patch-arg" "${APATCH_PATCHED_BOOT}")
    elif [[ "${FLAVOR}" == 'apatch-app' ]]; then
      echo -e "APatch-app is enabled. Using pre-provided apatch-custom-boot.img...\n"
      local custom_boot_img="$(pwd)/apatch-custom-boot.img"
      if [[ ! -f "${custom_boot_img}" ]]; then
        echo -e "::error::apatch-custom-boot.img not found!"
        exit 1
      fi
      args+=("--patch-arg=--prepatched" "--patch-arg" "${custom_boot_img}")
    else
      echo -e "Rootless mode (or unsupported flavor). Skipping root patching...\n"
    fi

    # Have to clear storage space because, `csig` results in storage runout
    rm -rf ${WORKDIR}/extracted/extracts/

    # Python command to run the patch script
    python ${my_avbroot_setup}/patch.py "${args[@]}"
  fi

  # Deactivate the virtual environment after patching the OTA
  deactivate
}

# Function to setup the environment for the my-avbroot-setup script
function my_avbroot_setup() {
  # Paths
  local setup_script="${WORKDIR}/tools/my-avbroot-setup/patch.py"
  local magisk_path="${WORKDIR}/modules/magisk.apk"
  local location_path="${DOMAIN}/${USER}/${REPOSITORY}/releases/download/${VERSION[GRAPHENEOS]}/${OUTPUTS[PATCHED_OTA]}"

  # Add support to pass env-vars to the setup script for passphrase in the CI/CD pipeline
  echo -e "Running script modifications..."

  # Update location path to use GitHub releases
  sed -i -e "s|generate_update_info(update_info, args.output.name)|generate_update_info(update_info, '${location_path}')|" "${setup_script}"
}

# Function to setup the environment variables and paths for patching the OTA
function env_setup() {
  # Set up `my-avbroot-setup` environment
  my_avbroot_setup

  # Paths
  local avbroot="${WORKDIR}/tools/avbroot"
  local afsr="${WORKDIR}/tools/afsr"
  local custota_tool="${WORKDIR}/tools/custota-tool"
  local my_avbroot_setup="${WORKDIR}/tools/my-avbroot-setup"
  local requirements_file="${my_avbroot_setup}/requirements.txt"

  # Add the paths to the PATH environment variable just so that the script can find them
  if ! command -v avbroot &>/dev/null && ! command -v afsr &>/dev/null && ! command -v custota-tool &>/dev/null; then
    export PATH="$(realpath ${afsr}):$(realpath ${avbroot}):$(realpath ${custota_tool}):$PATH"
  fi

  # Enabled python virtual environment
  enable_venv

  # Install required Python packages
  if [[ -f "${requirements_file}" ]]; then
    local missing_packages=false
    while read -r package; do
      [[ -z "${package}" ]] && continue
      if ! pip list | grep -i "^${package%%[=><]*}" &>/dev/null; then
        missing_packages=true
        break
      fi
    done <"${requirements_file}"

    if [[ "${missing_packages}" == "true" ]]; then
      echo -e "Installing required Python packages from requirements.txt..."
      pip3 install -r "${requirements_file}"
    fi
  else
    echo -e "Warning: requirements.txt not found at ${requirements_file}"
  fi
}

# Function to enable the python virtual environment
function enable_venv() {
  local dir_path='' # Default value is empty string
  local base_path=$(basename "$(pwd)")
  local venv_path=''

  # Check presence of venv
  # Create a virtual environment if not found
  if [[ "${base_path}" == "my-avbroot-setup" ]]; then
    if [ ! -d "venv" ]; then
      echo -e "Virtual environment not found. Creating..."
      python3 -m venv venv
    fi
  else
    echo -e "The script is not run from the \`my-avbroot-setup\` directory.\nSearching for the directory..."
    dir_path=$(find . -type d -name "my-avbroot-setup" -print -quit)
    if [ ! -d "${dir_path}/venv" ]; then
      echo -e "Virtual environment not found in path \`${dir_path}\`. Creating..."
      python3 -m venv "${dir_path}/venv"
    fi
  fi

  # Set the virtual environment path
  if [ -n "${dir_path}" ]; then
    venv_path="${dir_path}/venv/bin/activate"
  else
    venv_path="venv/bin/activate"
  fi

  # Ensure venv_path is set correctly and activate the virtual environment
  if [ -f "${venv_path}" ]; then
    source "${venv_path}"
  else
    echo -e "Virtual environment activation script not found at \`${venv_path}\`."
  fi
}

# Construct URL for the tools and download them
# This function is called by download_dependencies function when running in non-interactive mode
function url_constructor() {
  local repository="${1}"
  local user='chenxiaolong'
  INTERACTIVE_MODE="${2:-true}"

  local repository_upper_case=$(echo "${repository}" | tr '[:lower:]' '[:upper:]')

  echo -e "Constructing URL for \`${repository}\` as \`${repository}\` is non-existent at \`${WORKDIR}\`..."
  # `my-avbroot-setup` is git repository
  if [[ "${repository}" == "my-avbroot-setup" ]]; then
    URL="${DOMAIN}/${user}/${repository}"
  else
    # Afsr, avbroot, and custota-tool are binaries and are platform dependent. Modules are zipped files.
    if [[ "${repository}" == "afsr" || "${repository}" == "avbroot" || "${repository}" == "custota-tool" ]]; then
      local suffix="${ARCH}"
    else
      local suffix="release"
    fi

    # Custota is a special case
    # Custota is a module and Custota-Tool is a binary
    # Both reside in same repository
    if [[ "${repository}" == "custota-tool" ]]; then
      local download_page="${DOMAIN}/${user}/Custota/releases/download"
      local version="v${VERSION[CUSTOTA]}"
      local application="${repository}-${VERSION[CUSTOTA]}-${suffix}.zip"
    else
      local download_page="${DOMAIN}/${user}/${repository}/releases/download"
      local version="v${VERSION[${repository_upper_case}]}"
      local application="${repository}-${VERSION[${repository_upper_case}]}-${suffix}.zip"
    fi

    URL="${download_page}/${version}/${application}"
    SIGNATURE_URL="${download_page}/${version}/${application}.sig"
  fi

  echo -e "URL for \`${repository}\`: ${URL}"

  # If the script is running in interactive mode, prompt the user to overwrite the existing files
  if [[ "${INTERACTIVE_MODE}" == 'true' ]]; then
    if [[ -e "${WORKDIR}/tools/${repository}" || -e "${WORKDIR}/modules/${repository}.zip" || -e "${WORKDIR}/signatures/${repository}.zip.sig" ]]; then
      echo -n "Warning: \`${repository}\` already exists in \`${WORKDIR}\`\nOverwrite? (y/n) [default: yes]: "
      read -r confirm
      confirm=${confirm:-"yes"}
      if [[ $confirm =~ ^[yY](es|ES)?$ ]]; then
        echo "Removing existing files..."
        rm -rf "${WORKDIR}/tools/${repository}" "${WORKDIR}/modules/${repository}.zip" "${WORKDIR}/signatures/${repository}.zip.sig"
      else
        echo "Aborted."
        exit 1
      fi
    fi
  fi

  # Make the get call to download the tools and modules
  get "${repository}" "${URL}" "${SIGNATURE_URL}"
}

# Function to download the dependencies
# This calls the constructor that constructs the URL for the tools and modules
function download_dependencies() {
  local tool="${1}"
  INTERACTIVE_MODE='false'

  if type url_constructor &>/dev/null; then
    url_constructor "${tool}" "${INTERACTIVE_MODE}"
  else
    echo -e "Error: \`url_constructor\` function is not defined."
    exit 1
  fi
}

# Function to extract the official GrapheneOS keys from the OTA
function extract_official_keys() {
  # https://github.com/chenxiaolong/my-avbroot-setup/issues/1#issuecomment-2270286453
  # AVB: Extract vbmeta.img, run avbroot avb info -i vbmeta.img.
  #   The public_key field is avb_pkmd.bin encoded as hex.
  #   Verify that the key is official by comparing its sha256 checksum with grapheneos.org/articles/attestation-compatibility-guide.
  # OTA: Extract META-INF/com/android/otacert from the OTA.
  #   (Or from otacerts.zip inside system.img or vendor_boot.img. All 3 files are identical.)
  local ota_zip="${WORKDIR}/${GRAPHENEOS[OTA_TARGET]}.zip"

  # Extract OTA
  avbroot ota extract \
    --input "${ota_zip}" \
    --directory "${WORKDIR}/extracted/extracts" \
    --all

  # Extract vbmeta.img
  # To verify, execute sha256sum avb_pkmd.bin in terminal
  # compare the output with base16-encoded verified boot key fingerprints
  # mentioned at https://grapheneos.org/articles/attestation-compatibility-guide for the respective device
  avbroot avb info -i "${WORKDIR}/extracted/extracts/vbmeta.img" |
    grep 'public_key' |
    sed -n 's/.*public_key: "\(.*\)".*/\1/p' |
    tr -d '[:space:]' | xxd -r -p >"${WORKDIR}/extracted/avb_pkmd.bin"

  # Extract META-INF/com/android/otacert from OTA or otacerts.zip from either vendor_boot.img or system.img
  unzip "${ota_zip}" -d "${WORKDIR}/extracted/ota"
}

function dirty_suffix() {
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "-dirty"
  else
    echo ""
  fi
}

# Function to make directories
function make_directories() {
  mkdir -p \
    "${WORKDIR}" \
    "${WORKDIR}/.keys" \
    "${WORKDIR}/extracted/extracts" \
    "${WORKDIR}/extracted/ota" \
    "${WORKDIR}/modules" \
    "${WORKDIR}/signatures" \
    "${WORKDIR}/tools"
}

# Function to patch the boot image ramdisk so that all Magisk modules are disabled on boot.
# On GKI (Android 13+, boot header v4, RAMDISK_SZ=0) the ramdisk lives in init_boot.img.
# This function:
#   1. Reuses extract_magiskboot to get the magiskboot binary.
#   2. Extracts boot images from the OTA with avbroot --boot-only.
#   3. Auto-detects which image (init_boot.img → GKI, boot.img → legacy) has the ramdisk.
#   4. Extracts Magisk arm64 binaries (magiskinit, magisk64, stub.apk) from the APK.
#   5. Uses magiskboot cpio to embed Magisk AND our disable-modules overlay.d script in one pass.
#   6. Repacks and exports MAGISK_NOMODULES_PATCHED_BOOT; caller passes it as --prepatched.
function patch_magisk_nomodules() {
  local abs_workdir
  abs_workdir="$(realpath "${WORKDIR}")"
  local magisk_apk="${abs_workdir}/modules/magisk.apk"
  local nm_dir="${abs_workdir}/magisk_nomodules"
  local imgs_dir="${nm_dir}/imgs"
  local work_dir="${nm_dir}/work"
  local ota_zip="${abs_workdir}/${GRAPHENEOS[OTA_TARGET]}.zip"

  echo -e "[magisk-nomodules] Preparing workspace..."
  rm -rf "${nm_dir}"
  mkdir -p "${imgs_dir}" "${work_dir}"

  # ── 1. Get magiskboot ──────────────────────────────────────────────────────
  # extract_magiskboot() is defined in kernelsu.sh (which is sourced by util_functions.sh).
  # It extracts lib/x86_64/libmagiskboot.so → ${WORKDIR}/tools/magiskboot.
  extract_magiskboot
  local magiskboot="${abs_workdir}/tools/magiskboot"

  # ── 2. Extract boot images from the OTA ───────────────────────────────────
  echo -e "[magisk-nomodules] Extracting boot images from OTA..."
  avbroot ota extract \
    --input "${ota_zip}" \
    --directory "${imgs_dir}" \
    --boot-only

  # ── 3. Auto-detect which image carries the ramdisk ────────────────────────
  # GKI (header v4): boot.img → RAMDISK_SZ=0; ramdisk in init_boot.img.
  # Legacy (header v2/v3): ramdisk is directly in boot.img.
  local target_img=""
  for candidate in "${imgs_dir}/init_boot.img" "${imgs_dir}/boot.img"; do
    [[ ! -f "${candidate}" ]] && continue
    local probe_dir="${work_dir}/probe_$(basename "${candidate}")"
    mkdir -p "${probe_dir}"
    local probe_out
    probe_out=$(cd "${probe_dir}" && "${magiskboot}" unpack "${candidate}" 2>&1) || true
    echo -e "[magisk-nomodules] probe $(basename ${candidate}): ${probe_out}"
    local ramdisk_sz
    ramdisk_sz=$(echo "${probe_out}" | awk '/RAMDISK_SZ/{gsub(/[\[\]]/,"",$2); print $2}')
    if [[ -n "${ramdisk_sz}" && "${ramdisk_sz}" != "0" && -f "${probe_dir}/ramdisk.cpio" ]]; then
      target_img="${candidate}"
      echo -e "[magisk-nomodules] → ramdisk found in $(basename "${target_img}") (sz=${ramdisk_sz})"
      # Keep the unpacked workspace; we'll use it next.
      work_dir="${probe_dir}"
      break
    fi
  done

  if [[ -z "${target_img}" ]]; then
    echo -e "::error::[magisk-nomodules] No boot image with a ramdisk found."
    echo -e "          Checked: ${imgs_dir}/init_boot.img, ${imgs_dir}/boot.img"
    exit 1
  fi

  # ── 4. Extract arm64 Magisk binaries from the APK ─────────────────────────
  # magiskinit: replaces /init in the ramdisk (arm64)
  # magisk64:   main Magisk binary (arm64-v8a)
  # stub.apk:   stub app embedded in ramdisk
  echo -e "[magisk-nomodules] Extracting Magisk arm64 binaries..."
  python3 - <<PYEOF
import zipfile, os, stat, sys
apk = '${magisk_apk}'
out = '${work_dir}'
binary_map = {
    'lib/arm64-v8a/libmagiskinit.so': 'magiskinit',
    'lib/arm64-v8a/libmagisk64.so':   'magisk64',
    'lib/armeabi-v7a/libmagisk32.so': 'magisk32',
    'assets/stub.apk':                'stub.apk',
}
extracted = {}
with zipfile.ZipFile(apk, 'r') as z:
    names = set(z.namelist())
    for src, dst in binary_map.items():
        if src in names and dst not in extracted:
            data = z.read(src)
            dest_path = os.path.join(out, dst)
            with open(dest_path, 'wb') as f:
                f.write(data)
            if not dst.endswith('.apk'):
                os.chmod(dest_path, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP)
            extracted[dst] = dest_path
            print(f'  [magisk-nomodules] extracted {src} -> {dst}')
if 'magiskinit' not in extracted:
    print('ERROR: magiskinit not found in Magisk APK', file=sys.stderr)
    sys.exit(1)
PYEOF

  # ── 5. Write the disable-modules script to a temp file ────────────────────
  local disable_script_file="${work_dir}/10-disable-modules.sh"
  cat > "${disable_script_file}" <<'DISABLE_SCRIPT'
#!/system/bin/sh
# PixeneOS magisk-nomodules: touch 'disable' in every Magisk module dir
# at post-fs-data time so no modules are ever loaded.
MODULES_DIR=/data/adb/modules
if [ -d "$MODULES_DIR" ]; then
  for mod_dir in "$MODULES_DIR"/*/; do
    [ -d "$mod_dir" ] && touch "${mod_dir}disable"
  done
fi
DISABLE_SCRIPT
  chmod 0755 "${disable_script_file}"

  # ── 6. Embed Magisk + our overlay.d script using magiskboot cpio ──────────
  # magiskboot cpio operates in-place on ramdisk.cpio.
  # "patch" applies the Magisk bootstrap (replaces init, sets up magiskinit, etc.)
  # and preserves all files we added before it runs.
  echo -e "[magisk-nomodules] Embedding Magisk and disable-modules script into ramdisk..."
  pushd "${work_dir}" > /dev/null

  # Build the config content
  local magisk_config="KEEPVERITY=true
KEEPFORCEENCRYPT=true"
  if [[ -n "${MAGISK[PREINIT]}" ]]; then
    magisk_config="${magisk_config}
PREINITDEVICE=${MAGISK[PREINIT]}"
  fi

  local config_file="${work_dir}/magisk_config"
  echo "${magisk_config}" > "${config_file}"

  # Build the cpio command arguments dynamically
  local cpio_args=(
    "add 0750 init magiskinit"
    "mkdir 0750 overlay.d"
    "mkdir 0750 overlay.d/sbin"
    "add 0755 overlay.d/10-disable-modules.sh 10-disable-modules.sh"
  )
  [[ -f "magisk64" ]] && cpio_args+=("add 0755 overlay.d/sbin/magisk64 magisk64")
  [[ -f "magisk32" ]] && cpio_args+=("add 0755 overlay.d/sbin/magisk32 magisk32")
  [[ -f "stub.apk" ]] && cpio_args+=("add 0644 overlay.d/sbin/stub.apk stub.apk")
  cpio_args+=("patch")
  cpio_args+=("mkdir 0000 .backup")
  cpio_args+=("add 0000 .backup/.magisk magisk_config")

  "${magiskboot}" cpio ramdisk.cpio "${cpio_args[@]}"
  popd > /dev/null

  # ── 7. Repack and export the final image ──────────────────────────────────
  echo -e "[magisk-nomodules] Repacking boot image..."
  local final_img="${nm_dir}/nomodules_final.img"
  pushd "${work_dir}" > /dev/null
  "${magiskboot}" repack "${target_img}" "${final_img}"
  popd > /dev/null

  if [[ ! -f "${final_img}" || ! -s "${final_img}" ]]; then
    echo -e "::error::[magisk-nomodules] Repack produced no output."
    exit 1
  fi

  echo -e "[magisk-nomodules] Done. Final image (Magisk + no-modules): ${final_img}"
  export MAGISK_NOMODULES_PATCHED_BOOT="${final_img}"
}

# Function to modify ramdisk properties to enable ADB root for the adbroot flavor
function patch_adbroot() {
  local abs_workdir
  abs_workdir="$(realpath "${WORKDIR}")"
  local adbroot_dir="${abs_workdir}/adbroot"
  local imgs_dir="${adbroot_dir}/imgs"
  local work_dir="${adbroot_dir}/work"
  local ota_zip="${abs_workdir}/${GRAPHENEOS[OTA_TARGET]}.zip"

  echo -e "[adbroot] Preparing workspace..."
  rm -rf "${adbroot_dir}"
  mkdir -p "${imgs_dir}" "${work_dir}"

  # 1. Get magiskboot
  extract_magiskboot
  local magiskboot="${abs_workdir}/tools/magiskboot"

  # 2. Extract boot images from OTA
  echo -e "[adbroot] Extracting boot images from OTA..."
  avbroot ota extract \
    --input "${ota_zip}" \
    --directory "${imgs_dir}" \
    --boot-only

  # 3. Auto-detect which image carries the ramdisk
  local target_img=""
  for candidate in "${imgs_dir}/init_boot.img" "${imgs_dir}/boot.img"; do
    [[ ! -f "${candidate}" ]] && continue
    local probe_dir="${work_dir}/probe_$(basename "${candidate}")"
    mkdir -p "${probe_dir}"
    local probe_out
    probe_out=$(cd "${probe_dir}" && "${magiskboot}" unpack "${candidate}" 2>&1) || true
    echo -e "[adbroot] probe $(basename ${candidate}): ${probe_out}"
    local ramdisk_sz
    ramdisk_sz=$(echo "${probe_out}" | awk '/RAMDISK_SZ/{gsub(/[\[\]]/,"",$2); print $2}')
    if [[ -n "${ramdisk_sz}" && "${ramdisk_sz}" != "0" && -f "${probe_dir}/ramdisk.cpio" ]]; then
      target_img="${candidate}"
      echo -e "[adbroot] → ramdisk found in $(basename "${target_img}") (sz=${ramdisk_sz})"
      work_dir="${probe_dir}"
      break
    fi
  done

  if [[ -z "${target_img}" ]]; then
    echo -e "::error::[adbroot] No boot image with a ramdisk found."
    exit 1
  fi

  # 4. Modify prop.default / default.prop inside ramdisk.cpio
  echo -e "[adbroot] Modifying ramdisk properties for ADB root..."
  pushd "${work_dir}" > /dev/null

  local prop_file=""
  "${magiskboot}" cpio ramdisk.cpio "extract prop.default prop.default" 2>/dev/null && prop_file="prop.default"
  if [[ -z "${prop_file}" ]]; then
    "${magiskboot}" cpio ramdisk.cpio "extract default.prop default.prop" 2>/dev/null && prop_file="default.prop"
  fi

  if [[ -z "${prop_file}" || ! -f "${prop_file}" ]]; then
    echo -e "::warning::[adbroot] Could not find prop.default or default.prop in ramdisk!"
  else
    echo -e "[adbroot] Found ${prop_file}, injecting insecure adb properties..."
    sed -i 's/ro.secure=1/ro.secure=0/g' "${prop_file}"
    sed -i 's/ro.adb.secure=1/ro.adb.secure=0/g' "${prop_file}"
    sed -i 's/ro.debuggable=0/ro.debuggable=1/g' "${prop_file}"
    
    grep -q "ro.secure=" "${prop_file}" || echo "ro.secure=0" >> "${prop_file}"
    grep -q "ro.debuggable=" "${prop_file}" || echo "ro.debuggable=1" >> "${prop_file}"
    grep -q "ro.adb.secure=" "${prop_file}" || echo "ro.adb.secure=0" >> "${prop_file}"
    
    "${magiskboot}" cpio ramdisk.cpio "add 0644 ${prop_file} ${prop_file}"
  fi
  popd > /dev/null

  # 5. Repack and export
  echo -e "[adbroot] Repacking boot image..."
  local final_img="${adbroot_dir}/adbroot_final.img"
  pushd "${work_dir}" > /dev/null
  "${magiskboot}" repack "${target_img}" "${final_img}"
  popd > /dev/null

  if [[ ! -f "${final_img}" || ! -s "${final_img}" ]]; then
    echo -e "::error::[adbroot] Repack produced no output."
    exit 1
  fi

  echo -e "[adbroot] Done. Final image: ${final_img}"
  export ADBROOT_PATCHED_BOOT="${final_img}"
}

function generate_ota_info() {
  # Detect build flavor
  if [[ "${FLAVOR}" == 'magisk' ]] || [[ "${FLAVOR}" == 'magisk-pixincreate' ]] || [[ "${FLAVOR}" == 'magisk-nomodules' ]]; then
    local build_flavor="${FLAVOR}-${VERSION[MAGISK]}"
  elif [[ "${FLAVOR}" == 'kernelsu' ]]; then
    local build_flavor="kernelsu-${VERSION[KERNELSU]}"
  elif [[ "${FLAVOR}" == 'kernelsunext' ]]; then
    local build_flavor="kernelsunext-${VERSION[KERNELSU_NEXT]}"
  elif [[ "${FLAVOR}" == 'apatch' ]] || [[ "${FLAVOR}" == 'apatch-app' ]]; then
    local build_flavor="${FLAVOR}-${VERSION[APATCH]}"
  elif [[ "${FLAVOR}" == 'adbroot' ]]; then
    local build_flavor="adbroot"
  else
    local build_flavor="rootless"
  fi
  # e.g. bluejay-2024082200-rootless-abc12345-dirty.zip
  OUTPUTS[PATCHED_OTA]="${DEVICE_NAME}-${VERSION[GRAPHENEOS]}-${build_flavor}-$(git rev-parse --short HEAD)$(dirty_suffix).zip"
}

function check_toml_env() {
  declare -A config_vars
  toml_file="env.toml"

  if [ -f "$toml_file" ]; then
    while IFS='=' read -r key value; do
      key=$(echo "$key" | xargs)                                  # Trim whitespace
      value=$(echo "$value" | xargs | sed -E 's/^"([^"]*)"$/\1/') # Trim whitespace and quotes
      if [[ -n "$key" && -n "$value" ]]; then
        config_vars["$key"]="$value"
      fi
    done < <(grep -v '^#' "$toml_file") # Ignore comments

    if [[ ${#config_vars[@]} -gt 0 ]]; then
      echo -e "Found variables in \`${toml_file}\` and will take precedence over other values.\n"
      for key in "${!config_vars[@]}"; do
        echo -e "${key}: ${config_vars[$key]}"
        eval "${key}=${config_vars[$key]}"
      done
    else
      echo -e "Failed to find the required variables in \`${toml_file}\`.\n"
      exit 1
    fi
  fi
}

function supported_tools() {
  local arg="${1:-}"
  local tools=("avbroot" "afsr" "alterinstaller" "custota" "custota-tool" "msd" "bcr" "oemunlockonboot" "my-avbroot-setup")

  if [[ "${arg}" == "cdd" ]]; then
    echo "${tools[@]}"
    return
  fi

  echo -e "Supported tools:"
  for tool in "${tools[@]}"; do
    echo -e "- ${tool}"
  done
  echo -e "- magisk"
}

function help() {
  cat <<EOF
Usage: source src/<file>.sh [functions] [arguments]
functions:
  - url_constructor        Run the URL Constructor function
    - arguments            Supported tool name.
                           Check 'supported_tools' for more info
  - generate_keys          Generate keys
  - help                   Show this help message
  - check_toml_env         Check TOML environment
  - supported_tools        List supported tools
EOF
}
