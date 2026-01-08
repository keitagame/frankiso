#!/bin/bash
# Axiom Linux - Custom Distribution Build Script
# ArchLinuxベースの独自ディストリビューション

set -euo pipefail

# カラー出力
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# 設定
DISTRO_NAME="Axiom Linux"
DISTRO_VERSION="1.0"
DISTRO_CODENAME="Genesis"
BUILD_DIR="$(pwd)/axiom-build"
WORK_DIR="${BUILD_DIR}/work"
OUT_DIR="${BUILD_DIR}/out"
ISO_LABEL="AXIOM_$(date +%Y%m)"

# root権限チェック
if [[ $EUID -ne 0 ]]; then
   log_error "このスクリプトはroot権限で実行する必要があります"
   exit 1
fi

# 必要なパッケージの確認
check_dependencies() {
    log_info "依存関係を確認中..."
    local deps=(arch-install-scripts squashfs-tools dosfstools xorriso mtools)
    for dep in "${deps[@]}"; do
        if ! pacman -Q "$dep" &>/dev/null; then
            log_warn "$dep がインストールされていません。インストール中..."
            pacman -S --noconfirm "$dep"
        fi
    done
    log_success "依存関係の確認完了"
}

# ディレクトリ構造の作成
setup_directories() {
    log_info "ディレクトリ構造を作成中..."
    rm -rf "${BUILD_DIR}"
    mkdir -p "${WORK_DIR}"/{airootfs,iso/{boot,EFI/boot}}
    mkdir -p "${OUT_DIR}"
    log_success "ディレクトリ構造作成完了"
}

# ベースシステムのインストール
install_base_system() {
    log_info "ベースシステムをインストール中..."
    
    # 基本パッケージリスト
    local base_packages=(
        base linux linux-firmware archiso
        networkmanager sudo
        nano vim
        grub efibootmgr os-prober
        bash-completion
    )
    
    # デスクトップ環境（GNOME）
    local desktop_packages=(
        gnome gnome-extra
        gdm
        xorg xorg-server
        mesa
    )
    
    # システムツール
    local system_packages=(
        parted
        gparted
        gptfdisk
    )
    
    # 追加ユーティリティ
    local utility_packages=(
        firefox
        git
        wget curl
        htop
        fastfetch
        base-devel
    )
    
    # pacstrapでインストール
    pacstrap -c "${WORK_DIR}/airootfs" \
        "${base_packages[@]}" \
        "${desktop_packages[@]}" \
        "${system_packages[@]}" \
        "${utility_packages[@]}"
    
    log_success "ベースシステムのインストール完了"
}

# AURヘルパー（yay）とCalamaresのインストール
install_aur_packages() {
    log_info "AURパッケージをインストール中..."
    
    # 必要なマウント
    mount --bind /dev "${WORK_DIR}/airootfs/dev"
    mount --bind /proc "${WORK_DIR}/airootfs/proc"
    mount --bind /sys "${WORK_DIR}/airootfs/sys"
    
    # resolv.confのコピー
    cp -L /etc/resolv.conf "${WORK_DIR}/airootfs/etc/resolv.conf"
    
    # chrootで一時的にsudoユーザーを作成
    arch-chroot "${WORK_DIR}/airootfs" useradd -m -G wheel builder
    arch-chroot "${WORK_DIR}/airootfs" bash -c "echo 'builder ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder"
    chmod 440 "${WORK_DIR}/airootfs/etc/sudoers.d/builder"
    
    # pacman鍵の初期化
    arch-chroot "${WORK_DIR}/airootfs" pacman-key --init
    arch-chroot "${WORK_DIR}/airootfs" pacman-key --populate archlinux
    
    # yayのインストール
    arch-chroot "${WORK_DIR}/airootfs" su - builder -c "
        set -e
        cd /tmp
        git clone https://aur.archlinux.org/yay-bin.git
        cd yay-bin
        makepkg -si --noconfirm
    "
    
    # Calamaresのインストール（AURから）
    log_info "Calamaresをインストール中（時間がかかります）..."
    arch-chroot "${WORK_DIR}/airootfs" su - builder -c "
        yay -S --noconfirm calamares
    "
    
    # ビルダーユーザーを削除
    arch-chroot "${WORK_DIR}/airootfs" userdel -r builder
    rm -f "${WORK_DIR}/airootfs/etc/sudoers.d/builder"
    
    # マウント解除
    umount "${WORK_DIR}/airootfs/dev" || true
    umount "${WORK_DIR}/airootfs/proc" || true
    umount "${WORK_DIR}/airootfs/sys" || true
    
    log_success "AURパッケージのインストール完了"
}
    
