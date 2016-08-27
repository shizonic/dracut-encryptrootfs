#!/bin/sh

. /lib/dracut-lib.sh
. /sbin/encryptrootfs_key_management_impl.sh

partitions_dump_file=/tmp/initial_partition_dump.txt

_info() {
    info "$*"
}

_warning() {
    warn "$*"
}

_resize_partition(){
    disk_name=$1
    partition_name=$2
    free_space_to_clean_mb=$3


    #free space to clean at the end of disk in megabytes
    sector_size_output=$(/sbin/fdisk -l $disk_name)
    _check_errors
    sector_size=$(echo "${sector_size_output}" | grep "Sector size" | awk '{print $4}')
    _check_errors
    _info "Sector size is "${sector_size}" bytes"

    let free_space_to_clean_sectors=$free_space_to_clean_mb*1024*1024/$sector_size

    _info "We need "$free_space_to_clean_sectors" sectors for storing "$free_space_to_clean_mb" Mb"

    size_in_sectors_output=$(/sbin/fdisk -l $disk_name)
    _check_errors
    size_in_sectors=$(echo "${size_in_sectors_output}" | grep "Disk $disk_name" | awk '{print $7}')
    _info "Size in sectors "$size_in_sectors

    let result_partition_size_in_sectors=$size_in_sectors-$free_space_to_clean_sectors
    _info "Result partition size should be "$result_partition_size_in_sectors" sectors"

    _info $(/sbin/sfdisk  -d $disk_name > $partitions_dump_file)
    _check_errors
    _info $(sed -e 's!\(^'${partition_name}'.*size\=\s*\)\([0-9]*\)\(,.*\)!\1'$result_partition_size_in_sectors'\3!' -i $partitions_dump_file)
    _check_errors
    _info "Result partition is "$(cat $partitions_dump_file)

    out=$(/sbin/sfdisk --no-reread --force $disk_name < $partitions_dump_file)
    _check_errors
    _info "Result partition table"${out}

}

_create_boot_partition(){
    disk_name=$1
    boot_partition_sized_in_mb=$2
    fs_type=$3

    disk_size_in_mb_output=$(/sbin/parted $disk_name unit mb print)
    _check_errors
    disk_size_in_mb=$(echo "${disk_size_in_mb_output}" | grep -e "Disk $disk_name" | awk '{print $3}' | grep -o -e "[0-9]*")
    _check_errors
    _info "Disk size is "$disk_size_in_mb" MB"

    let start_partition=$disk_size_in_mb-$boot_partition_sized_in_mb
    _info "Boot partition will start from "$start_partition

    _info "Creating boot partition /sbin/parted $disk_name mkpart primary ext2 $start_partition $disk_size_in_mb"
    out=$(/sbin/parted $disk_name mkpart primary $fs_type $start_partition $disk_size_in_mb)
    _check_errors
    _info "Partition creation result "$out

    _info "Removing boot flag from current rootfs /sbin/parted $disk_name set 1 boot off"
    out=$(/sbin/parted $disk_name set 1 boot off)
    _check_errors
    _info "Result "$out

    _info "Setting boot flag to new boot partition /sbin/parted $disk_name set 2 boot on"
    out=$(/sbin/parted $disk_name set 2 boot on)
    _check_errors
    _info "Result "$out

    _info "Creating filesystem on boot partition mkfs.ext3 ${disk_name}2"
    out=$(mkfs.$fs_type ${disk_name}2)
    _check_errors
    _info "Result "$out

    _info "Setting boot label e2label ${disk_name}2 boot"
    out=$(/sbin/e2label ${disk_name}2 boot)
    _check_errors
    _info "Result "$out
}

_copy_rootfs_content(){
    root_partition=$1
    mount $root_partition /sysroot/
    _check_errors

    content_size_of_rootfs_kb=$(df -B K | grep /sysroot | awk '{print $3}' | grep -o -e "[0-9]*")
    _check_errors
    shm_size_kb=$(df -B K | grep /dev/shm | awk '{print $2}' | grep -o -e "[0-9]*")
    _check_errors
    free_memory=$(cat /proc/meminfo | grep MemFree | awk '{print $2}')

    if [ "$content_size_of_rootfs_kb" -gt "$free_memory" ]; then
        _warning "Filesystem content (${content_size_of_rootfs_kb}KB) is bigger that available (${free_memory}KB) memory. Couldn't perform encryption."$enc_file
        sleep ${pause_on_error}
        exit 1
    fi

    if [ "$content_size_of_rootfs_kb" -gt "$shm_size_kb" ]; then
        _info "Remounting /dev/shm with bigger size"
        umount /dev/shm
        _check_errors "umount /dev/shm"
        mount -t tmpfs -o size=${content_size_of_rootfs_kb}K,nosuid,nodev,rw,strictatime tmpfs /dev/shm/
        _check_errors "mount -t tmpfs -o size=${content_size_of_rootfs_kb}K,nosuid,nodev,rw,strictatime tmpfs /dev/shm/"
        dev_shm_remounted="true"
    fi

    cp -a /sysroot/ /dev/shm/sysroot/
    _check_errors
    umount $root_partition
    _check_errors
}
_check_errors(){
   if [[ $? -gt 0 ]]
   then
        _warning "Return code is not 0 but '$?'. For operation ${1}"
        #sleeping some time to make sure we are able to see where error happened
        sleep ${pause_on_error}
        exit 1
   fi
}

