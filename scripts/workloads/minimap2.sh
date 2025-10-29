#!/bin/bash

# Source workload utilities
source "$CUR_PATH/scripts/workload_utils.sh"

# Data paths
MINIMAP2_DATA_DIR="$CUR_PATH/minimap2/data"
REFERENCE_GENOME_URL="https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.15_GRCh38/seqs_for_alignment_pipelines.ucsc_ids/GCA_000001405.15_GRCh38_no_alt_analysis_set.fna.gz"
REFERENCE_GENOME_FILE="$MINIMAP2_DATA_DIR/GRCh38_reference.fa.gz"

# Oxford Nanopore Ultralong Promethion data (HG002 - ~30-50x coverage, ultra-long reads)
ONT_UL_PROMETHION_URLS=(
    "ftp://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/AshkenazimTrio/HG002_NA24385_son/UCSC_Ultralong_OxfordNanopore_Promethion/GM24385_1.fastq.gz"
    "ftp://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/AshkenazimTrio/HG002_NA24385_son/UCSC_Ultralong_OxfordNanopore_Promethion/GM24385_2.fastq.gz"
    "ftp://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/AshkenazimTrio/HG002_NA24385_son/UCSC_Ultralong_OxfordNanopore_Promethion/GM24385_3.fastq.gz"
)

# Illumina short read data (HG002 - 300x coverage, good for short read testing)
# Using just the first pair of files to keep download reasonable (~12GB total)
ILLUMINA_WGS_URLS=(
    "ftp://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/AshkenazimTrio/HG002_NA24385_son/NIST_Illumina_2x250bps/reads/D1_S1_L001_R1_001.fastq.gz"
    "ftp://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/AshkenazimTrio/HG002_NA24385_son/NIST_Illumina_2x250bps/reads/D1_S1_L001_R2_001.fastq.gz"
)

download_reference_genome() {
    echo "Checking for reference genome..."

    if [[ -f "$REFERENCE_GENOME_FILE" ]]; then
        echo "Reference genome already downloaded: $REFERENCE_GENOME_FILE"
        return 0
    fi

    echo "Downloading GRCh38 reference genome (~800MB compressed)..."
    echo "This may take a while..."
    mkdir -p "$MINIMAP2_DATA_DIR"

    if wget -c -O "$REFERENCE_GENOME_FILE" "$REFERENCE_GENOME_URL"; then
        echo "Reference genome downloaded successfully"
    else
        echo "ERROR: Failed to download reference genome"
        return 1
    fi
}

download_ont_ultralong() {
    echo "Checking for Oxford Nanopore ultralong data..."

    local all_present=true
    for url in "${ONT_UL_PROMETHION_URLS[@]}"; do
        local filename=$(basename "$url")
        if [[ ! -f "$MINIMAP2_DATA_DIR/$filename" ]]; then
            all_present=false
            break
        fi
    done

    if $all_present; then
        echo "ONT ultralong data already downloaded"
        return 0
    fi

    echo "Downloading Oxford Nanopore Ultralong Promethion data for HG002..."
    echo "WARNING: This is ~35-50GB of data. This will take a long time!"
    echo "Read lengths: 10kb to >100kb (ultralong reads)"
    echo "Coverage: ~30-50x of human genome"
    mkdir -p "$MINIMAP2_DATA_DIR"

    for url in "${ONT_UL_PROMETHION_URLS[@]}"; do
        local filename=$(basename "$url")
        local filepath="$MINIMAP2_DATA_DIR/$filename"

        if [[ -f "$filepath" ]]; then
            echo "  $filename already exists, skipping..."
            continue
        fi

        echo "  Downloading $filename..."
        if wget -c -O "$filepath" "$url"; then
            echo "  Downloaded $filename successfully"
        else
            echo "ERROR: Failed to download $filename"
            return 1
        fi
    done

    echo "ONT ultralong data downloaded successfully"
}

