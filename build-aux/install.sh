#!/bin/bash
set -exo pipefail

mkdir -p /app/chromium

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

cp -v "${TOPLEVEL_FILES[@]/#/out/Release/}" /app/chromium/

install -Dvm644 -t /app/chromium/locales out/Release/locales/*.pak
for pak_file in /app/chromium/locales/*.pak; do
	gzip -9n "${pak_file}"
	mv "${pak_file}.gz" "${pak_file}"
done

for size in 24 48 64 128 256; do
	install -Dvm644 "chrome/app/theme/chromium/product_logo_${size}.png" "/app/share/icons/hicolor/${size}x${size}/apps/io.github.ungoogled_software.ungoogled_chromium.png"
done

for size in 16 32; do
	install -Dvm644 "chrome/app/theme/default_100_percent/chromium/product_logo_${size}.png" "/app/share/icons/hicolor/${size}x${size}/apps/io.github.ungoogled_software.ungoogled_chromium.png"
done

install -Dvm644 chrome/app/theme/chromium/product_logo.svg /app/share/icons/hicolor/scalable/apps/io.github.ungoogled_software.ungoogled_chromium.svg
install -Dvm644 cobalt.ini -t /app/etc
install -Dvm644 io.github.ungoogled_software.ungoogled_chromium.desktop -t /app/share/applications
install -Dvm644 io.github.ungoogled_software.ungoogled_chromium.metainfo.xml -t /app/share/metainfo
install -Dvm755 chromium.sh /app/bin/chromium
