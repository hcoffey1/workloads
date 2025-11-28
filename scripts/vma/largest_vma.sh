#!/bin/bash

# Default input and output file variables
input_file="$1"  # First argument by default
output_file="output.csv"
epoch_filter=false  # Default: no epoch-based filtering

# Parse options for -i (input), -o (output), and -e (epoch filtering)
while getopts "i:o:e" opt; do
    echo "Parsing option: $opt, with argument: $OPTARG"
    case $opt in
        i) input_file="$OPTARG" ;;
        o) output_file="$OPTARG" ;;
        e) epoch_filter=true ;;
        *) echo "Usage: $0 [-i input_file] [-o output_file] [-e (enable epoch filtering)]"; exit 1 ;;
    esac
done

# Check if input file is provided
if [[ -z "$input_file" ]]; then
    echo "Error: No input file provided."
    echo "Usage: $0 -i input_file -o output_file [-e]"
    exit 1
fi

# Temporary files for processing
temp_file=$(mktemp)
filtered_file=$(mktemp)

# Initialize the output file with headers
echo "epoch,rno,start,end,size,rss(kb),pathname" > "$output_file"

# Function to calculate size in decimal from hex addresses
calculate_size() {
    start_hex=$1
    end_hex=$2
    start_dec=$((16#$start_hex))
    end_dec=$((16#$end_hex))
    echo $((end_dec - start_dec))
}

# Step 1: Process the input file to calculate sizes and save to a temporary file
tail -n +2 "$input_file" | while IFS=',' read -r epoch rno start end inode pathname rss_kb; do
    size=$(calculate_size "$start" "$end")
    echo "$epoch,$rno,$start,$end,$size,$rss_kb,$pathname" >> "$temp_file"
done

# Step 2: Epoch-based filtering (if enabled)
if $epoch_filter; then
    # Find the epoch with the most rows
    biggest_epoch=$(awk -F',' '{count[$1]++} END {for (e in count) if (count[e] > max) {max = count[e]; best = e} print best}' "$temp_file")

    # Filter rows for the biggest epoch
    awk -F',' -v epoch="$biggest_epoch" '$1 == epoch' "$temp_file" > "$filtered_file"
else
    # No filtering: Use all rows
    cp "$temp_file" "$filtered_file"
fi

# Step 3: Eliminate duplicates by keeping the largest size for each starting address
awk -F',' '
    BEGIN { OFS="," }
    {
        if (!seen[$3] || $5 > seen[$3]) {
            seen[$3] = $5
            data[$3] = $0
        }
    }
    END {
        for (address in data) {
            print data[address]
        }
    }
' "$filtered_file" > "$temp_file"

# Step 4: Sort the output by start address (column 3)
sort -t',' -k3 "$temp_file" >> "$output_file"

# Clean up temporary files
rm -f "$temp_file" "$filtered_file"

echo "Processed and sorted VMA set saved to: $output_file"

