#!/bin/bash
set -exo pipefail

mkdir -p /app/chromium

pushd out/Release
for path in chrome chrome_crashpad_handler icudtl.dat *.so libvulkan.so.1 *.pak *.bin *.png locales MEIPreload vk_swiftshader_icd.json; do
	# All the 'libVk*' names are just for debugging, stuff like "libVkICD_mock_icd" and "libVkLayer_khronos_validation".
	[[ "${path}" == libVk* ]] && continue
	cp -rv "${path}" /app/chromium || true
done
popd

for size in 24 48 64 128 256; do
	install -Dvm 644 "chrome/app/theme/chromium/product_logo_${size}.png" "/app/share/icons/hicolor/${size}x${size}/apps/io.github.ungoogled_software.ungoogled_chromium.png";
done
install -Dvm 644 chrome/app/theme/chromium/product_logo.svg /app/share/icons/hicolor/scalable/apps/io.github.ungoogled_software.ungoogled_chromium.svg
install -Dvm 644 cobalt.ini -t /app/etc
install -Dvm 644 io.github.ungoogled_software.ungoogled_chromium.desktop -t /app/share/applications
install -Dvm 644 io.github.ungoogled_software.ungoogled_chromium.metainfo.xml -t /app/share/metainfo
install -Dvm 755 chromium.sh /app/bin/chromium
