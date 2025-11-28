import argparse
import pandas as pd

# Parse command-line arguments
parser = argparse.ArgumentParser(description="Find max and min rss for VMAs across epochs.")
parser.add_argument("-d", "--datafile", required=True, help="Path to the csv file with smap and rss data.")
args = parser.parse_args()

# Read the file
data_file = args.datafile

# Load your CSV
df = pd.read_csv(data_file)  # Replace with your actual filename

# Sum rss_kb grouped by epoch
rss_sum_per_epoch = df.groupby('epoch')['rss_kb'].sum()

# Find maximum and minimum
max_epoch = rss_sum_per_epoch.idxmax()
max_value = rss_sum_per_epoch.max()

min_epoch = rss_sum_per_epoch.idxmin()
min_value = rss_sum_per_epoch.min()

# Print results
print(f"Maximum RSS sum: {max_value} KB or {max_value/1024} MB at epoch {max_epoch}")
print(f"Minimum RSS sum: {min_value} KB or {min_value/1024} MB at epoch {min_epoch}")