# システム設定
configure_system() {
    log_info "システムを設定中..."
    # archiso hook をホストからコピー（必須）

mount --bind /dev  "${WORK_DIR}/airootfs/dev"
    mount --bind /proc "${WORK_DIR}/airootfs/proc"
    mount --bind /sys  "${WORK_DIR}/airootfs/sys"
    cat > "${WORK_DIR}/airootfs/etc/mkinitcpio.conf" <<'EOF'
MODULES=(loop squashfs overlay)
BINARIES=()
FILES=()
HOOKS=(base udev block filesystems keyboard)
COMPRESSION="zstd"
EOF
cat > "${WORK_DIR}/airootfs/etc/mkinitcpio.d/archiso.preset" <<'EOF'
PRESETS=('archiso')

archiso_config="/etc/mkinitcpio.conf"
archiso_image="/boot/initramfs-linux.img"
archiso_kver="/boot/vmlinuz-linux"
EOF

    arch-chroot "${WORK_DIR}/airootfs" mkinitcpio -P
    # pacman.confとmirrorsのコピー
    cp /etc/pacman.conf "${WORK_DIR}/airootfs/etc/pacman.conf"
    cp /etc/pacman.d/mirrorlist "${WORK_DIR}/airootfs/etc/pacman.d/mirrorlist"
    
    # pacmanキャッシュディレクトリ
    mkdir -p "${WORK_DIR}/airootfs/var/cache/pacman/pkg"
    # ホスト名設定
    echo "axiom-live" > "${WORK_DIR}/airootfs/etc/hostname"
    
    # ロケール設定
    cat > "${WORK_DIR}/airootfs/etc/locale.gen" <<EOF
en_US.UTF-8 UTF-8
EOF
    
    echo "LANG=ja_JP.UTF-8" > "${WORK_DIR}/airootfs/etc/locale.conf"
    
    # タイムゾーン
    arch-chroot "${WORK_DIR}/airootfs" ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
    
    # ロケール生成
    arch-chroot "${WORK_DIR}/airootfs" locale-gen
    
    # NetworkManager有効化
    arch-chroot "${WORK_DIR}/airootfs" systemctl enable NetworkManager
    arch-chroot "${WORK_DIR}/airootfs" systemctl enable gdm
    umount "${WORK_DIR}/airootfs/dev"
    umount "${WORK_DIR}/airootfs/proc"
    umount "${WORK_DIR}/airootfs/sys"
    log_success "システム設定完了"
}

