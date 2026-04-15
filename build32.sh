#!/usr/bin/env bash

# 完全32bit (i686) Arch Linux ライブISO作成スクリプト
# 依存: archiso, yq (v4), git, arch-install-scripts
set -euo pipefail


WORKDIR="$PWD/work"
ISO_ROOT="$WORKDIR/iso"
AIROOTFS="$WORKDIR/airootfs"
ISO_NAME="frankos"
ISO_LABEL="FRANK_LIVE"
ISO_VERSION="$(date +%Y.%m.%d)"
OUTPUT="$PWD/out"
ARCH="i686"

echo "=========================================="
echo "FrankOS 32bit (i686) ISO Builder"
echo "=========================================="

# ===== 作業ディレクトリ初期化 =====
echo "[*] 作業ディレクトリを初期化..."
rm -rf "$WORKDIR" "$OUTPUT" mnt_esp/
mkdir -p "$AIROOTFS" "$ISO_ROOT" "$OUTPUT"

# ===== 32bit用 pacman.conf 作成 =====
echo "[*] 32bit用 pacman 設定を作成..."
mkdir -p "$AIROOTFS/etc/pacman.d"

cat <<'EOF' > "$AIROOTFS/etc/pacman.conf"
[options]
HoldPkg     = pacman glibc
Architecture = i686
CheckSpace
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

