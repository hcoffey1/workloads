suite=gapbs
work=bc

export PEBS_USE_PA=0
./run.sh -b $suite -w $work -i pebs -s 1000 --record-vma -o results_va_no_huge
export PEBS_USE_PA=1
./run.sh -b $suite -w $work -i pebs -s 1000 --record-vma -o results_pa_no_huge

suite=liblinear
work=liblinear

export PEBS_USE_PA=0
./run.sh -b $suite -w $work -i pebs -s 1000 --record-vma -o results_va_no_huge
export PEBS_USE_PA=1
./run.sh -b $suite -w $work -i pebs -s 1000 --record-vma -o results_pa_no_huge