download_illumina_short() {
    echo "Checking for Illumina short read data..."

    local all_present=true
    for url in "${ILLUMINA_WGS_URLS[@]}"; do
        local filename=$(basename "$url")
        if [[ ! -f "$MINIMAP2_DATA_DIR/$filename" ]]; then
            all_present=false
            break
        fi
    done

    if $all_present; then
        echo "Illumina data already downloaded"
        return 0
    fi

    echo "Downloading Illumina WGS 2x250bp data for HG002..."
    echo "Size: ~2-4GB per file"
    mkdir -p "$MINIMAP2_DATA_DIR"

    for url in "${ILLUMINA_WGS_URLS[@]}"; do
        local filename=$(basename "$url")
        local filepath="$MINIMAP2_DATA_DIR/$filename"

        if [[ -f "$filepath" ]]; then
            echo "  $filename already exists, skipping..."
            continue
        fi

        echo "  Downloading $filename..."
        if wget -c -O "$filepath" "$url"; then
            echo "  Downloaded $filename successfully"
        else
            echo "ERROR: Failed to download $filename"
            return 1
        fi
    done

    echo "Illumina data downloaded successfully"
}

config_minimap2(){
    local config_file="$1"
    local workload="$2"
    
    # Configuration for minimap2 alignment
    # Dataset options: "test", "ont-ultralong", "illumina-short"
    MINIMAP2_DATASET="${MINIMAP2_DATASET:-test}"
    MINIMAP2_THREADS="${MINIMAP2_THREADS:-8}"
    
    # Alignment mode: "full" (-a flag) or "approx" (no -a, faster, less memory)
    # full: Complete base-level alignment with CIGAR strings (more memory, slower)
    # approx: Approximate mapping only (PAF format, less memory, faster)
    MINIMAP2_MODE="${MINIMAP2_MODE:-full}"
    
    # Subsampling: number of reads to use (0 = all reads)
    # Useful for faster testing with representative data
    # Example: MINIMAP2_SUBSAMPLE=1000000 for 1M reads
    MINIMAP2_SUBSAMPLE="${MINIMAP2_SUBSAMPLE:-0}"
    
    # Configure based on dataset choice
    case "$MINIMAP2_DATASET" in
        "test")
            echo "=== Using minimap2 test dataset (VERY SMALL) ==="
            MINIMAP2_REFERENCE="$CUR_PATH/minimap2/test/MT-human.fa"
            MINIMAP2_QUERY="$CUR_PATH/minimap2/test/MT-orang.fa"
            MINIMAP2_PRESET="map-ont"
            echo "Reference: MT-human.fa (mitochondrial DNA, 16kb)"
            echo "Query: MT-orang.fa (orangutan mtDNA)"
            echo "Expected memory: <100MB"
            echo "Expected time: <1 second"
            ;;
            
        "ont-ultralong")
            echo "=== Using Oxford Nanopore Ultralong dataset (LARGE) ==="
            download_reference_genome || return 1
            download_ont_ultralong || return 1
            
            MINIMAP2_REFERENCE="$REFERENCE_GENOME_FILE"
            # Concatenate all ONT files for query
            MINIMAP2_QUERY="$MINIMAP2_DATA_DIR/GM24385_1.fastq.gz $MINIMAP2_DATA_DIR/GM24385_2.fastq.gz $MINIMAP2_DATA_DIR/GM24385_3.fastq.gz"
            MINIMAP2_PRESET="map-ont"
            echo "Reference: GRCh38 human genome (~3Gb)"
            echo "Query: ONT Ultralong Promethion HG002 (~35-50GB compressed)"
            echo "Expected memory: 10-15GB for index + 5-10GB per thread"
            echo "Expected time: 1-4 hours depending on system"
            ;;
            
        "illumina-short")
            echo "=== Using Illumina short read dataset (MEDIUM) ==="
            download_reference_genome || return 1
            download_illumina_short || return 1
            
            MINIMAP2_REFERENCE="$REFERENCE_GENOME_FILE"
            MINIMAP2_QUERY="$MINIMAP2_DATA_DIR/D1_S1_L001_R1_001.fastq.gz $MINIMAP2_DATA_DIR/D1_S1_L001_R2_001.fastq.gz"
            MINIMAP2_PRESET="sr"  # short read preset
            echo "Reference: GRCh38 human genome (~3Gb)"
            echo "Query: Illumina 2x250bp WGS (~12GB total, paired-end)"
            echo "Expected memory: 10-15GB for index + 2-4GB per thread"
            echo "Expected time: 30min-2 hours depending on system"
            ;;
            
        *)
            echo "ERROR: Unknown dataset '$MINIMAP2_DATASET'"
            echo "Valid options: test, ont-ultralong, illumina-short"
            return 1
            ;;
    esac
    
    # Export for use in run function
    export MINIMAP2_REFERENCE MINIMAP2_QUERY MINIMAP2_PRESET MINIMAP2_THREADS MINIMAP2_DATASET MINIMAP2_MODE MINIMAP2_SUBSAMPLE
    
    echo "Preset: $MINIMAP2_PRESET"
    echo "Threads: $MINIMAP2_THREADS"
    echo "Mode: $MINIMAP2_MODE ($([ "$MINIMAP2_MODE" = "full" ] && echo "full alignment with -a" || echo "approximate mapping, no -a"))"
    if [[ "$MINIMAP2_SUBSAMPLE" -gt 0 ]]; then
        echo "Subsampling: $MINIMAP2_SUBSAMPLE reads (shuffled for representativeness)"
    else
        echo "Subsampling: disabled (using all reads)"
    fi
    echo "=============================="
}build_minimap2(){
    local workload=$1

    echo "Building minimap2..."
    pushd $CUR_PATH/minimap2 > /dev/null

    # Clean and build
    make clean
    make -j$(nproc)

    # Verify binary was created
    if [[ ! -f minimap2 ]]; then
        echo "ERROR: minimap2 binary not found after build"
        popd
        exit 1
    fi

    echo "Minimap2 built successfully"
    popd > /dev/null
}

