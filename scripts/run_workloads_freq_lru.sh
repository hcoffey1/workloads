#!/bin/bash
#==============================================================
# 4, 8, 16, 32 GB
#DRAM_SIZES=(4294967296)
#HEMEM_POL=(/mydata/hemem/src/libhemem.so)
#MIN_INTERPOSE_MEM_SIZE=33554432
#MIN_INTERPOSE_MEM_SIZE=16777216
MIN_INTERPOSE_MEM_SIZE=$((32*1024))

#MIN_INTERPOSE_MEM_SIZE=67108864
#DRAM_SIZES=(2147483648)
DRAM_SIZES=($((5*1024*1024*1024)))
HEMEM_POL=(~/arms/src/libhemem-runtime.so)
N=0
for i in $(seq 0 $N); do
    for size in "${DRAM_SIZES[@]}"; do
        for pol in "${HEMEM_POL[@]}"; do
           #HEMEM_REGIONS="0x7fff1f800000-0x7fff97800000:lru" HEMEM_REGIONS_PHYS="lru:1G:8G" MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b merci -w merci -o results/results_dual_policy_lru_${i}
           #HEMEM_REGIONS="0x555555400000-0x7fff1f600000:lru,0x7fff1f800000-0x7fff97800000:hemem" MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b merci -w merci -o results/results_dual_policy_${i}
        #   SYS_ALLOC="/users/hjcoffey/arms/jemalloc/lib/libjemalloc.so" \
	#	   ./run.sh -b merci -w merci -o results/results_pebs_${i} -r 3 -i pebs -s 1000 --record-vma

		   #HEMEM_REGIONS="0x7ff99990fc00-0x7fffed9ce000:lru" \
		   #HEMEM_REGIONS="0x7ff99990fc00-0x7ffac396ee00:lru" \
		   
		   #HEMEM_REGIONS="0x7fe89a6d6200-0x7fea000e1e00:lru" \
		   #HEMEM_REGIONS="0x7ff084fc3600-0x7ff1ea9cf200:lru" \
           #SYS_ALLOC="/users/hjcoffey/arms/jemalloc/lib/libjemalloc.so" \
	#	   HEMEM_REGIONS="0x7fea000e1e00-0x77feb65aeda00:lru" \
	#	   HEMEM_REGIONS_PHYS="lru:1G:26G" \
	#	   MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE \
			   #REGENT_REGIONS=lru:0x7ffdca733000-0x7ffef479220:2G \

			   #REGENT_REGIONS=lru:0x7ffd00000000-0x7ffeff000000:256M \

		#   REGENT_FAST_MEMORY=8G \
		#   ARMS_POLICY=ARMS \
		#	   HEMEMPOL=~/arms/libarms_kernel.so ./run.sh \
		#	   -b merci -w merci -o results3/results_lfu_${i} \
		#	-r 2 #-i pebs -s 1000 --record-vma

		   REGENT_FAST_MEMORY=8G \
		   ARMS_POLICY=lru \
			   HEMEMPOL=~/arms/libarms_kernel.so ./run.sh \
			   -b merci -w merci -o results_perf/results_lru_${i} \
			-r 2 #-i pebs -s 1000 --record-vma

		   REGENT_FAST_MEMORY=8G \
		   REGENT_REGIONS=lru:0x7ffd00000000-0x7ffeff000000:512M \
			   HEMEMPOL=~/arms/libarms_kernel.so ./run.sh \
			   -b merci -w merci -o results_perf/results_hybrid_512M_${i} \
			-r 2 #-i pebs -s 1000 --record-vma

		   REGENT_FAST_MEMORY=8G \
		   REGENT_REGIONS=lru:0x7ffd00000000-0x7ffeff000000:2G \
			   HEMEMPOL=~/arms/libarms_kernel.so ./run.sh \
			   -b merci -w merci -o results_perf/results_hybrid_2G_${i} \
			-r 2 #-i pebs -s 1000 --record-vma

        #   SYS_ALLOC="/users/hjcoffey/arms/jemalloc/lib/libjemalloc.so" \
	#	   HEMEM_REGIONS="0x7fea000e1e00-0x77feb65aeda00:lru" \
	#	   HEMEM_REGIONS_PHYS="lru:1G:26G" \
	#	   MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE \
	#	   HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b merci -w merci -o results/results_lru_${i} \
	#		-r 1 #-i pebs -s 1000 --record-vma

        #   SYS_ALLOC="/users/hjcoffey/arms/jemalloc/lib/libjemalloc.so" \
	#	   HEMEM_REGIONS="0x7ff084fc3600-0x7ff1ea9cf200:lfu" \
	#	   HEMEM_REGIONS_PHYS="lfu:1G:8G" \
	#	   MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE \
	#	   HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b merci -w merci -o results/results_lfu_${i} \
	#		-r 3 #-i pebs -s 1000 --record-vma

        #   SYS_ALLOC="/users/hjcoffey/arms/jemalloc/lib/libjemalloc.so" \
	#	   MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE \
	#	   HEMEM_POLICY="lfu"\
	#	   HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b merci -w merci -o results/results_lfu_${i} -r 1

        #   SYS_ALLOC="/users/hjcoffey/arms/jemalloc/lib/libjemalloc.so" \
	#	   MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE \
	#	   HEMEM_POLICY="lru"\
	#	   HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b merci -w merci -o results/results_lru_${i} -r 3

           #SYS_ALLOC="/users/hjcoffey/arms/jemalloc/lib/libjemalloc.so" HEMEM_POLICY="lfu" MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b merci -w merci -o results/results_lfu_${i}
          # SYS_ALLOC="/users/hjcoffey/arms/jemalloc/lib/libjemalloc.so" HEMEM_POLICY="lfu" MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b merci -w merci -o results/results_lfu_${i}
          # SYS_ALLOC="/users/hjcoffey/arms/jemalloc/lib/libjemalloc.so" HEMEM_POLICY="lru" MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b merci -w merci -o results/results_lru_${i}

          # SYS_ALLOC="/users/hjcoffey/arms/jemalloc/lib/libjemalloc.so" HEMEM_POLICY="lfu" MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b gapbs -w bc -o results/results_lfu_${i}
          # SYS_ALLOC="/users/hjcoffey/arms/jemalloc/lib/libjemalloc.so" HEMEM_POLICY="lru" MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b gapbs -w bc -o results/results_lru_${i}

           #SYS_ALLOC="/users/hjcoffey/arms/jemalloc/lib/libjemalloc.so" ./run.sh -b merci -w merci -o results/results_freq_${i}
           #HEMEM_POLICY="lru" MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b merci -w merci -o results/results_lru_${i}

           #HEMEM_POLICY="lfu" MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b gapbs -w bc -o results/results_freq_${i}
           #HEMEM_POLICY="lru" MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b gapbs -w bc -o results/results_lru_${i}

           #MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b xsbench -w xsbench -o results/results_freq_lru_${i}

           #MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b silo -w silo -o results/results_freq_lru_${i}

           #MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b liblinear -w liblinear -o results/results_freq_lru_${i}

           #MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b flexkvs -w flexkvs -o results/results_freq_lru_${i}

           #MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b graph500 -w graph500 -o results/results_freq_lru_${i}

           #MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b gapbs -w bc -o results/results_freq_lru_${i}

           #MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b gapbs -w pr -o results/results_freq_lru_${i}

           #MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b gapbs -w pr_spmv -o results/results_freq_lru_${i}

           #MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b gapbs -w cc -o results/results_freq_lru_${i}

           #MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b gapbs -w cc_sv -o results/results_freq_lru_${i}

           #MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b gapbs -w bfs -o results/results_freq_lru_${i}

           #MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b gapbs -w sssp -o results/results_freq_lru_${i}

            # ======================
            # gapbs tc takes too long (~2 hours per run)
            #HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b gapbs -w tc -o results/results_freq_lru_${i}

            #MERCI doesn't work with HEMEM
            #HEMEMPOL=$pol DRAMSIZE=$size ./run.sh -b merci -w merci -o results/results_freq_lru_${i}

        done
    done
done
exit

cloverleaf_peak=$((9154748*1024))

liblinear_peak=$((74121965774)) #~69 GB?
DRAM_SIZES=(0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 0.1 1)
N=15
HEMEM_POL=(/mydata/hemem/src/libhemem.so /mydata/hemem/src/libhemem-lru.so /mydata/hemem/src/libhemem-baseline.so)
# May or may not work, lets run after other workloads are done that are more stable
for i in $(seq 4 $N); do
    for size in "${DRAM_SIZES[@]}"; do
        for pol in "${HEMEM_POL[@]}"; do
            MEM_USED=$(echo "$liblinear_peak * $size / 1" | bc)
            MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$MEM_USED ./run.sh -b liblinear -w liblinear -o results/test_${i}

            MEM_USED=$(echo "$cloverleaf_peak * $size / 1" | bc)
            MIN_INTERPOSE_MEM_SIZE=$MIN_INTERPOSE_MEM_SIZE HEMEMPOL=$pol DRAMSIZE=$MEM_USED ./run.sh -b cloverleaf -w cloverleaf -o results/test_${i}
        done
    done
done
