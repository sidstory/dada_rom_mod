#!/bin/bash

sudo timedatectl set-timezone Asia/Shanghai
sudo apt-get remove -y firefox zstd
sudo apt-get install python3 aria2

VENDOR_SOURCE="$1"    # 底包下载地址或本地路径
GITHUB_ENV="$2"       # 输出环境变量
GITHUB_WORKSPACE="$3" # 工作目录

device=dada # 设备代号

Red='\033[1;31m'    # 粗体红色
Yellow='\033[1;33m' # 粗体黄色
Blue='\033[1;34m'   # 粗体蓝色
Green='\033[1;32m'  # 粗体绿色

vendor_zip_name=$(basename "${VENDOR_SOURCE%%\?*}")                                          # 底包的 zip 名称, 例: dada-ota_full-OS4.0.0.7.XOCCNXM-user-17.0-832125be27.zip
vendor_os_version=$(echo "$vendor_zip_name" | grep -oE "OS[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[A-Z]+") # 底包的 OS 版本号, 例: OS4.0.0.7.UNCCNXM
android_version=$(echo "$vendor_zip_name" | sed -E 's/.*-([0-9]+)\.[0-9]+-[^-]+\.zip/\1/') # Android 版本号, 例: 17
build_time=$(date)                                                                           # 构建时间

sudo chmod -R 777 "$GITHUB_WORKSPACE"/tools
magiskboot="$GITHUB_WORKSPACE"/tools/magiskboot
ksud="$GITHUB_WORKSPACE"/tools/ksud
a7z="$GITHUB_WORKSPACE"/tools/7zzs
zstd="$GITHUB_WORKSPACE"/tools/zstd
payload_extract="$GITHUB_WORKSPACE"/tools/payload_extract
erofs_extract="$GITHUB_WORKSPACE"/tools/extract.erofs
erofs_mkfs="$GITHUB_WORKSPACE"/tools/mkfs.erofs
lpmake="$GITHUB_WORKSPACE"/tools/lpmake

Start_Time() {
  Start_s=$(date +%s)
  Start_ns=$(date +%N)
}