# 32bit Arch Linux リポジトリ（Arch32 / archlinux32.org）
[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[community]
Include = /etc/pacman.d/mirrorlist
EOF

# ===== 32bit用ミラーリスト作成 =====
cat <<'EOF' > "$AIROOTFS/etc/pacman.d/mirrorlist"
# Arch Linux 32bit ミラー
Server = https://mirror.archlinux32.org/$arch/$repo
Server = https://de.mirror.archlinux32.org/$arch/$repo
Server = https://uk.mirror.archlinux32.org/$arch/$repo
EOF

# ===== ベースシステム作成 =====
echo "[*] 32bit ベースシステムを pacstrap でインストール..."
AIROOTFS_IMG="$WORKDIR/airootfs.img"
AIROOTFS_MOUNT="$WORKDIR/airootfs"

# 8GB の空き容量を確保
truncate -s 8G "$AIROOTFS_IMG"
mkfs.ext4 -F "$AIROOTFS_IMG"

# マウント
mkdir -p "$AIROOTFS_MOUNT"
mount -o loop "$AIROOTFS_IMG" "$AIROOTFS_MOUNT"
AIROOTFS="$AIROOTFS_MOUNT"

# 32bit用 pacstrap 実行（Architecture指定）
# packages.conf があれば使用、なければ基本パッケージのみ
if [ -f packages.conf ]; then
    PACKAGES=$(grep -v '^#' packages.conf | tr '\n' ' ')
else
    PACKAGES="base linux linux-firmware networkmanager sudo vim nano"
fi

echo "[*] インストールパッケージ: $PACKAGES"

# pacstrap で32bitシステムをインストール
pacstrap -C "$AIROOTFS/etc/pacman.conf" -M "$AIROOTFS" $PACKAGES

# ===== 基本設定 =====
echo "[*] 基本設定を投入..."
echo "frankos" > "$AIROOTFS/etc/hostname"

cat <<'EOF' > "$AIROOTFS/etc/vconsole.conf"
KEYMAP=jp106
FONT=Lat2-Terminus16
EOF

cat <<'EOF' > "$AIROOTFS/etc/locale.gen"
en_US.UTF-8 UTF-8
ja_JP.UTF-8 UTF-8
EOF

# locale 生成
arch-chroot "$AIROOTFS" locale-gen
echo "LANG=en_US.UTF-8" > "$AIROOTFS/etc/locale.conf"

# ===== mkinitcpio 設定（32bit最適化） =====
echo "[*] mkinitcpio 設定..."
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/' \
    "$AIROOTFS/etc/mkinitcpio.conf"

# 32bit用の最小限モジュール
sed -i 's/^MODULES=.*/MODULES=(loop squashfs)/' "$AIROOTFS/etc/mkinitcpio.conf"

# initramfs 生成
arch-chroot "$AIROOTFS" mkinitcpio -P

# ===== pacman鍵の初期化 =====
echo "[*] pacman 鍵の初期化..."
arch-chroot "$AIROOTFS" pacman-key --init
arch-chroot "$AIROOTFS" pacman-key --populate archlinux32 || \
arch-chroot "$AIROOTFS" pacman-key --populate archlinux

# データベース更新
arch-chroot "$AIROOTFS" pacman -Sy --noconfirm || true

# ===== ユーザー設定 =====
echo "[*] ユーザー設定..."
# rootパスワード（デフォルト: root）
echo "root:root" | arch-chroot "$AIROOTFS" chpasswd

# liveユーザー作成
arch-chroot "$AIROOTFS" useradd -m -G wheel -s /bin/bash live || true
echo "live:live" | arch-chroot "$AIROOTFS" chpasswd

# sudoers 設定
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> "$AIROOTFS/etc/sudoers"

# ===== サービス有効化 =====
echo "[*] サービス有効化..."
arch-chroot "$AIROOTFS" systemctl enable NetworkManager || true

# 自動ログイン設定（オプション）
mkdir -p "$AIROOTFS/etc/systemd/system/getty@tty1.service.d"
cat <<'EOF' > "$AIROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf"
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin live %I $TERM
EOF

# ===== カスタムファイル =====
echo "[*] カスタムファイル追加..."
mkdir -p "$AIROOTFS/root"
cat <<'EOF' > "$AIROOTFS/root/README.txt"
Welcome to FrankOS 32bit Live!

This is a complete i686 (32-bit) Arch Linux-based live system.

Default credentials:
  root / root
  live / live

Enjoy!
EOF

# ===== squashfs 作成 =====
echo "[*] squashfs イメージ作成..."
mkdir -p "$ISO_ROOT/arch/$ARCH"
mksquashfs "$AIROOTFS" "$ISO_ROOT/arch/$ARCH/airootfs.sfs" -comp xz -b 1M

# ===== BIOS ブートローダー (SYSLINUX/ISOLINUX) =====
echo "[*] BIOS ブートローダー準備..."
mkdir -p "$ISO_ROOT/isolinux"

# 32bit用のsyslinuxバイナリをコピー
# システムに32bit版がない場合は、/usr/lib/syslinux/bios/ から
cp /usr/lib/syslinux/bios/isolinux.bin "$ISO_ROOT/isolinux/" || \
cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_ROOT/isolinux/"

cp /usr/lib/syslinux/bios/*.c32 "$ISO_ROOT/isolinux/" 2>/dev/null || true

# isolinux.cfg 作成
cat <<'EOF' > "$ISO_ROOT/isolinux/isolinux.cfg"
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT frankos

LABEL frankos
    MENU LABEL Boot FrankOS 32bit Live (BIOS)
    LINUX /arch/boot/i686/vmlinuz-linux
    INITRD /arch/boot/i686/initramfs-linux.img
    APPEND archisobasedir=arch archisolabel=FRANK_LIVE quiet splash
EOF

# ===== UEFI ブートローダー (32bit EFI) =====
echo "[*] 32bit UEFI ブートローダー準備..."
# 注意: 32bit UEFIは稀だが、対応させる場合
dd if=/dev/zero of="$ISO_ROOT/efiboot.img" bs=1M count=100
mkfs.vfat "$ISO_ROOT/efiboot.img"

mkdir -p mnt_esp
mount "$ISO_ROOT/efiboot.img" mnt_esp

mkdir -p mnt_esp/EFI/BOOT

# 32bit EFI ブートローダー（ia32）
# systemd-boot の32bit版、または grub-i386を使用
# ここではgrub-i386の例
if [ -f /usr/lib/grub/i386-efi/grubia32.efi ]; then
    cp /usr/lib/grub/i386-efi/grubia32.efi mnt_esp/EFI/BOOT/BOOTIA32.EFI
fi

# カーネルとinitramfsをコピー
mkdir -p mnt_esp/arch/boot/i686
cp "$AIROOTFS/boot/vmlinuz-linux" mnt_esp/arch/boot/i686/
cp "$AIROOTFS/boot/initramfs-linux.img" mnt_esp/arch/boot/i686/

umount mnt_esp
rmdir mnt_esp

# ===== カーネルとinitramfsをISOルートに配置 =====
mkdir -p "$ISO_ROOT/arch/boot/$ARCH"
cp "$AIROOTFS/boot/vmlinuz-linux" "$ISO_ROOT/arch/boot/$ARCH/"
cp "$AIROOTFS/boot/initramfs-linux.img" "$ISO_ROOT/arch/boot/$ARCH/"

# ===== airootfs アンマウント =====
echo "[*] airootfs をアンマウント..."
umount -l "$AIROOTFS_MOUNT" || umount "$AIROOTFS_MOUNT"
losetup -D 2>/dev/null || true

# ===== ISO イメージ生成 =====
echo "[*] ISO イメージ生成中..."
xorriso -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -volid "$ISO_LABEL" \
  -appid "FrankOS 32bit Live" \
  -publisher "FrankOS Project" \
  -preparer "build.sh" \
  -eltorito-boot isolinux/isolinux.bin \
  -eltorito-catalog isolinux/boot.cat \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  -eltorito-alt-boot \
  -e efiboot.img \
  -no-emul-boot \
  -isohybrid-mbr /usr/lib/syslinux/bios/isohdpfx.bin \
  -isohybrid-gpt-basdat \
  -output "${OUTPUT}/${ISO_NAME}-${ISO_VERSION}-${ARCH}.iso" \
  "$ISO_ROOT"

echo "=========================================="
echo "[✓] 完了!"
echo "出力: ${OUTPUT}/${ISO_NAME}-${ISO_VERSION}-${ARCH}.iso"
echo "=========================================="
echo ""
echo "テスト方法:"
echo "  qemu-system-i386 -m 2048 -cdrom ${OUTPUT}/${ISO_NAME}-${ISO_VERSION}-${ARCH}.iso"
echo ""
