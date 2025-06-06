#!/bin/bash
set -euxo pipefail

mkdir -pv "${FLATPAK_DEST}/chromium"

TOPLEVEL_FILES=(
	chrome
	chrome_100_percent.pak
	chrome_200_percent.pak
	chrome_crashpad_handler
	resources.pak
	v8_context_snapshot.bin

	# ANGLE
	libEGL.so
	libGLESv2.so

	# SwiftShader ICD
	libvk_swiftshader.so
	libvulkan.so.1
	vk_swiftshader_icd.json
)

cp -v "${TOPLEVEL_FILES[@]/#/out/Release/}" "${FLATPAK_DEST}/chromium/"

mkdir -pv "${FLATPAK_DEST}/chromium/locales"
for locale_path in out/Release/locales/*.pak; do
	locale_file=${locale_path##*/}
	lang_region=${locale_file%.pak}
	lang_code=${lang_region%%-*}

	dest_dir="${FLATPAK_DEST}/share/runtime/locale/${lang_code}"
	dest_file="${dest_dir}/${locale_file}"

	mkdir -pv "${dest_dir}"
	gzip -9nc "${locale_path}" > "${dest_file}"
	ln -svf "${dest_file}" "${FLATPAK_DEST}/chromium/locales/${locale_file}"
done

for size in 24 48 64 128 256; do
	install -Dvm644 "chrome/app/theme/chromium/product_logo_${size}.png" "${FLATPAK_DEST}/share/icons/hicolor/${size}x${size}/apps/io.github.ungoogled_software.ungoogled_chromium.png"
done

for size in 16 32; do
	install -Dvm644 "chrome/app/theme/default_100_percent/chromium/product_logo_${size}.png" "${FLATPAK_DEST}/share/icons/hicolor/${size}x${size}/apps/io.github.ungoogled_software.ungoogled_chromium.png"
done

install -Dvm644 chrome/app/theme/chromium/product_logo.svg "${FLATPAK_DEST}/share/icons/hicolor/scalable/apps/io.github.ungoogled_software.ungoogled_chromium.svg"
install -Dvm644 cobalt.ini -t "${FLATPAK_DEST}/etc"
install -Dvm644 io.github.ungoogled_software.ungoogled_chromium.desktop -t "${FLATPAK_DEST}/share/applications"
install -Dvm644 io.github.ungoogled_software.ungoogled_chromium.metainfo.xml -t "${FLATPAK_DEST}/share/metainfo"
install -Dvm755 chromium.sh "${FLATPAK_DEST}/bin/chromium"
