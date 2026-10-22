#!/bin/bash -ex

app_id=io.github.ungoogled_software.ungoogled_chromium

mkdir -p /app/chromium

pushd out/Release
for path in chrome chrome_crashpad_handler icudtl.dat *.so libvulkan.so.1 *.pak *.bin *.png vk_swiftshader_icd.json; do
    # All the 'libVk*' names are just for debugging, stuff like "libVkICD_mock_icd" and "libVkLayer_khronos_validation".
    [[ "$path" == libVk* ]] && continue
    cp -rv $path /app/chromium
done
popd

# Compress the locale packs into Flatpak's locale extension.
mkdir -p /app/chromium/locales
for locale_path in out/Release/locales/*.pak; do
    locale_file=${locale_path##*/}
    lang_region=${locale_file%.pak}
    lang_code=${lang_region%%-*}
    dest_dir=/app/share/runtime/locale/$lang_code
    mkdir -p "$dest_dir"
    gzip -9nc "$locale_path" > "$dest_dir/$locale_file"
    ln -sf "$dest_dir/$locale_file" "/app/chromium/locales/$locale_file"
done

for size in 24 48 64 128 256; do
    install -Dvm 644 chrome/app/theme/chromium/linux/product_logo_$size.png /app/share/icons/hicolor/${size}x${size}/apps/$app_id.png;
done
for size in 16 32; do
    install -Dvm 644 chrome/app/theme/default_100_percent/chromium/linux/product_logo_$size.png /app/share/icons/hicolor/${size}x${size}/apps/$app_id.png;
done
install -Dvm 644 chrome/app/theme/chromium/product_logo.svg /app/share/icons/hicolor/scalable/apps/$app_id.svg
install -Dvm 644 cobalt.ini -t /app/etc
install -Dvm 644 $app_id.desktop -t /app/share/applications
install -Dvm 644 $app_id.metainfo.xml -t /app/share/metainfo
install -Dvm 755 chromium.sh /app/bin/chromium
