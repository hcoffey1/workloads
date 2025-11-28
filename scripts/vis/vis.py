# Python script for visualizing results of test scripts.
# WIP and very unstable. - Hayden Coffey
import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
import seaborn as sns
import numpy as np
import sys
import os
import re

# Used to accelerate plotting DAMON figures.
from concurrent.futures import ProcessPoolExecutor
import multiprocessing

from matplotlib.colors import LogNorm, hsv_to_rgb

# Return a df for the damon region file
def parse_damon_region_log_file(file_path):
    records = []
    current_section = {}
    global_base = None

    with open(file_path, 'r') as f:
        lines = f.readlines()

    # Process the global header: first line should contain base_time_absolute
    if lines and lines[0].startswith("base_time_absolute:"):
        global_base = lines[0].split(":", 1)[1].strip()
        # Remove this line from further processing
        lines = lines[1:]

    i = 0
    while i < len(lines):
        line = lines[i].strip()
        # Skip empty lines
        if not line:
            i += 1
            continue

        # Detect the start of a new section
        if line.startswith("monitoring_start:"):
            region_id = 0
            current_section = {}
            # Capture section metadata (monitoring_start, monitoring_end, etc.)
            while i < len(lines) and lines[i].strip() and ':' in lines[i]:
                meta_line = lines[i].strip()
                # Stop when reaching the comment line that begins the table
                if meta_line.startswith("#"):
                    break
                key, value = meta_line.split(":", 1)
                current_section[key.strip()] = value.strip()
                i += 1

            # Now skip the column header line (which starts with "#")
            if i < len(lines) and lines[i].strip().startswith("#"):
                # Optionally, you could parse column names here:
                # columns = lines[i].strip()[1:].split()
                i += 1
            continue  # Continue so we can start reading table rows

        # Now, process table rows until a blank line or a new section
        # Expected format:
        # 555555554000-555555590000 (      245760)           0    22
        pattern = r'(\S+-\S+)\s+\(\s*([0-9]+)\)\s+([0-9]+)\s+([0-9]+)'
        m = re.match(pattern, line)
        if m:
            addr_range = m.group(1)
            length = int(m.group(2))
            nr_accesses = int(m.group(3))
            age = int(m.group(4))
            # Split the address range into start and end addresses
            start_addr, end_addr = addr_range.split('-')

            # Build a record with both section metadata and log fields
            record = current_section.copy()
            record.update({
                "base_time_absolute": global_base,
                "start_addr": start_addr,
                "end_addr": end_addr,
                "length": length,
                "nr_accesses": nr_accesses,
                "age": age,
                "region_id": region_id
                })
            records.append(record)
            region_id += 1
        i += 1

    # Convert list of records to a pandas DataFrame
    return pd.DataFrame(records)

# Prepare a df for given PEBS sample file
def prepare_pebs_df(file):
    # Read the file line by line
    with open(file) as f:
        rows = [line.strip().split() for line in f if line.strip()]

    # Find the maximum number of columns in any row
    max_cols = max(len(row) for row in rows)

    # Pad each row so all have the same length
    #padded_rows = [row + [np.nan]*(max_cols - len(row)) for row in rows]

    # Function to pad each row with the last recorded value
    def pad_row(row, target_length):
        if len(row) < target_length:
            last_value = row[-1]
            # Extend the row with the last_value until it reaches the target length
            row = row + [last_value] * (target_length - len(row))
        return row

    # Pad each row accordingly
    padded_rows = [pad_row(row, max_cols) for row in rows]

    # Create a DataFrame
    df = pd.DataFrame(padded_rows)

    # Rename columns: first column as 'PageFrame' and remaining as 'Epoch1', 'Epoch2', ...
    df.rename(columns={0: "PageFrame"}, inplace=True)
    df.columns = ["PageFrame"] + [f"Epoch_{i}" for i in range(1, max_cols)]

    df["PageFrame"] = df["PageFrame"].apply(lambda x: hex(int(x, 16) << 21))

    # Convert epoch columns to numeric
    for col in df.columns[1:]:
        df[col] = pd.to_numeric(df[col])


    # Set PageFrame as index for easier time-series operations
    df.set_index("PageFrame", inplace=True)

    df = df.copy() # Improves performance? df is sparse otherwise

    # Compute the deltas across epochs
    delta_df = df.diff(axis=1)

    # For the first epoch, fill NaN with the original epoch value
    first_epoch = df.columns[0]
    delta_df[first_epoch] = df[first_epoch]

    # Reorder columns to ensure the first epoch is first
    delta_df = delta_df[df.columns]

    # Optional: Convert column names to a numeric index if desired
    # For plotting purposes, we can remove the 'Epoch_' prefix and convert to int
    delta_df.columns = [int(col.replace("Epoch_", ""))*0.5 for col in delta_df.columns]

    # If we want to use plt instead of sns, melt df into long form
    #df_long = (
    #    delta_df
    #    .reset_index()
    #    .melt(id_vars=["PageFrame"], var_name="epoch", value_name="value")
    #)
    #df_long["PageFrame"] = df_long["PageFrame"].apply(lambda x: int(x,16))
    #return df_long

    return delta_df