_init_key(){
    boot_mount="/tmp/boot"
    mkdir $boot_mount

    boot_partition=$(blkid -L $boot_partition_label)
    _check_errors
    mount $boot_partition $boot_mount
    _check_errors
    key_management_generate_key_file $decrypted_keyfile_path
    _check_errors
    key_management_encrypt_key_file $decrypted_keyfile_path $boot_mount/$encrypted_keyfile_path
    _check_errors
    umount $boot_mount
}

_luks_format_and_open(){
    root_partition=$1
    decrypted_keyfile_path=$2
    rootfs_partition_file_system=$3

    /sbin/cryptsetup -v luksFormat $root_partition $decrypted_keyfile_path
    _check_errors

    /sbin/cryptsetup --debug luksOpen $root_partition rootfs --key-file $decrypted_keyfile_path
    _check_errors

    /sbin/mkfs.$rootfs_partition_file_system /dev/mapper/rootfs
    _check_errors

    mkdir /sysroot
    mount -t $rootfs_partition_file_system /dev/mapper/rootfs /sysroot/
    _check_errors
}

_decrypt_keyfile()
{
     mount_path="/tmp/boot"
     mkdir $mount_path
     boot_partition=$(blkid -L $boot_partition_label)
     _check_errors
     mount $boot_partition $mount_path
     _check_errors

     enc_file=$mount_path/$encrypted_keyfile_path

     if [  -e $enc_file ];then
        key_management_decrypt_key_file $enc_file $decrypted_keyfile_path
        _check_errors
     else
        _warning "Can't find file "$enc_file
        sleep ${pause_on_error}
        exit 1
     fi

     umount $mount_path
     _check_errors
     _info "Key file was decrypted and stored to "$decrypted_keyfile_path
}

_luks_open(){
     root_partition=$1
     decrypted_keyfile_path=$2

     /sbin/cryptsetup --debug luksOpen $root_partition rootfs --key-file $decrypted_keyfile_path
     _check_errors

     mkdir /sysroot
     mount -t $rootfs_partition_file_system /dev/mapper/rootfs /sysroot/
     _check_errors
}

_copy_rootfs_content_back(){
    cp -a /dev/shm/sysroot/* /sysroot
    rm -rf /dev/shm/sysroot/
    if [[ -n "$dev_shm_remounted" ]]; then
        _info "Returning /dev/shm to original size"
        umount /dev/shm
        _check_errors "umount /dev/shm"
        mount -t tmpfs -o size=${shm_size_kb}K,nosuid,nodev,rw,strictatime tmpfs /dev/shm/
        _check_errors "mount -t tmpfs -o size=${content_size_of_rootfs_kb}K,nosuid,nodev,rw,strictatime tmpfs /dev/shm/"
    fi
}

_encryptrootfs()
{
    . /etc/encryptrootfs.conf

    boot_partition=$(/sbin/blkid | grep $boot_partition_label)
    if [[ -z $boot_partition ]]
    then
        _info "Starting partition preparation"

        _copy_rootfs_content $root_partition

        _resize_partition $disk $root_partition $boot_partition_size
        _create_boot_partition $disk $boot_partition_size $boot_partition_file_system
        _init_key

        _luks_format_and_open $root_partition $decrypted_keyfile_path $rootfs_partition_file_system
        _copy_rootfs_content_back
        echo "#File marker for further processing" > /sysroot/etc/encryptrootfs-initramfs

    else
        _info "All partitions are already created. Just unlocking filesystem"
        _decrypt_keyfile
        _luks_open $root_partition $decrypted_keyfile_path
    fi

    if [ "$?" = "0" ]; then
        _info "Partitions were successfuly configured during."
    else
        _warning "Can't unlock rootfs."
        exit 1
    fi
}

_encryptrootfs