# ダークモード＆丸アイコンのカスタマイズ
customize_desktop() {
    log_info "デスクトップをカスタマイズ中..."
    
    # GNOMEダークモード設定スクリプト
    cat > "${WORK_DIR}/airootfs/usr/local/bin/axiom-setup-desktop" <<'EOF'
#!/bin/bash
# Axiom Linux デスクトップセットアップ

# ダークモードを有効化
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'

# 丸アイコンテーマ（Papirus-Darkをインストール）
if ! pacman -Q papirus-icon-theme &>/dev/null; then
    sudo pacman -S --noconfirm papirus-icon-theme
fi
gsettings set org.gnome.desktop.interface icon-theme 'Papirus-Dark'

# フォント設定
gsettings set org.gnome.desktop.interface font-name 'Noto Sans CJK JP 11'
gsettings set org.gnome.desktop.interface document-font-name 'Noto Sans CJK JP 11'
gsettings set org.gnome.desktop.interface monospace-font-name 'Noto Sans Mono CJK JP 10'

# アニメーション有効化
gsettings set org.gnome.desktop.interface enable-animations true

# 壁紙設定
gsettings set org.gnome.desktop.background picture-uri 'file:///usr/share/backgrounds/axiom-wallpaper.jpg'
gsettings set org.gnome.desktop.background picture-uri-dark 'file:///usr/share/backgrounds/axiom-wallpaper.jpg'

echo "Axiom Desktop setup complete!"
EOF
    chmod +x "${WORK_DIR}/airootfs/usr/local/bin/axiom-setup-desktop"
    
    # Papirus丸アイコンテーマをインストール
    arch-chroot "${WORK_DIR}/airootfs" pacman -S --noconfirm papirus-icon-theme
    
    # デフォルトGDM設定
    mkdir -p "${WORK_DIR}/airootfs/etc/dconf/db/gdm.d"
    cat > "${WORK_DIR}/airootfs/etc/dconf/db/gdm.d/01-axiom" <<EOF
[org/gnome/desktop/interface]
gtk-theme='Adwaita-dark'
icon-theme='Papirus-Dark'
cursor-theme='Adwaita'
EOF
    
    arch-chroot "${WORK_DIR}/airootfs" dconf update
    
    log_success "デスクトップカスタマイズ完了"
}

# Calamaresインストーラー設定
configure_calamares() {
    log_info "Calamaresインストーラーを設定中..."
    
    mkdir -p "${WORK_DIR}/airootfs/etc/calamares"
    
    # Calamares設定ファイル
    cat > "${WORK_DIR}/airootfs/etc/calamares/settings.conf" <<EOF
---
modules-search: [ local ]

instances:
- id: before
  module: shellprocess
  config: shellprocess_before.conf

sequence:
- show:
  - welcome
  - locale
  - keyboard
  - partition
  - users
  - summary
- exec:
  - partition
  - mount
  - unpackfs
  - machineid
  - fstab
  - locale
  - keyboard
  - localecfg
  - users
  - networkcfg
  - hwclock
  - services-systemd
  - bootloader
  - umount
- show:
  - finished

branding: axiom

prompt-install: true
dont-chroot: false
EOF

    # Branding設定
    mkdir -p "${WORK_DIR}/airootfs/etc/calamares/branding/axiom"
    cat > "${WORK_DIR}/airootfs/etc/calamares/branding/axiom/branding.desc" <<EOF
---
componentName: axiom

strings:
    productName:         "${DISTRO_NAME}"
    version:             "${DISTRO_VERSION}"
    shortVersion:        "${DISTRO_VERSION}"
    versionedName:       "${DISTRO_NAME} ${DISTRO_VERSION}"
    shortVersionedName:  "Axiom ${DISTRO_VERSION}"
    bootloaderEntryName: "Axiom"
    productUrl:          "https://axiom-linux.org"
    supportUrl:          "https://axiom-linux.org/support"

images:
    productLogo:         "logo.png"
    productIcon:         "logo.png"

slideshow:              "show.qml"

style:
   sidebarBackground:    "#2c2c2c"
   sidebarText:          "#ffffff"
   sidebarTextSelect:    "#4a90d9"
EOF
    
    log_success "Calamaresインストーラー設定完了"
}

# Liveユーザー作成
create_live_user() {
    log_info "Liveユーザーを作成中..."
    
    arch-chroot "${WORK_DIR}/airootfs" useradd -m -G wheel -s /bin/bash axiom
    arch-chroot "${WORK_DIR}/airootfs" bash -c "echo 'axiom:axiom' | chpasswd"
    
    # sudoers設定
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > "${WORK_DIR}/airootfs/etc/sudoers.d/wheel"
    chmod 440 "${WORK_DIR}/airootfs/etc/sudoers.d/wheel"
    
    # GDM自動ログイン設定
    mkdir -p "${WORK_DIR}/airootfs/etc/gdm"
    cat > "${WORK_DIR}/airootfs/etc/gdm/custom.conf" <<EOF
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=axiom
EOF
    
    log_success "Liveユーザー作成完了"
}