End_Time() {
  local End_s End_ns time_s time_ns
  End_s=$(date +%s)
  End_ns=$(date +%N)
  time_s=$((10#$End_s - 10#$Start_s))
  time_ns=$((10#$End_ns - 10#$Start_ns))
  if ((time_ns < 0)); then
    ((time_s--))
    ((time_ns += 1000000000))
  fi

  local ns ms sec min hour
  ns=$((time_ns % 1000000))
  ms=$((time_ns / 1000000))
  sec=$((time_s % 60))
  min=$((time_s / 60 % 60))
  hour=$((time_s / 3600))

  if ((hour > 0)); then
    echo -e "${Green}- 本次$1用时: ${Blue}$hour小时$min分$sec秒$ms毫秒"
  elif ((min > 0)); then
    echo -e "${Green}- 本次$1用时: ${Blue}$min分$sec秒$ms毫秒"
  elif ((sec > 0)); then
    echo -e "${Green}- 本次$1用时: ${Blue}$sec秒$ms毫秒"
  elif ((ms > 0)); then
    echo -e "${Green}- 本次$1用时: ${Blue}$ms毫秒"
  else
    echo -e "${Green}- 本次$1用时: ${Blue}$ns纳秒"
  fi
}

### 底包下载
echo -e "${Red}- 开始下载底包"
Start_Time
if [[ "$VENDOR_SOURCE" == http* ]]; then
  echo -e "${Yellow}- 检测到 URL, 开始下载底包"
  aria2c -x16 -j$(nproc) -U "Mozilla/5.0" -d "$GITHUB_WORKSPACE" "$VENDOR_SOURCE"
else
  echo -e "${Yellow}- 检测到本地路径, 开始复制底包"
  cp -f "$VENDOR_SOURCE" "$GITHUB_WORKSPACE/${vendor_zip_name}"
fi
End_Time 下载底包
### 底包下载结束

### 解包
echo -e "${Red}- 开始解压底包"
mkdir -p "$GITHUB_WORKSPACE"/Extra_dir
mkdir -p "$GITHUB_WORKSPACE"/images/config
mkdir -p "$GITHUB_WORKSPACE"/zip

echo -e "${Yellow}- 开始解压底包 zip"
Start_Time
$a7z x "$GITHUB_WORKSPACE"/${vendor_zip_name} -o"$GITHUB_WORKSPACE"/"${device}" payload.bin >/dev/null
rm -rf "$GITHUB_WORKSPACE"/${vendor_zip_name}
End_Time 解压底包

echo -e "${Red}- 开始解底包payload (固件镜像)"
$payload_extract -s -o "$GITHUB_WORKSPACE"/Extra_dir/ -i "$GITHUB_WORKSPACE"/"${device}"/payload.bin -X system,system_ext,product -e -T0
echo -e "${Red}- 开始解底包payload (动态分区镜像)"
$payload_extract -s -o "$GITHUB_WORKSPACE"/images/ -i "$GITHUB_WORKSPACE"/"${device}"/payload.bin -X product,system,system_ext -T0
sudo rm -rf "$GITHUB_WORKSPACE"/"${device}"
# 未修改的动态分区镜像直接用于打包
for i in mi_ext odm system_dlkm vendor_dlkm; do
  mv -f "$GITHUB_WORKSPACE"/Extra_dir/$i.img "$GITHUB_WORKSPACE"/images/
done
# 分解需要修改的分区
echo -e "${Red}- 开始分解 vendor.img"
cd "$GITHUB_WORKSPACE"/images
sudo $erofs_extract -s -i "$GITHUB_WORKSPACE"/Extra_dir/vendor.img -x
rm -rf "$GITHUB_WORKSPACE"/Extra_dir/vendor.img
echo -e "${Red}- 开始分解 product.img"
sudo $erofs_extract -s -i "$GITHUB_WORKSPACE"/images/product.img -x
rm -rf "$GITHUB_WORKSPACE"/images/product.img
# 固件镜像放入 firmware-update
echo -e "${Red}- 整理固件镜像"
mkdir -p "$GITHUB_WORKSPACE"/images/firmware-update
sudo mv -f "$GITHUB_WORKSPACE"/Extra_dir/* "$GITHUB_WORKSPACE"/images/firmware-update/
sudo rm -rf "$GITHUB_WORKSPACE"/Extra_dir
### 解包结束

### 写入变量
echo -e "${Red}- 开始写入变量"
echo "build_time=$build_time" >>$GITHUB_ENV
echo -e "${Blue}- 构建日期: $build_time"
echo "vendor_os_version=$vendor_os_version" >>$GITHUB_ENV
echo -e "${Blue}- 底包版本: $vendor_os_version"
echo "android_version=$android_version" >>$GITHUB_ENV
echo -e "${Blue}- Android 版本: $android_version"
### 写入变量结束

### 功能修复
echo -e "${Red}- 开始功能修复"
Start_Time
# 添加 KernelSU 支持 (可选择, 设置 KSU=false 跳过)
if [ "$KSU" != "false" ]; then
  echo -e "${Red}- 添加 KernelSU 支持"
  mkdir -p "$GITHUB_WORKSPACE"/init_boot
  cd "$GITHUB_WORKSPACE"/init_boot
  cp -f "$GITHUB_WORKSPACE"/images/firmware-update/init_boot.img "$GITHUB_WORKSPACE"/init_boot
  $ksud boot-patch -b "$GITHUB_WORKSPACE"/init_boot/init_boot.img --magiskboot $magiskboot --kmi android15-6.6
  mv -f "$GITHUB_WORKSPACE"/init_boot/kernelsu_*.img "$GITHUB_WORKSPACE"/images/firmware-update/init_boot-kernelsu.img
  rm -rf "$GITHUB_WORKSPACE"/init_boot
else
  echo -e "${Yellow}- 已跳过 KernelSU"
fi
# 替换 vendor_boot 的 fstab
echo -e "${Red}- 替换 Vendor Boot 的 fstab"
mkdir -p "$GITHUB_WORKSPACE"/vendor_boot
cd "$GITHUB_WORKSPACE"/vendor_boot
mv -f "$GITHUB_WORKSPACE"/images/firmware-update/vendor_boot.img "$GITHUB_WORKSPACE"/vendor_boot
$magiskboot unpack -h "$GITHUB_WORKSPACE"/vendor_boot/vendor_boot.img 2>&1
echo -e "${Yellow}- vendor_boot 解包产物: $(ls -A)"
# 兼容新旧 magiskboot: 新版(v27+)对 vendor_boot v4 会把 ramdisk 解包到 vendor_ramdisk/ 目录
# (表项名为空时为 vendor_ramdisk/ramdisk.cpio, 且已自动解压); 旧版则是单个文件 vendor_ramdisk 或 ramdisk.cpio
rd_file=ramdisk.cpio
[ -f vendor_ramdisk/ramdisk.cpio ] && rd_file=vendor_ramdisk/ramdisk.cpio
[ -f vendor_ramdisk ] && rd_file=vendor_ramdisk
if [ ! -f "$rd_file" ]; then
  echo "::error::vendor_boot 解包失败, 未找到 ramdisk.cpio"
  exit 1
fi
echo -e "${Yellow}- vendor ramdisk 文件: $rd_file"
comp=$($magiskboot decompress "$rd_file" 2>&1 | grep -v 'raw' | sed -n 's;.*\[\(.*\)\];\1;p')
if [ "$comp" ]; then
  mv -f "$rd_file" "$rd_file.$comp"
  $magiskboot decompress "$rd_file.$comp" "$rd_file" 2>&1
  if [ $? != 0 ] && $comp --help 2>/dev/null; then
    $comp -dc "$rd_file.$comp" >"$rd_file"
  fi
fi
mkdir -p ramdisk
chmod 755 ramdisk
(cd ramdisk && EXTRACT_UNSAFE_SYMLINKS=1 cpio -d -F "../$rd_file" -i 2>&1)
mkdir -p ramdisk/first_stage_ramdisk
sudo cp -f "$GITHUB_WORKSPACE"/"${device}"_files/fstab.qcom "$GITHUB_WORKSPACE"/vendor_boot/ramdisk/first_stage_ramdisk/fstab.qcom
sudo chmod 644 "$GITHUB_WORKSPACE"/vendor_boot/ramdisk/first_stage_ramdisk/fstab.qcom
(cd ramdisk && find . | sed 1d | cpio -H newc -R 0:0 -o -F ../ramdisk_new.cpio 2>&1)
rm -f "$rd_file"
mv -f ramdisk_new.cpio "$rd_file"
case $comp in
cpio) nocompflag="-n" ;;
esac
$magiskboot repack $nocompflag "$GITHUB_WORKSPACE"/vendor_boot/vendor_boot.img "$GITHUB_WORKSPACE"/images/firmware-update/vendor_boot.img 2>&1
if [ ! -s "$GITHUB_WORKSPACE"/images/firmware-update/vendor_boot.img ]; then
  echo "::error::vendor_boot repack 失败, 未生成有效镜像"
  exit 1
fi
sudo rm -rf "$GITHUB_WORKSPACE"/vendor_boot
# 替换 vendor 的 fstab
echo -e "${Red}- 替换 vendor 的 fstab"
sudo cp -f "$GITHUB_WORKSPACE"/"${device}"_files/fstab.qcom "$GITHUB_WORKSPACE"/images/vendor/etc/fstab.qcom
# 替换 recovery 镜像
echo -e "${Red}- 替换 Recovery 镜像"
sudo cp -f "$GITHUB_WORKSPACE"/"${device}"_files/recovery.img "$GITHUB_WORKSPACE"/images/firmware-update/recovery.img
# 占位广告应用
echo -e "${Red}- 占位广告应用"
sudo rm -rf "$GITHUB_WORKSPACE"/images/product/app/MSA/*
sudo mkdir -p "$GITHUB_WORKSPACE"/images/product/app/MSA
sudo cp -f "$GITHUB_WORKSPACE"/"${device}"_files/MSA.apk "$GITHUB_WORKSPACE"/images/product/app/MSA
# 精简部分应用
echo -e "${Red}- 精简部分应用"
apps=("MIUIDriveMode" "MIUIDuokanReader" "MIUIGameCenter" "MIUINewHome" "MIUIYoupin" "MIUIHuanJi" "MIUIMiDrive" "MIUIVirtualSim" "ThirdAppAssistant" "XMRemoteController" "MIUIVipAccount" "Xinre" "SmartHome" "MiShop" "MiRadio" "BaiduIME" "iflytek.inputmethod" "MIService" "MIUIEmail" "MIUIVideo" "MIUIMusicT")
for app in "${apps[@]}"; do
  appsui=$(sudo find "$GITHUB_WORKSPACE"/images/product/data-app/ -type d -iname "*${app}*")
  if [[ -n $appsui ]]; then
    echo -e "${Yellow}- 找到精简目录: $appsui"
    sudo rm -rf "$appsui"
  fi
done
# 添加刷机脚本
echo -e "${Red}- 添加刷机脚本"
sudo unzip -o -q "$GITHUB_WORKSPACE"/tools/flashtools.zip -d "$GITHUB_WORKSPACE"/images
End_Time 功能修复
### 功能修复结束

### 生成 super.img
echo -e "${Red}- 开始打包super.img"
Start_Time
# 重新打包修改过的分区
for partition in product vendor; do
  echo -e "${Red}- 正在生成: $partition"
  sudo python3 "$GITHUB_WORKSPACE"/tools/fspatch.py "$GITHUB_WORKSPACE"/images/$partition "$GITHUB_WORKSPACE"/images/config/"$partition"_fs_config
  sudo python3 "$GITHUB_WORKSPACE"/tools/contextpatch.py "$GITHUB_WORKSPACE"/images/$partition "$GITHUB_WORKSPACE"/images/config/"$partition"_file_contexts
  sudo $erofs_mkfs --quiet -zlz4hc,9 -T 1230768000 --mount-point /$partition --fs-config-file "$GITHUB_WORKSPACE"/images/config/"$partition"_fs_config --file-contexts "$GITHUB_WORKSPACE"/images/config/"$partition"_file_contexts "$GITHUB_WORKSPACE"/images/$partition.img "$GITHUB_WORKSPACE"/images/$partition
  sudo rm -rf "$GITHUB_WORKSPACE"/images/$partition
done
# 统计各分区大小
partitions=("mi_ext" "odm" "product" "system" "system_ext" "system_dlkm" "vendor" "vendor_dlkm")
for partition in "${partitions[@]}"; do
  eval "${partition}_size=$(du -sb "$GITHUB_WORKSPACE"/images/$partition.img | awk '{print $1}')"
done
sudo rm -rf "$GITHUB_WORKSPACE"/images/config
$lpmake --metadata-size 65536 --super-name super --block-size 4096 --partition mi_ext_a:readonly:"$mi_ext_size":qti_dynamic_partitions_a --image mi_ext_a="$GITHUB_WORKSPACE"/images/mi_ext.img --partition mi_ext_b:readonly:0:qti_dynamic_partitions_b --partition odm_a:readonly:"$odm_size":qti_dynamic_partitions_a --image odm_a="$GITHUB_WORKSPACE"/images/odm.img --partition odm_b:readonly:0:qti_dynamic_partitions_b --partition vendor_a:readonly:"$vendor_size":qti_dynamic_partitions_a --image vendor_a="$GITHUB_WORKSPACE"/images/vendor.img --partition vendor_b:readonly:0:qti_dynamic_partitions_b --partition vendor_dlkm_a:readonly:"$vendor_dlkm_size":qti_dynamic_partitions_a --image vendor_dlkm_a="$GITHUB_WORKSPACE"/images/vendor_dlkm.img --partition vendor_dlkm_b:readonly:0:qti_dynamic_partitions_b --partition system_a:readonly:"$system_size":qti_dynamic_partitions_a --image system_a="$GITHUB_WORKSPACE"/images/system.img --partition system_b:readonly:0:qti_dynamic_partitions_b --partition system_dlkm_a:readonly:"$system_dlkm_size":qti_dynamic_partitions_a --image system_dlkm_a="$GITHUB_WORKSPACE"/images/system_dlkm.img --partition system_dlkm_b:readonly:0:qti_dynamic_partitions_b --partition product_a:readonly:"$product_size":qti_dynamic_partitions_a --image product_a="$GITHUB_WORKSPACE"/images/product.img --partition product_b:readonly:0:qti_dynamic_partitions_b --partition system_ext_a:readonly:"$system_ext_size":qti_dynamic_partitions_a --image system_ext_a="$GITHUB_WORKSPACE"/images/system_ext.img --partition system_ext_b:readonly:0:qti_dynamic_partitions_b --device super:11811160064 --metadata-slots 3 --group qti_dynamic_partitions_a:11811160064 --group qti_dynamic_partitions_b:11811160064 --virtual-ab -F --output "$GITHUB_WORKSPACE"/images/super.img
End_Time 打包super
for i in mi_ext odm product system system_ext system_dlkm vendor vendor_dlkm; do
  rm -rf "$GITHUB_WORKSPACE"/images/$i.img
done
### 生成 super.img 结束

### 输出卡刷包
echo -e "${Red}- 开始生成卡刷包"
echo -e "${Red}- 开始压缩super.zst"
Start_Time
sudo find "$GITHUB_WORKSPACE"/images/ -exec touch -t 200901010000.00 {} \;
zstd -12 -f "$GITHUB_WORKSPACE"/images/super.img -o "$GITHUB_WORKSPACE"/images/super.zst --rm
End_Time 压缩super.zst
# 生成卡刷包
echo -e "${Red}- 生成卡刷包"
Start_Time
sudo $a7z a "$GITHUB_WORKSPACE"/zip/hyperos_${device}_${vendor_os_version}.zip "$GITHUB_WORKSPACE"/images/* >/dev/null
sudo rm -rf "$GITHUB_WORKSPACE"/images
End_Time 压缩卡刷包
# 定制 ROM 包名
echo -e "${Red}- 定制 ROM 包名"
md5=$(md5sum "$GITHUB_WORKSPACE"/zip/hyperos_${device}_${vendor_os_version}.zip)
echo "MD5=${md5:0:32}" >>$GITHUB_ENV
zip_md5=${md5:0:10}
rom_name="hyperos_dada_${vendor_os_version}_${zip_md5}_${android_version}.0_smice.zip"
sudo mv "$GITHUB_WORKSPACE"/zip/hyperos_${device}_${vendor_os_version}.zip "$GITHUB_WORKSPACE"/zip/"${rom_name}"
echo "rom_name=$rom_name" >>$GITHUB_ENV
### 输出卡刷包结束
