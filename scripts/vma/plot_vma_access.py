import argparse
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.colors import LogNorm
import seaborn as sns

# Step 1: Parse command-line arguments
parser = argparse.ArgumentParser(description="Generate heat map for address range accesses.")
parser.add_argument("-d", "--datafile", required=True, help="Path to the data file with address accesses.")
parser.add_argument("-r", "--rangefile", required=True, help="Path to the range file with address ranges.")
parser.add_argument("-t", "--titlename", required=True, help="Workload name in title.")
args = parser.parse_args()

# Step 2: Read the files
data_file = args.datafile
ranges_file = args.rangefile
titlename = args.titlename

# Parse the address access file
address_accesses = []
with open(data_file, 'r') as f:
    for line in f:
        parts = line.split()
        address = int(parts[0], 16)  # Convert hexadecimal to integer
        accesses = np.diff([int(x) for x in parts[1:]], prepend=0)  # Calculate differences
        address_accesses.append((address, accesses))

# Load the ranges CSV file
ranges = pd.read_csv(ranges_file)
ranges['start'] = ranges['start'].apply(lambda x: int(x, 16))  # Convert start to integer
ranges['end'] = ranges['end'].apply(lambda x: int(x, 16))      # Convert end to integer

# Ensure the columns are integers for compatibility
ranges['start'] = ranges['start'].astype(int)
ranges['end'] = ranges['end'].astype(int)

# Aggregate accesses for ranges
epochs = len(address_accesses[0][1])
max_length = max(len(arr) for _, arr in address_accesses) # Find biggest epoch array
#heatmap_data = np.zeros((len(ranges), epochs))
heatmap_data = np.zeros((len(ranges), max_length))

for i, row in ranges.iterrows():
    start, end = row['start'], row['end']
    for address, accesses in address_accesses:
        if start <= address <= end:
            heatmap_data[i] += np.pad(accesses, (0, max_length - len(accesses)), 'constant')  # Aggregate accesses
            #heatmap_data[i] += accesses  # Aggregate accesses

# Step 3: Prepare for plotting
time_periods = range(epochs)
address_ranges = [f"{hex(row['start'])}-{hex(row['end'])}" for _, row in ranges.iterrows()]  # Format as hex

# Step 4: Plot the heat map
plt.figure(figsize=(10, 8))
sns.heatmap(heatmap_data, xticklabels=time_periods, yticklabels=address_ranges, norm=LogNorm())
plt.xlabel("Epoch/Time Period")
plt.ylabel("Address Range")
plt.title("Heat Map of Address Range Accesses for " + titlename)
plt.axhline(y=0.5, color='black', linestyle='--')  # Example dashed lines
plt.savefig(titlename+".png", dpi=300, bbox_inches="tight")
plt.show()