#Concurrent DAMON df preprocessing operations=====================
def process_chunk(chunk_df, df_regions):
    # Note: you have to pass df_regions in via a global or serialize it
    # Here we assume it's a global variable accessible by child processes.
    chunk_df['region_id'] = chunk_df.apply(lambda row: find_region_id(row, df_regions), axis=1)
    return chunk_df

def find_region_id(row, df2):
    #print(row)
    time = row['time']
    addr = row['address']
    matches = df2[
            (df2['monitoring_start'] <= time) &
            (df2['monitoring_end'] >= time) &
            (df2['start_addr'] <= addr) &
            (df2['end_addr'] >= addr)
            ]
    if not matches.empty:
        return matches.iloc[0]['region_id']  # if multiple matches, take the first
    else:
        #print("Failed! time {} addr {}".format(time,addr))
        #exit()
        return None
#========================================================

# Prepare df from given DAMON heatmap file
def prepare_damon_df(file, output_path):
    damon_draw_group = -1
    records = []
    start = None

    header_re = re.compile(r'^\[(\d+),\s*(\d+)\]$')

    with open(file, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            # If this line is a new [start,end] header, parse it
            m = header_re.match(line)
            if m:
                start = int(m.group(1))
                damon_draw_group += 1
                #if damon_draw_group > 0:
                    #break
                # (we ignore 'end' here since you only need 'start')
                continue

            # Otherwise it should be a data row: time address frequency
            # split on whitespace:
            time_ns, addr_off, freq = line.split()
            records.append({
                'time':      float(time_ns) / 1e9,
                'address':     int(addr_off) + start,
                'frequency':   float(freq),
                'damon_draw_group':   int(damon_draw_group)
            })

    # build DataFrame
    data = pd.DataFrame.from_records(records, columns=['time','address','frequency', 'damon_draw_group'])

    # Check if we have plotted some of these figures before, can save a lot of time
    # by not recalculating everything for these data points.
    for draw_group in data['damon_draw_group'].unique():
        tmp_file = output_path + "_{}dg_heatmap.png".format(str(draw_group))
        print("Checking " + tmp_file)
        if os.path.isfile(tmp_file):
            print("Skipping {}".format(tmp_file))
            data = data[data['damon_draw_group'] != draw_group]

    print(data)

    df_regions = parse_damon_region_log_file(file.split('.')[0] + ".region.damon.txt")

    df_regions['start_addr'] = df_regions['start_addr'].apply(lambda x: int(x,16))
    df_regions['end_addr'] = df_regions['end_addr'].apply(lambda x: int(x,16))

    #Convert times from ns to s
    df_regions['monitoring_start'] = df_regions['monitoring_start'].astype(float) / (1e9)
    df_regions['monitoring_end'] = df_regions['monitoring_end'].astype(float) / (1e9)

    # Address to DAMON region lookup (done in parallel)===========================
    # Number of worker threads,
    # could change to core count if memory consumed not too high
    n_procs = multiprocessing.cpu_count()

    # split into chunks
    chunks = np.array_split(data, n_procs)

    # “freeze” df_regions into child processes by declaring it global
    # (alternative: use functools.partial to bind it as an extra argument)
    global _REGIONS
    _REGIONS = df_regions

    with ProcessPoolExecutor(max_workers=n_procs) as exe:
        # map each chunk into its own process
        futures = [exe.submit(process_chunk, chunk, _REGIONS) for chunk in chunks]

        # collect results as they come back
        results = [f.result() for f in futures]

    # stitch your DataFrame back together
    data = pd.concat(results, ignore_index=True)
    #=====================================

    # Sequential implemenation (very slow)
    #data['region_id'] = data.apply(lambda row: find_region_id(row, df_regions), axis=1)

    print('-----')
    data = data.dropna()

    return data

def generate_damon_figure(file, output_path):
    df = prepare_damon_df(file, output_path)

    for draw_group in df['damon_draw_group'].unique():
        tmp_df = df[df['damon_draw_group'] == draw_group].copy()

        plt.figure(figsize=(12, 12))
        #=====================================
        # Normalize intensity to [0,1]
        int_min, int_max = tmp_df['frequency'].min(), tmp_df['frequency'].max()
        print('min max ', int_min, int_max)
        #norm = LogNorm(vmin=int_min, vmax=int_max)#, clip=True)
        eps = 1e-3  # or something small compared to your data
        norm = LogNorm(vmin=int_min + eps, vmax=int_max + eps, clip=True)
        #df['int_norm'] = (df['frequency'] - int_min) / (int_max - int_min)
        tmp_df['int_norm'] = norm(tmp_df['frequency'])

        # Assign a distinct hue for each region_id in HSV space
        unique_regions = sorted(df['region_id'].unique())
        n_regions = len(unique_regions)
        hue_map = {reg: idx / n_regions for idx, reg in enumerate(unique_regions)}

        # Build RGB colors by combining hue (category) and value (intensity)
        colors = [
                #hsv_to_rgb([hue_map[r], 1.0, intensity]) #Uncomment if we want to also show frequency info
                hsv_to_rgb([hue_map[r], 1.0, 1])
                for r, intensity in zip(tmp_df['region_id'], tmp_df['int_norm'])
                ]

        # Plot
        #plt.figure(figsize=(8, 6))
        plt.scatter(tmp_df['time'], tmp_df['address'], color=colors, s=50, edgecolor='none', rasterized=True, alpha=0.7, marker='.')
        #plt.scatter(df['time'], df['address'], s=50, edgecolor='none', rasterized=True, alpha=0.7, marker='.')
        ax = plt.gca()

        # 1) Define a hex‐formatter: takes a float x and returns e.g. '0x1a3f'
        hex_formatter = FuncFormatter(lambda x, pos: hex(int(x)))

        # 2) Install it on the y‐axis
        ax.yaxis.set_major_formatter(hex_formatter)
        ax.invert_yaxis()
        #=====================================

        plt.xlabel("Time (s)")
        plt.ylabel("Page Frame")
        plt.title(file)
        plt.legend()
        #plt.show()

        #print("Saving: ", file_name)
        plt.savefig(output_path + "_{}dg_heatmap.png".format(draw_group), dpi=300, bbox_inches="tight")

def generate_pebs_figure(file, output_path):

    output_file = output_path + "_heatmap.png"
    print("Checking {}".format(output_file))

    if os.path.isfile(output_file):
        print("Skipping {}".format(output_file))
        return

    df = prepare_pebs_df(file)
    plt.figure(figsize=(12, 12))
    sns.heatmap(df, cmap="viridis", cbar=True, norm=LogNorm())

    # If we want to use plt instead of sns
    #plt.scatter(df['epoch'], df['PageFrame'], c=df['value'], s=50, norm=LogNorm(), edgecolor='none', rasterized=True, alpha=0.7, marker='.')

    #ax = plt.gca()
    ## 1) Define a hex‐formatter: takes a float x and returns e.g. '0x1a3f'
    #hex_formatter = FuncFormatter(lambda x, pos: hex(int(x)))

    ## 2) Install it on the y‐axis
    #ax.yaxis.set_major_formatter(hex_formatter)
    #ax.invert_yaxis()

    plt.xlabel("Time (s)")
    plt.ylabel("Page Frame")
    plt.title(file + ": PEBS")
    plt.savefig(output_file, dpi=300, bbox_inches="tight")

def view(directory, file, pebs=True):
    if pebs:
        subdirectory="pebs"
    else:
        subdirectory="damon"

    file_name=(file.split('/')[-1].split('.')[0])
    output_dir = os.path.join(directory, subdirectory)
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)

    output_path = os.path.join(output_dir, file_name) #+ "_heatmap.png")

    #print("Checking {}".format(output_path))

    #if os.path.isfile(output_path):
    #    print("Skipping {}".format(output_path))
    #    return

    if pebs:
        generate_pebs_figure(file, output_path)
    else:
        generate_damon_figure(file, output_path)

def main():
    sns.set(font_scale=2)

    assert len(sys.argv) == 2

    directory = sys.argv[1]

    assert os.path.isdir(directory)

    i = 0
    for filename in os.listdir(directory):
        file_path = os.path.join(directory, filename)
        if os.path.isfile(file_path):  # Ensure it's a file, not a directory
            isPebs = True
            print(file_path)

            #if file_path.endswith('_damon.region.damon.txt'):
            #    continue

            if file_path.endswith('_damon.damon.txt'):
                isPebs = False
            elif not file_path.endswith('samples.dat'):
                continue

            view(directory, file_path, isPebs)

if __name__ == "__main__":
    main()