run_minimap2(){
    local workload=$1
    
    # Generate filenames using utility function
    generate_workload_filenames "$workload"
    
    # Prepare query: If subsampling, shuffle and take first N reads
    local query_files="$MINIMAP2_QUERY"
    if [[ "$MINIMAP2_SUBSAMPLE" -gt 0 ]]; then
        echo "Subsampling $MINIMAP2_SUBSAMPLE reads with shuffling..."
        local subsampled_query=""
        for qfile in $MINIMAP2_QUERY; do
            local basename=$(basename "$qfile" .gz)
            local subsampled_file="$MINIMAP2_DATA_DIR/subsampled_${MINIMAP2_SUBSAMPLE}_${basename}"
            
            # Skip if already subsampled
            if [[ ! -f "$subsampled_file" ]]; then
                echo "  Creating subsampled file: $subsampled_file"
                # Use seqtk for shuffling and subsampling (assumes seqtk is installed)
                # If not available, can use awk/sed but seqtk is much faster
                if command -v seqtk &> /dev/null; then
                    zcat "$qfile" | seqtk sample -s100 - "$MINIMAP2_SUBSAMPLE" > "$subsampled_file"
                else
                    echo "WARNING: seqtk not found, using all reads (subsampling disabled)"
                    echo "Install seqtk for subsampling: conda install -c bioconda seqtk"
                    query_files="$MINIMAP2_QUERY"
                    break
                fi
            fi
            subsampled_query="$subsampled_query $subsampled_file"
        done
        if [[ -n "$subsampled_query" ]]; then
            query_files="$subsampled_query"
        fi
    fi
    
    # Build minimap2 arguments based on mode
    local minimap2_flags=""
    if [[ "$MINIMAP2_MODE" = "full" ]]; then
        minimap2_flags="-a"  # Full SAM alignment
    fi
    # For "approx" mode, no -a flag (outputs PAF format)
    
    # Minimap2 command: -x sets preset, -t sets threads, -a for full alignment (optional)
    local binary_path="$CUR_PATH/minimap2/minimap2"
    local binary_args="$minimap2_flags -x $MINIMAP2_PRESET -t $MINIMAP2_THREADS $MINIMAP2_REFERENCE $query_files"
    
    # Create wrapper script
    local extra_env=""
    
    create_workload_wrapper "$WRAPPER" "$PIDFILE" "$binary_path" "$binary_args" "$extra_env"
    
    echo "Starting minimap2 alignment..."
    echo "Dataset: $MINIMAP2_DATASET"
    echo "Mode: $MINIMAP2_MODE"
    if [[ "$MINIMAP2_SUBSAMPLE" -gt 0 ]]; then
        echo "Using subsampled queries: $query_files"
    fi
    echo "This may take a while for large datasets..."
    
    # Use standard workload execution
    run_workload_standard "--cpunodebind=0 --membind=0"
    
    start_bwmon
}run_strace_minimap2(){
    local workload=$1

    echo "Running minimap2 with strace..."
    taskset 0xFF strace -e mmap,munmap -o minimap2_${workload}_strace.log \
        $CUR_PATH/minimap2/minimap2 -a -x $MINIMAP2_PRESET -t $MINIMAP2_THREADS \
        $MINIMAP2_REFERENCE $MINIMAP2_QUERY > /dev/null

    workload_pid=$!
}

clean_minimap2(){
    stop_bwmon
    return
}