# SquashFS作成
create_squashfs() {
    log_info "SquashFSファイルシステムを作成中..."
    
    mksquashfs "${WORK_DIR}/airootfs" \
        "${WORK_DIR}/iso/arch/x86_64/axiom.sfs" \
        -comp xz -b 1M -Xdict-size 100%
    
    log_success "SquashFS作成完了"
}

# ブートローダー設定
setup_bootloader() {
    log_info "ブートローダーを設定中..."
    mkdir -p "${WORK_DIR}/iso/arch/x86_64/grub"
    # GRUB設定
    cat > "${WORK_DIR}/iso/arch/x86_64/grub/grub.cfg" <<EOF
set timeout=10
set default=0

menuentry "${DISTRO_NAME} ${DISTRO_VERSION} (x86_64)" {
    linux /arch/x86_64/vmlinuz-linux archisobasedir=arch archisolabel=${ISO_LABEL} quiet splash
    initrd /arch/x86_64/initramfs-linux.img
}

menuentry "${DISTRO_NAME} ${DISTRO_VERSION} (x86_64, Safe Mode)" {
    linux /arch/x86_64/vmlinuz-linux archisobasedir=arch archisolabel=${ISO_LABEL} nomodeset
    initrd /arch/x86_64/initramfs-linux.img
}
EOF
    
    # カーネルとinitramfsをコピー
    cp "${WORK_DIR}/airootfs/boot/vmlinuz-linux" "${WORK_DIR}/iso/arch/x86_64"
    cp "${WORK_DIR}/airootfs/boot/initramfs-linux.img" "${WORK_DIR}/iso/arch/x86_64"
   

    # EFI設定
    mkdir -p "${WORK_DIR}/iso/EFI/boot"
    grub-mkstandalone \
        -d /usr/lib/grub/x86_64-efi \
        -O x86_64-efi \
        --modules="part_gpt part_msdos" \
        --fonts="unicode" \
        -o "${WORK_DIR}/iso/EFI/boot/bootx64.efi" \
        "boot/grub/grub.cfg=${WORK_DIR}/iso/arch/x86_64/grub/grub.cfg"
    
    log_success "ブートローダー設定完了"
}

# ISO作成
create_iso() {
    log_info "ISOイメージを作成中..."
    
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "${ISO_LABEL}" \
        -eltorito-boot boot/grub/bios.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --eltorito-catalog boot/grub/boot.cat \
        --grub2-boot-info \
        --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
        -eltorito-alt-boot \
        -e EFI/boot/bootx64.efi \
        -no-emul-boot \
        -append_partition 2 0xef "${WORK_DIR}/iso/EFI/boot/bootx64.efi" \
        -output "${OUT_DIR}/axiom-${DISTRO_VERSION}-x86_64.iso" \
        "${WORK_DIR}/iso"
    
    log_success "ISO作成完了: ${OUT_DIR}/axiom-${DISTRO_VERSION}-x86_64.iso"
}

# メイン実行
main() {
    log_info "=== ${DISTRO_NAME} ${DISTRO_VERSION} ビルド開始 ==="
    
    check_dependencies
    setup_directories
    install_base_system
    configure_system
    install_aur_packages
    customize_desktop
    configure_calamares
    create_live_user
    create_squashfs
    setup_bootloader
    create_iso
    
    log_success "=== ビルド完了 ==="
    log_info "ISOファイル: ${OUT_DIR}/axiom-${DISTRO_VERSION}-x86_64.iso"
    log_info "USBに書き込むには: dd if=${OUT_DIR}/axiom-${DISTRO_VERSION}-x86_64.iso of=/dev/sdX bs=4M status=progress"
}

main "$@"