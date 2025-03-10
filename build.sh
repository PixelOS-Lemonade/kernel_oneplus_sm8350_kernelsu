#!/bin/sh

SUSFS=false
WIREGUARD=false
SCOPED_HOOK=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --with-susfs)
      SUSFS=true
      shift # past argument
      ;;
    --scoped-hook)
      SCOPED_HOOK=true
      shift # past argument
      ;;
    --wireguard)
      WIREGUARD=true
      shift # past argument
      ;;
  esac
done

BASE_PATH=$(pwd)
export KBUILD_BUILD_HOST=github
export KBUILD_BUILD_USER=github
export ARCH=arm64
echo ">${BASE_PATH}"

# system
echo ">install tools"
sudo apt update -y 
sudo apt install -y elfutils libarchive-tools

#libufdt
echo ">clone libufdt"
git clone --branch android14-qpr2-release --depth 1 "https://android.googlesource.com/platform/system/libufdt.git" libufdt 

#AnyKernel3
echo ">clone AnyKernel3"
git clone --depth 1 https://github.com/osm0sis/AnyKernel3  AnyKernel3

# toolchain
echo ">download toolchain"
mkdir toolchain
cd toolchain
curl -LO "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman"
chmod +x ./antman
./antman -S
./antman --patch=glibc
cd $BASE_PATH

#kernel
echo ">clone kernel source"
git clone --depth 1 https://github.com/PixelOS-Lemonade/kernel_oneplus_sm8350 kernel

#Scoped Hook
if [[ $SCOPED_HOOK == "true" ]]; then
  echo ">download scoped hook patchset and patch the kernel"
  curl -LO "https://github.com/dev-sm8350/kernel_oneplus_sm8350/commit/583337f3cbfad72ad3a4109953b45a067bccd5be.patch"
  cd kernel
  git apply ../583337f3cbfad72ad3a4109953b45a067bccd5be.patch
  cd $BASE_PATH
fi

#KernelSU
echo ">clone KernelSU and patch the kernel"
cd kernel
curl -LSs "https://raw.githubusercontent.com/rsuntk/KernelSU/main/kernel/setup.sh" | bash -s v1.0.3-10-legacy
git apply ../0001-backport-path-umount.patch
git apply ../0002-backport-strncpy-from-user-nofault.patch
git apply ../0003-no-dirty-flag.patch
cd $BASE_PATH

#SUSFS
if [[ $SUSFS == "true" ]]; then
  echo ">clone SUSFS and patch the kernel"
  git clone --branch kernel-5.4 --depth 1 https://gitlab.com/simonpunk/susfs4ksu susfs

  # Original patch does not fit lemonade kernel. We include additonal patches
  # to patch the patch files fiest
  cd susfs
  patch -p1 < ../0004-patch_enable_susfs_for_ksu.patch
  patch -p1 < ../0005-patch_add_susfs_in_kernel-5.4.patch
  cd $BASE_PATH

  # Include susfs. Copied from https://gitlab.com/simonpunk/susfs4ksu/-/blob/kernel-5.4/README.md
  cp susfs/kernel_patches/fs/* kernel/fs/
  cp susfs/kernel_patches/include/linux/* kernel/include/linux/
  cd kernel/KernelSU
  patch -p1 < ../../susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch
  cd ../
  patch -p1 < ../susfs/kernel_patches/50_add_susfs_in_kernel-5.4.patch
  echo "CONFIG_KSU=y" >> arch/arm64/configs/vendor/lahaina-qgki_defconfig
  echo "CONFIG_KSU_SUSFS=y" >> arch/arm64/configs/vendor/lahaina-qgki_defconfig
  echo "CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y" >> arch/arm64/configs/vendor/lahaina-qgki_defconfig
  echo "CONFIG_KSU_SUSFS_SUS_SU=n" >> arch/arm64/configs/vendor/lahaina-qgki_defconfig
  cd $BASE_PATH
fi

#WireGuard
if [[ $WIREGUARD == "true" ]]; then
  echo ">clone WireGuard and patch the kernel"
  git clone --branch v1.0.20220627 --depth 1 https://git.zx2c4.com/wireguard-linux-compat wireguard
  mv wireguard/src kernel/net/wireguard
  cd kernel
  sed -i '94i source "net/wireguard/Kconfig"' net/Kconfig
  sed -i '18i obj-$(CONFIG_WIREGUARD)		+= wireguard/' net/Makefile
  echo "CONFIG_WIREGUARD=y" >> arch/arm64/configs/vendor/lahaina-qgki_defconfig
  cd $BASE_PATH
fi

#build
echo ">build kernel"
cd kernel
export PATH="$BASE_PATH/toolchain/bin:${PATH}"
MAKE_ARGS="CC=clang O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 CFLAGS=-Wno-enum-compare"
make $MAKE_ARGS "vendor/lahaina-qgki_defconfig"
make $MAKE_ARGS -j"$(nproc --all)"
cd $BASE_PATH
cp kernel/out/arch/arm64/boot/Image AnyKernel3/

#create dtb
echo ">create dtb and dtbo.img"
cat $(find kernel/out/arch/arm64/boot/dts/vendor/oplus/lemonadev/ -type f -name "*.dtb" | sort) > AnyKernel3/dtb
python libufdt/utils/src/mkdtboimg.py create AnyKernel3/dtbo.img --page_size=4096 $(find kernel/out/arch/arm64/boot/dts/vendor/oplus/lemonadev/ -type f -name "*.dtbo" | sort)

#clean AnyKernel3
echo ">clean AnyKernel3"
rm -rf AnyKernel3/.git* AnyKernel3/README.md
echo "lineageOS oneplus sm8350 kernel with KernelSU" > AnyKernel3/README.md
sed -i 's/do.devicecheck=1/do.devicecheck=0/g' AnyKernel3/anykernel.sh
sed -i 's!BLOCK=/dev/block/platform/omap/omap_hsmmc.0/by-name/boot;!BLOCK=auto;!g' AnyKernel3/anykernel.sh
sed -i 's/IS_SLOT_DEVICE=0;/IS_SLOT_DEVICE=auto;/g' AnyKernel3/anykernel.sh
