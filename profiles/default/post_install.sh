#!/usr/bin/env bash
set -euo pipefail

# タイムゾーン設定
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
hwclock --systohc

# ロケール生成
echo "ja_JP.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=ja_JP.UTF-8" > /etc/locale.conf

# ホスト名設定
echo "keita" > /etc/hostname

# root パスワード設定（デフォルト: archlinux）
echo "root:archlinux" | chpasswd

# モチベーションメッセージ
echo "Welcome to Keita Linux" > /etc/motd
