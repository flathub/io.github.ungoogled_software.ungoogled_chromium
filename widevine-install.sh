#!/usr/bin/env bash
set -euo pipefail

# Fetch latest WideVine version
widevine_ver_url="https://dl.google.com/widevine-cdm/versions.txt"
widevine_ver="$(wget -qO- "${widevine_ver_url}" | tail -n1)"
if [[ -z "${widevine_ver}" ]]; then
    echo "Error: Failed to get WideVine version from ${widevine_ver_url}" >&2
    exit 1
fi

# Determine architecture
arch="$(uname -m)"
case "${arch}" in
    x86_64)
        widevine_arch="x64"
        chromium_arch="x64"
        ;;
    *)
        echo "Error: Unsupported architecture ${arch}" >&2
        exit 1
        ;;
esac

# Create temporary files/directories and set up cleanup
tmp_zip="$(mktemp)"
tmp_dir="$(mktemp -d)"
trap 'rm -f "${tmp_zip:?}"; rm -rf "${tmp_dir:?}"' EXIT

# Download WideVine
widevine_zip_url="https://dl.google.com/widevine-cdm/${widevine_ver}-linux-${widevine_arch}.zip"
echo "======================================================================"
echo "Downloading WideVine version ${widevine_ver} for ${widevine_arch}..."
echo "URL: ${widevine_zip_url}"
if ! wget -qO "${tmp_zip}" "${widevine_zip_url}"; then
    echo "----------------------------------------------------------------------" >&2
    echo "Error: Failed to download WideVine from ${widevine_zip_url}" >&2
    echo "======================================================================" >&2
    exit 1
fi
echo "Download complete."
echo "======================================================================"

# Extract WideVine
echo "Extracting WideVine..."
if ! unzip -qod "${tmp_dir}" "${tmp_zip}"; then
    echo "----------------------------------------------------------------------" >&2
    echo "Error: Failed to extract ${tmp_zip} to ${tmp_dir}" >&2
    echo "======================================================================" >&2
    exit 1
fi
echo "Extraction complete."
echo "======================================================================"

# Define installation paths
install_base_dir="${HOME}/.var/app/io.github.ungoogled_software.ungoogled_chromium/config/chromium/WidevineCdm/${widevine_ver}"
install_so_path="${install_base_dir}/_platform_specific/linux_${chromium_arch}/libwidevinecdm.so"
install_manifest_path="${install_base_dir}/manifest.json"
install_license_path="${install_base_dir}/LICENSE.txt"

# Install WideVine files
echo "Installing WideVine files to ${install_base_dir}..."
install -Dm644 "${tmp_dir}/libwidevinecdm.so" "${install_so_path}"
install -Dm644 "${tmp_dir}/manifest.json" "${install_manifest_path}"
install -Dm644 "${tmp_dir}/LICENSE.txt" "${install_license_path}"
echo "Installation complete."
echo "======================================================================"
echo

# Print success message and instructions
echo "**********************************************************************"
echo "WideVine version ${widevine_ver} installed successfully!"
echo "Installation path: ${install_base_dir}"
echo
echo "IMPORTANT: You may need to restart Ungoogled Chromium"
echo "           at least TWICE for WideVine to be detected and work."
echo "**********************************************************************"
