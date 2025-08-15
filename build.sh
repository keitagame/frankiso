#!/usr/bin/env bash
set -euo pipefail

# カレントディレクトリをスクリプト位置に固定
cd "$(dirname "$0")"

# 設定読み込み
eval $(grep -E '^[a-z]+' config.yaml | sed 's/: /=/')


# 作業ディレクトリ準備
rm -rf "${work_dir}" "${out_dir}"
mkdir -p "${work_dir}" "${out_dir}"

# ベースシステム構築
echo "[BUILD] pacstrap -> ${work_dir}/root"
pacstrap -c -d -G -R /mnt"${work_dir}/root" $(< profiles/"${profile}"/packages)

# fstab, hostname 生成
genfstab -U "${work_dir}/root" >> "${work_dir}/root/etc/fstab"

# chroot 内処理
echo "[BUILD] arch-chroot -> post_install"
arch-chroot "${work_dir}/root" /bin/bash -eux <<EOF
# サービス有効化
for svc in $(< profiles/"${profile}"/services); do
  systemctl enable "\$svc"
done

# ユーザープロファイルの post-install スクリプト実行
/profiles/${profile}/post_install.sh
EOF

# initramfs, Bootloader 設定
echo "[BUILD] mkinitcpio & ${bootloader}"
arch-chroot "${work_dir}/root" mkinitcpio -P

if [[ "${bootloader}" == "syslinux" ]]; then
  arch-chroot "${work_dir}/root" bash -eux <<EOF
  pacman -Sy --noconfirm syslinux
  syslinux-install_update -i -a -m
EOF
fi

# ISO イメージ生成
echo "[BUILD] SquashFS + xorriso"
mksquashfs "${work_dir}/root" "${out_dir}/airootfs.sfs" ${squashfs_opts}
cp -a "${work_dir}/root"/usr/lib/syslinux/isos/isolinux.bin "${out_dir}/"
cat > "${out_dir}/isolinux.cfg" <<CFG
UI menu.c32
PROMPT 0
MENU TITLE ${iso_name}
LABEL arch
  MENU LABEL Boot ${iso_name}
  KERNEL /vmlinuz-linux
  APPEND initrd=/initramfs-linux.img archisobasedir=${iso_name} archisolabel=${label}
CFG

xorriso -as mkisofs \
  -iso-level 3 \
  -o "${iso_name}.iso" \
  -volid "${label}" \
  -eltorito-boot isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
  "${out_dir}"

echo "[DONE] ${iso_name}.iso を生成しました"
