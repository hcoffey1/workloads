import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
import argparse
import os

def get_cluster_bounds(df):
    arr = np.asarray(df['cluster'])
    if arr.size == 0:
        return []
    
    # Compare previous and next values to find where cluster ID changes
    change_indices = np.flatnonzero(arr[1:] != arr[:-1]) + 1
    starts = np.concatenate(([0], change_indices))
    ends = np.concatenate((change_indices - 1, [len(arr) - 1]))
    #values = arr[starts]

    return np.stack((starts, ends), axis=1).tolist()

def label_regions(df, bounds, label_col='region_id'):
    df = df.copy()
    df[label_col] = -1  # default value for unlabeled rows

    for i, (start, end) in enumerate(bounds):
        df.loc[start:end, label_col] = i

    return df

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("csv_file_path")
    args = parser.parse_args()
    csv_file = args.csv_file_path

    base,_ = os.path.splitext(csv_file)
    grouped_image = base + "_grouped_cluster.png"

    full_df = pd.read_csv(csv_file)

    grouped_dfs = {
        epoch: group.copy()
        for epoch, group in full_df.groupby('cluster_epoch')
    }

   
    labeled_dfs = []
    for df in grouped_dfs.values():
        # Duplicate pageframes have identical stats in same epoch
        df = df.drop_duplicates('PageFrame').reset_index(drop=True)
        bounds = get_cluster_bounds(df)
        df = label_regions(df,bounds)
        labeled_dfs.append(df)

    label_combined_df = pd.concat(labeled_dfs, ignore_index=True)
    final_df = full_df.merge(label_combined_df[['PageFrame', 'region_id']], on='PageFrame', how='left')
    print(final_df)
    #for b in bounds:


    plt.figure(figsize=(12, 12))
    plt.scatter(final_df['epoch'], final_df['PageFrame'], c=final_df['region_id'], s=50, edgecolor='none', rasterized=True, alpha=0.7, marker='.')
    ax = plt.gca()

    # 1) Define a hex‐formatter: takes a float x and returns e.g. '0x1a3f'
    hex_formatter = FuncFormatter(lambda x, pos: hex(int(x)))
    print("done with formatter")

    # 2) Install it on the y‐axis
    ax.yaxis.set_major_formatter(hex_formatter)
    ax.invert_yaxis()
    print("invert y axi")
    
    #plt.show()
    plt.xlabel("Time (s)")
    plt.ylabel("Page Frame")
    plt.title(base + ": Cont. Cluster Groups")
    print("saving figure")
    plt.savefig(grouped_image, dpi=300, bbox_inches="tight")
