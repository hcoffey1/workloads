#!/bin/bash

#TODO: gups currently softlocks server?
config_gups(){
    num_threads=8
    mem_size_log=35 # (1 << 35) = 32 GB
    num_iter=$((1 * 1000 * 1000 * 1000))
    hot_mem_size_log=$(($mem_size_log / 4))
    item_size=8
    
    # Enable hugepages for gups
    nr_hugepages=$(( (1 << mem_size_log) / (1 << 21) ))

    # Set the number of hugepages
    echo "$nr_hugepages" | sudo tee /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages
}

build_gups(){
    (cd $CUR_PATH/gups_hemem && make -j$(nproc))
}

run_gups(){
    # Run GUPS
    #taskset 0xFF "${CUR_PATH}/gups_hemem/gups-skewed" \
    #    "$num_threads" "$num_iter" "$mem_size_log" "$item_size" "$hot_mem_size_log"
}

clean_gups(){
    # Disable hugepages
    echo 0 | sudo tee /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages
}
