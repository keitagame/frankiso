#!/usr/bin/env bash
set -euo pipefail

# === 初期設定 ===
cd "$(dirname "$0")"

# config.yaml を読み込む
eval "$(
  awk -F': ' '/^[a-zA-Z_]+: / {
    gsub(/"/, "", $2);
    gsub(/ /, "", $2);
    print $1 "=" $2
  }' config.yaml
)"

# 絶対パスに変換
work_dir="$(pwd)/${work_dir}"
out_dir="$(pwd)/${out_dir}"
profile_dir="profiles/${profile}"

# === 作業ディレクトリ準備 ===
echo "[STEP] Clean workspace"
rm -rf "$work_dir" "$out_dir"
mkdir -p "$work_dir/root" "$out_dir"

# === ベースシステム構築 ===
echo "[STEP] pacstrap base system"
pacstrap -c -G "$work_dir/root" $(< "$profile_dir/packages")

# === 基本設定 ===
echo "[STEP] Generate fstab"
genfstab -U "$work_dir/root" >> "$work_dir/root/etc/fstab"

echo "[STEP] Copy post_install script"
cp "$profile_dir/post_install.sh" "$work_dir/root/"
chmod +x "$work_dir/root/post_install.sh"

# === chroot 内設定 ===
echo "[STEP] arch-chroot configuration"
arch-chroot "$work_dir/root" /bin/bash -eux <<EOF
# サービス有効化
for svc in $(< /profiles/${profile}/services); do
  systemctl enable "\$svc"
done

# ユーザー定義の post-install 処理
/post_install.sh
EOF

# === initramfs & bootloader ===
echo "[STEP] mkinitcpio"
arch-chroot "$work_dir/root" mkinitcpio -P

if [[ "$bootloader" == "syslinux" ]]; then
  echo "[STEP] Install syslinux"
  arch-chroot "$work_dir/root" pacman -Sy --noconfirm syslinux
  arch-chroot "$work_dir/root" syslinux-install_update -i -a -m
fi

# === ISO イメージ生成 ===
echo "[STEP] Create squashfs"
mksquashfs "$work_dir/root" "$out_dir/airootfs.sfs" $squashfs_opts

echo "[STEP] Prepare boot files"
cp "$work_dir/root/usr/lib/syslinux/isolinux.bin" "$out_dir/"
cat > "$out_dir/isolinux.cfg" <<CFG
UI menu.c32
PROMPT 0
MENU TITLE ${iso_name}
LABEL arch
  MENU LABEL Boot ${iso_name}
  KERNEL /vmlinuz-linux
  APPEND initrd=/initramfs-linux.img archisobasedir=${iso_name} archisolabel=${label}
CFG

echo "[STEP] Generate ISO"
xorriso -as mkisofs \
  -iso-level 3 \
  -o "${iso_name}.iso" \
  -volid "${label}" \
  -eltorito-boot isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
  "$out_dir"

echo "[DONE] ISO generated: ${iso_name}.iso"

