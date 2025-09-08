#!/bin/bash

config_graph500(){
    num_threads=8
    size=26
    skip_validation=1
}

build_graph500(){
    pushd $CUR_PATH/graph500 > /dev/null

    git checkout master

    cp make-incs/make.inc-gcc make.inc

    #Change makefile gcc version and enable openmp
    sed -i -e 's/^CC = gcc-4.6/CC = gcc/' \
        -e 's/^# \(BUILD_OPENMP = Yes\)/\1/' \
        -e 's/^# \(CFLAGS_OPENMP = -fopenmp\)/\1/' make.inc

    (make -j$(nproc))

    popd
}

run_graph500(){
    local workload=$1
    # paths / names
    TIMEFILE="${OUTPUT_DIR}/${SUITE}_${workload}_${hemem_policy}_${DRAMSIZE}_time.txt"
    STDOUT="${OUTPUT_DIR}/${SUITE}_${workload}_${hemem_policy}_${DRAMSIZE}_stdout.txt"
    STDERR="${OUTPUT_DIR}/${SUITE}_${workload}_${hemem_policy}_${DRAMSIZE}_stderr.txt"
    PIDFILE="${OUTPUT_DIR}/${SUITE}_${workload}_${hemem_policy}_${DRAMSIZE}.pid"
    WRAPPER="${OUTPUT_DIR}/run_omp_${workload}.sh"

    # create wrapper (expand outer-shell vars now, but keep $$ for the wrapper to write its own PID)
    cat > "$WRAPPER" <<EOF
#!/bin/sh
# write this process's PID (will be the PID of omp-csr after exec)
echo \$\$ > "$PIDFILE"

# env only for the workload (time is not affected)
export LD_PRELOAD="$HEMEMPOL"
export DRAMSIZE="$DRAMSIZE"
export MIN_INTERPOSE_MEM_SIZE="$MIN_INTERPOSE_MEM_SIZE"
export SKIP_VALIDATION="$skip_validation"
export OMP_NUM_THREADS="$num_threads"

# replace shell with the real binary so PID stays the same
exec "$CUR_PATH/graph500/omp-csr/omp-csr" -s "$size" -V
EOF
    chmod +x "$WRAPPER"

    # run under numactl; time measures the wrapper -> execed omp-csr
    sudo numactl --cpunodebind=0 --membind=0 \
        /usr/bin/time -v -o "$TIMEFILE" \
        "$WRAPPER" \
        1> "$STDOUT" 2> "$STDERR" &

    # wait until wrapper has written pidfile (tiny loop is fine)
    while [ ! -s "$PIDFILE" ]; do sleep 0.01; done
    workload_pid=$(cat "$PIDFILE")
    echo "workload_pid=$workload_pid"

    # optional: cleanup wrapper if you don't need it
    rm -f "$WRAPPER"
}

run_strace_graph500(){
    SKIP_VALIDATION=$skip_validation OMP_NUM_THREADS=$num_threads taskset 0xFF \
        strace -e mmap,munmap -o graph500_xsbench_strace.log $CUR_PATH/graph500/omp-csr/omp-csr -s $size -V
}

clean_graph500(){
    return
}
