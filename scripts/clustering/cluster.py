# Given input data produce:
# - Cluster region figure
# - PEBs Access heatmap figure
# - csv with page stats and cluster labels

import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
import seaborn as sns
import numpy as np
import sys
import os
import re
import argparse
import time
import joblib
import tracemalloc
import gc
from collections import Counter
from scipy.stats import skew, kurtosis

# Used to accelerate plotting DAMON figures.
#from concurrent.futures import ProcessPoolExecutor
#import multiprocessing
from multiprocessing import Pool, cpu_count
from functools import partial

from matplotlib.colors import LogNorm, hsv_to_rgb
from matplotlib.patches import Patch

from sklearn.cluster import KMeans, DBSCAN, Birch
from sklearn.preprocessing import StandardScaler
from sklearn.decomposition import PCA, IncrementalPCA

plt.rcParams.update({'font.size': 22})
epoch_conversion = 1 # How long each epoch is in seconds
feature_filter = ['PageFrame', 'duty_cycle_sample_count', 'duty_cycle', 'label', 'workload', 'cluster']
#feature_filter = ['PageFrame', 'value_mean', 'value_std', 'duty_cycle_sample_count', 'duty_cycle', 'label', 'workload', 'cluster']

def normalized_mad(x):
    med = np.median(x)
    if med == 0:
        return np.nan  # or np.inf, or 0 depending on your logic
    mad = np.median(np.abs(x - med))
    return mad / med

def apply_cluster(page_stat_df, birch=None, ipca=None, group_size=1):
    scaler = StandardScaler()
    #print(page_stat_df)
    # Collapsed Clustering===========================
    #features = page_stat_df.drop(columns=['PageFrame_-1', 'PageFrame', 'PageFrame_1', \
    #        'rno_-1', 'rno', 'rno_1', 'duty_cycle_sample_count_-1', \
    #        'duty_cycle_sample_count', 'duty_cycle_sample_count_1', \
    #        'duty_cycle_-1', 'duty_cycle', 'duty_cycle_1'])
    # Collapsed Clustering===========================
    features = page_stat_df.drop(columns=feature_filter, errors='ignore')

    num_full_groups = len(features) // group_size
    leftover = len(features) % group_size

    group_features = []
    group_indices = []

    # Process full groups
    for i in range(num_full_groups):
        group = features.iloc[i * group_size : (i + 1) * group_size]
        group_features.append(group.values.flatten())
        group_indices.append(list(group.index))

    # Process leftover group if present
    if leftover > 0:
        group = features.iloc[-leftover:]
        # Pad with zeros to match full group shape
        padded = np.pad(group.values.flatten(),
                        (0, group_size * features.shape[1] - group.values.size),
                        mode='constant', constant_values=0)
        group_features.append(padded)
        group_indices.append(list(group.index))
    #
    ##print(group_features)
    X = np.array(group_features)
    if len(X) < 2:
        return None

    scaled_features = scaler.fit_transform(X)
    #scaled_features = scaler.fit_transform(features)
    #print(X)

    # Simple check per page=================
    #threshold = 10
    #diff = np.abs(page_stat_df['duty_cycle_percent_first_half'] - page_stat_df['duty_cycle_percent_second_half'])
    #print("Diff")
    #print(diff)
    #page_stat_df['label'] = np.where((diff > threshold) & (page_stat_df['duty_cycle_percent'] < 25), 'sequential', 'random')

    #page_stat_df['label'] = page_stat_df['duty_cycle_percent'].apply(
    #    lambda x: 'sequential' if x < 25 else 'random'
    #)
    ##print(page_stat_df['duty_cycle_percent'])
    #page_stat_df['cluster'] = -1
    #return page_stat_df
    # Simple check per page=================


    if not birch and not ipca: # PCA + DBSCAN
        #print("DBSCAN")
        #pca = PCA(n_components=0.95)
        #pca_df = pd.DataFrame(pca.fit_transform(scaled_features))#, columns=pca_col)
        db = DBSCAN(eps=1.0, min_samples=5).fit(scaled_features) # Density based clustering
        page_stat_df['cluster'] = db.labels_
    elif ipca and not birch: # IPCA + DBSCAN
        #print("IPCA + DBSCAN")
        ipca.partial_fit(scaled_features)
        pca_df = ipca.transform(scaled_features)
        db = DBSCAN(eps=1.0, min_samples=5).fit(pca_df) # Density based clustering
        page_stat_df['cluster'] = db.labels_
    else: # BIRCH
        ipca.partial_fit(scaled_features)
        pca_df = ipca.transform(scaled_features)
        #print("No IPCA")
        birch.partial_fit(pca_df)
        #birch.partial_fit(scaled_features)
        #page_stat_df['cluster'] = birch.predict(scaled_features)
        labels = birch.predict(pca_df)
        #labels = birch.predict(scaled_features)
        # Assign labels back to the DataFrame
        page_stat_df['group_id'] = -1
        page_stat_df['cluster'] = -1

        for gid, (idxs, label) in enumerate(zip(group_indices, labels)):
            page_stat_df.loc[idxs, 'group_id'] = gid
            page_stat_df.loc[idxs, 'cluster'] = label

    page_stat_df['cluster'] = page_stat_df['cluster'].astype(int)

    #region_counts = page_stat_df['cluster'].value_counts()
    #small_regions = region_counts[region_counts < 1024].index
    #small_id = -1
    #page_stat_df['cluster'] = page_stat_df['cluster'].apply(lambda x: small_id if x in small_regions else x)

    #for df in page_stat_df address groups of 0.5 GB:
        #find last boundary change in 0.5 GB group
        #convert all rows up to that boundary to the majority class
    page_stat_df['window_base'] = (page_stat_df['PageFrame'] // (2**29)) * (2**29)
    for base_addr, group in page_stat_df.groupby('window_base'):
        cluster_seq = group['cluster'].values
        last_boundary = 0

        for i in range(1, len(cluster_seq)):
            if cluster_seq[i] != cluster_seq[i-1]:
                last_boundary = i

        if last_boundary == 0:
            continue

        # Filter out -1 and find the most common label
        valid_clusters = [c for c in cluster_seq[:last_boundary+1] if c != -1]
        if not valid_clusters:
            continue  # skip if only -1s

        majority_cluster = Counter(valid_clusters).most_common(1)[0][0]

        index_to_update = group.index[:last_boundary+1]
        page_stat_df.loc[index_to_update, 'cluster'] = majority_cluster

    #for cluster, group in page_stat_df.groupby('cluster'):
    #    print(cluster, '============')
    #    print(group)

    # Step 1: Compute average x per label
    avg_dc = page_stat_df.groupby('cluster')['duty_cycle_percent'].mean()
    #print("Average DC:----------------")
    #print(avg_dc)

    # Step 2: Map condition to new values
    page_stat_df['label'] = page_stat_df['cluster'].map(lambda lbl: 'sequential' if avg_dc[lbl] < 25 else 'random')

    return page_stat_df

def find_region_id(row, df2):
    #print(row)
    #time = row['time']
    addr = row['PageFrame']
    if df2 is None:
        return None  # No VMA filtering when df2 is None
    matches = df2[
            (df2['start'] <= addr) &
            (df2['end'] > addr)
            #(df2['start_addr'] <= addr) &
            #(df2['end_addr'] >= addr)
            ]
    if not matches.empty:
        return matches.iloc[0]['rno'].astype(int) # if multiple matches, take the first
    else:
        #print("Failed! time {} addr {}".format(time,addr))
        #exit()
        return None

# Prepare a df for given PEBS sample file
def prepare_pebs_df(file):
    # Read the file line by line
    with open(file) as f:
        rows = [line.strip().split() for line in f if line.strip()]

    # Find the maximum number of columns in any row
    max_cols = max(len(row) for row in rows)

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

    df["PageFrame"] = df["PageFrame"].apply(lambda x: hex(int(x, 16))) #<< 21))

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
    delta_df.columns = [int(col.replace("Epoch_", ""))*epoch_conversion for col in delta_df.columns]

    # If we want to use plt instead of sns, melt df into long form
    df_long = (
        delta_df
        .reset_index()
        .melt(id_vars=["PageFrame"], var_name="epoch", value_name="value")
    )
    df_long["PageFrame"] = df_long["PageFrame"].apply(lambda x: int(x,16))

    return df_long

def get_reuse_distance_df(df):
    df_zero_streak_sorted = df.sort_values(by=['PageFrame', 'epoch']).reset_index(drop=True)

    # Container for results
    results = []

    grouped = df_zero_streak_sorted.groupby('PageFrame')
    # Group by PageFrame
    for pf, group in grouped:
        # Mark where value == 0
        zero_mask = group['value'] == 0

        # Identify start of new streaks using the change in zero_mask
        streak_id = (zero_mask != zero_mask.shift()).cumsum()

        # For value == 0 streaks only, compute their lengths
        zero_streaks = group[zero_mask].groupby(streak_id).size()

        # Get the max streak length (0 if none)
        max_streak = zero_streaks.max() if not zero_streaks.empty else 0

        results.append({'PageFrame': pf, 'reuse_distance': max_streak})

    # Create a new dataframe
    streak_df = pd.DataFrame(results)
    return streak_df

def calculate_duty_cycle(df):
    # Total unique time samples (e.g. epochs)
    total_samples = len(df['epoch'].unique())

    # Calculate overall duty cycle
    non_zero_df = df[df['value'] != 0]
    counts = non_zero_df.groupby('PageFrame').size()
    counts.name = 'duty_cycle'
    df = df.merge(counts, on='PageFrame', how='left')
    df['duty_cycle'] = df['duty_cycle'].fillna(0).astype(int)
    df['duty_cycle_sample_count'] = total_samples
    df['duty_cycle_percent'] = (df['duty_cycle'] / total_samples * 100).astype(int)

    # Split by half: sort by epoch first for consistent splitting
    df_sorted = df.sort_values('epoch')
    halfway = len(df_sorted) // 2

    first_half = df_sorted.iloc[:halfway]
    second_half = df_sorted.iloc[halfway:]

    # Get sample count in each half
    first_half_samples = len(first_half['epoch'].unique())
    second_half_samples = len(second_half['epoch'].unique())

    # Calculate duty cycles per half
    first_half_counts = first_half[first_half['value'] != 0].groupby('PageFrame').size()
    second_half_counts = second_half[second_half['value'] != 0].groupby('PageFrame').size()

    # Map to full df
    df['duty_cycle_first_half'] = df['PageFrame'].map(first_half_counts).fillna(0).astype(int)
    df['duty_cycle_second_half'] = df['PageFrame'].map(second_half_counts).fillna(0).astype(int)

    df['duty_cycle_percent_first_half'] = (df['duty_cycle_first_half'] / first_half_samples * 100).astype(int)
    df['duty_cycle_percent_second_half'] = (df['duty_cycle_second_half'] / second_half_samples * 100).astype(int)

    return df

def process_interval(df, split_vma_df, pebs_rate, birch=None, ipca=None, group_size=1):
    clustering_time_start = time.time()
    preproc_time1_start = time.time()
    time_bin_df = df.copy()

    d_start = time.time()
    duty_df = calculate_duty_cycle(time_bin_df)
    d_end = time.time()
    #duty_df = duty_df.drop_duplicates(subset='PageFrame')[['PageFrame', 'duty_cycle', 'duty_cycle_sample_count', 'duty_cycle_percent']]
    duty_df = duty_df.drop_duplicates(subset='PageFrame')[['PageFrame', 'duty_cycle', 'duty_cycle_sample_count', 'duty_cycle_percent', 'duty_cycle_percent_first_half', 'duty_cycle_percent_second_half']]

    # Reuse distance takes too long to calculate ~28 seconds
    #s_start = time.time()
    #streak_df = get_reuse_distance_df(time_bin_df)
    #s_end = time.time()
    #time_bin_df = time_bin_df.merge(streak_df, on='PageFrame', how='left')

    v_start = time.time()
    time_bin_df['value'] = time_bin_df['value'] * pebs_rate # Scale samples by PEBS rate.
    page_stat_df = time_bin_df.groupby('PageFrame').agg(
            #value_min=('value', 'min'),
            #value_max=('value', 'max'),
            value_mean=('value', 'mean'),
            value_std=('value', 'std'),
            # Skew and kurtosis too slow to calculate ~10 seconds
            #value_skew=('value', lambda x: skew(x, bias=False)),
            #value_kurtosis=('value', lambda x: kurtosis(x, fisher=True, bias=False)),
            #value_nmad=('value', normalized_mad),
    )
    v_end = time.time()
    preproc_time1_end = time.time()
    #print("preproc1 done : {} s".format(preproc_time1_end - preproc_time1_start))
    #print("\td : {} s".format(d_end - d_start))
    #print("\tv : {} s".format(v_end - v_start))

    preproc_time2_start = time.time()
    page_stat_df['value_std'] = page_stat_df['value_std'].fillna(0)
    page_stat_df['var'] = page_stat_df['value_std'] / page_stat_df['value_mean']
    page_stat_df = page_stat_df.merge(duty_df, on='PageFrame', how='left')
    page_stat_df = page_stat_df.reset_index(drop=True)

    #TODO: No longer using split_vma in this func. Not filtering pages until figure gen.
    #page_stat_df['rno'] = page_stat_df.apply(lambda row: find_region_id(row, split_vma_df), axis=1)
    #page_stat_df = page_stat_df.dropna().reset_index(drop=True)

    page_stat_df = page_stat_df[page_stat_df['value_mean'] != 0.0]
    preproc_time2_end = time.time()
    #print("preproc2 done : {} s", preproc_time2_end - preproc_time2_start)

    if page_stat_df.empty or len(page_stat_df) == 1:
        return None

    cluster_time_start = time.time()
    clustered_df = apply_cluster(page_stat_df.copy(), birch, ipca, group_size)
    cluster_time_end = time.time()
    print("Cluster done : {} s", cluster_time_end - cluster_time_start)
    if clustered_df is None:
        return None

    time_bin_df = time_bin_df.merge(
        clustered_df.drop_duplicates('PageFrame'),
        on='PageFrame',
        how='left'
    )
    time_bin_df = time_bin_df.dropna()

    clustering_time_end = time.time()

    # Return clustered results, timing info, and # of elements clustered
    return {
            'result': time_bin_df,
            'time': clustering_time_end - clustering_time_start,
            'count': len(time_bin_df)
    }

# Pulls data from ./labeled
def get_labeled_data(N, birch):
    def prepare_labeled_df(df, N):
        #df = prepare_pebs_df(pebs_file)
        df['time_bin'] = (df['epoch'] // N).astype(int)
        dfs_by_interval = {
            f"{N * bin}s_to_{N * (bin + 1)}s": group.drop(columns='time_bin')
            for bin, group in df.groupby('time_bin')
        }

        # Apply cluster labels in parallel for each binned df
        print("Applying cluster labels to epochs...")
        dfs = list(dfs_by_interval.values())

        prepped_dfs = []
        for time_bin_df in dfs:
            duty_df = calculate_duty_cycle(time_bin_df)
            duty_df = duty_df.drop_duplicates(subset='PageFrame')[['PageFrame', 'duty_cycle', 'duty_cycle_sample_count', 'duty_cycle_percent', 'duty_cycle_percent_first_half', 'duty_cycle_percent_second_half']]

            pebs_rate = 20000
            time_bin_df['value'] = time_bin_df['value'] * pebs_rate # Scale samples by PEBS rate.
            page_stat_df = time_bin_df.groupby('PageFrame').agg(
                    value_mean=('value', 'mean'),
                    value_std=('value', 'std'),
                    #value_skew=('value', lambda x: skew(x, bias=False)),
                    #value_kurtosis=('value', lambda x: kurtosis(x, fisher=True, bias=False)),
            )

            page_stat_df['value_std'] = page_stat_df['value_std'].fillna(0)
            page_stat_df['var'] = page_stat_df['value_std'] / page_stat_df['value_mean']
            page_stat_df = page_stat_df.merge(duty_df, on='PageFrame', how='left')

            page_stat_df = page_stat_df.merge(time_bin_df[['PageFrame', 'workload']], on='PageFrame', how='left')

            # Step 1: Compute the majority label for each PageFrame
            majority_labels = (
                time_bin_df.groupby('PageFrame')['label']
                   .agg(lambda x: x.value_counts().idxmax())
                   .reset_index()
            )

            # Step 2: Merge the majority labels into df1
            page_stat_df = page_stat_df.merge(majority_labels, on='PageFrame', how='left')

            page_stat_df = page_stat_df.reset_index(drop=True)

            page_stat_df = page_stat_df[page_stat_df['value_mean'] != 0.0]
            prepped_dfs.append(page_stat_df)

            #print(majority_labels)
        labeled_df = pd.concat(prepped_dfs, ignore_index=True)
        labeled_df = labeled_df[labeled_df['label'] != 'unlabeled']

        return labeled_df

    starting_dfs = []
    merci_df = pd.read_csv('./labeled/merci_20k.csv', index_col=0).reset_index(drop=True)
    merci_df['workload'] = 'merci'
    starting_dfs.append(merci_df)

    #graph500_df = pd.read_csv('./labeled/graph500_20k.csv', index_col=0).reset_index(drop=True)
    #graph500_df['workload'] = 'graph500'
    #starting_dfs.append(graph500_df)

    cc_sv_df = pd.read_csv('./labeled/gapbs_cc_sv_20k.csv', index_col=0).reset_index(drop=True)
    cc_sv_df['workload'] = 'gapbs_cc_sv'
    starting_dfs.append(cc_sv_df)

    labeled_dfs = []
    for df in starting_dfs:
        labeled_dfs.append(prepare_labeled_df(df, N))

    labeled_df = pd.concat(labeled_dfs, ignore_index=True)

    clustered_df = apply_cluster(labeled_df.copy(), birch, None)
    print('-------------------------------')
    print(clustered_df.columns)
    print('-------------------------------')

    majority_labels = (
        clustered_df.groupby('cluster')['label']
          .agg(lambda x: x.value_counts().idxmax())
          .reset_index()
    )
    print(majority_labels)
    scaler = StandardScaler()
    features = clustered_df.drop(columns=feature_filter, errors='ignore')
    print(features)
    scaled_features = scaler.fit_transform(features)

    pca = PCA(n_components=2)
    pca_df = pd.DataFrame(pca.fit_transform(scaled_features), columns=['pca_0', 'pca_1'])#, columns=pca_col)

    # Reset index to align rows if needed (just in case)
    pca_df.index = clustered_df.index

    # Add PCA features to original DataFrame
    clustered_df = pd.concat([clustered_df, pca_df], axis=1)

    print(clustered_df)
    #exit()
    plt.figure(figsize=(12, 12))

    #clustered_df = clustered_df[clustered_df['label'] == 'uniform']

    # Step 1: Get unique cluster labels and map to a categorical colormap
    cluster_labels = clustered_df['label'].unique()
    #cluster_labels.sort()  # Optional: consistent ordering

    # Choose a categorical colormap (tab10 = 10 colors, tab20 = 20, etc.)
    cmap = plt.get_cmap('Set1')  # or 'Set3', 'Accent' if more clusters

    # Create a mapping from cluster label to color
    color_dict = {label: cmap(i % cmap.N) for i, label in enumerate(cluster_labels)}

    # Apply the color mapping to your DataFrame
    colors = clustered_df['label'].map(color_dict)
    plt.scatter(clustered_df['pca_0'], clustered_df['pca_1'], c=colors, s=50, edgecolor='none', rasterized=True, alpha=1.0, marker='.')

    # Add a legend showing label -> color
    legend_elements = [Patch(facecolor=color_dict[label], label=label) for label in cluster_labels]
    plt.legend(handles=legend_elements, title="Label", bbox_to_anchor=(1.05, 1), loc='upper left')

    #plt.scatter(clustered_df['duty_cycle_percent'], clustered_df['var'], s=50, edgecolor='none', rasterized=True, alpha=0.7, marker='.')

    #plt.show()
    plt.xlabel("Time (s)")
    plt.ylabel("Page Frame")
    plt.title(base + ": Clusters. (P = " + str(N) + ")")
    plt.savefig("cluster.png", dpi=300, bbox_inches="tight")

    plt.figure(figsize=(12, 12))

    #clustered_df = clustered_df[clustered_df['label'] == 'uniform']

    # Step 1: Get unique cluster labels and map to a categorical colormap
    cluster_labels = clustered_df['workload'].unique()
    #cluster_labels.sort()  # Optional: consistent ordering

    # Choose a categorical colormap (tab10 = 10 colors, tab20 = 20, etc.)
    cmap = plt.get_cmap('Set1')  # or 'Set3', 'Accent' if more clusters

    # Create a mapping from cluster label to color
    color_dict = {label: cmap(i % cmap.N) for i, label in enumerate(cluster_labels)}

    # Apply the color mapping to your DataFrame
    colors = clustered_df['workload'].map(color_dict)
    plt.scatter(clustered_df['pca_0'], clustered_df['pca_1'], c=colors, s=50, edgecolor='none', rasterized=True, alpha=1.0, marker='.')

    # Add a legend showing label -> color
    legend_elements = [Patch(facecolor=color_dict[label], label=label) for label in cluster_labels]
    plt.legend(handles=legend_elements, title="Label", bbox_to_anchor=(1.05, 1), loc='upper left')


    #plt.scatter(clustered_df['duty_cycle_percent'], clustered_df['var'], s=50, edgecolor='none', rasterized=True, alpha=0.7, marker='.')

    #plt.show()
    plt.xlabel("Time (s)")
    plt.ylabel("Page Frame")
    plt.title(base + ": Clusters. (P = " + str(N) + ")")
    plt.savefig("cluster_workload.png", dpi=300, bbox_inches="tight")

    return majority_labels

def save_cluster_fig(file_name, df, feature):
    plt.figure(figsize=(12, 12))

    # Step 1: Get unique cluster labels and map to a categorical colormap
    cluster_labels = df[feature].unique()
    #cluster_labels.sort()  # Optional: consistent ordering

    # Choose a categorical colormap (tab10 = 10 colors, tab20 = 20, etc.)
    cmap = plt.get_cmap('Set1')  # or 'Set3', 'Accent' if more clusters

    # Create a mapping from cluster label to color
    color_dict = {label: cmap(i % cmap.N) for i, label in enumerate(cluster_labels)}

    # Apply the color mapping to your DataFrame
    colors = df[feature].map(color_dict)
    plt.scatter(df['epoch'], df['PageFrame'], c=colors, s=50, edgecolor='none', rasterized=True, alpha=0.7, marker='.')

    # Add a legend showing label -> color
    legend_elements = [Patch(facecolor=color_dict[label], label=label) for label in cluster_labels]
    plt.legend(handles=legend_elements, title=feature, bbox_to_anchor=(1.05, 1), loc='upper left')

    xmin = df['epoch'].min()
    xmax = df['epoch'].max()
    ymin = df['PageFrame'].min() + (1<<30)
    ax = plt.gca()

    # 1) Define a hex‐formatter: takes a float x and returns e.g. '0x1a3f'
    hex_formatter = FuncFormatter(lambda x, pos: hex(int(x)))

    # 2) Install it on the y‐axis
    ax.yaxis.set_major_formatter(hex_formatter)
    ax.invert_yaxis()

    #plt.show()
    plt.xlabel("Time (s)")
    plt.ylabel("Page Frame")
    plt.title(base + ": {}. (P = ".format(feature) + str(N) + ")")
    plt.savefig(file_name, dpi=300, bbox_inches="tight")
    #==================================

if __name__ == "__main__":

    parser = argparse.ArgumentParser()
    parser.add_argument("smap_file_path", nargs='?', default=None, help="Optional path to smap file for VMA filtering")
    parser.add_argument("pebs_file_path")
    parser.add_argument('--birch', default=False, action='store_true')
    parser.add_argument('--birch_model', type=str, default=None, help='Birch Model to use.')
    parser.add_argument('--time_bin', type=int, default=20, help='How often to perform clustering (seconds).')
    parser.add_argument('--group_size', type=int, default=1, help='Number of rows to flatten.')
    parser.add_argument('--fig', default=False, action='store_true')
    parser.add_argument('--mem_prof', default=False, action='store_true', help='Collect memory usage stats. (Slows execution)')
    parser.add_argument('--pebs_rate', type=int, help='PEBS Sampling Rate')

    args = parser.parse_args()
    smap_file = args.smap_file_path
    pebs_file = args.pebs_file_path
    birch_model = args.birch_model
    is_birch = args.birch
    is_fig = args.fig
    mem_prof = args.mem_prof
    pebs_rate = args.pebs_rate
    group_size = args.group_size
    N = args.time_bin # Bin length in seconds

    base,_ = os.path.splitext(pebs_file)
    birch_path='birch_model.joblib'
    ipca_path='ipca_model.joblib'

    if birch_model:
        is_birch = True
        birch_path = birch_model

    if not is_birch:
        csv_output_file = base + "_" + str(N) + "_dbscan_cluster.csv"
        cluster_fig_output_file = base + "_" + str(N) + "_dbscan_cluster.png"
        label_fig_output_file = base + "_" + str(N) + "_dbscan_cluster_label.png"
    else:
        birch_name = os.path.splitext(os.path.basename(birch_path))[0]
        csv_output_file = base + "_" + str(N) + "_" + birch_name + "_" + str(group_size) + "_gs_" + "_no_pca_birch_cluster.csv"
        cluster_fig_output_file = base + "_" + str(N) + "_" + birch_name + "_" + str(group_size) + "_gs_" + "_no_pca_birch_cluster.png"
        label_fig_output_file = base + "_" + str(N) + "_" + birch_name + "_" + str(group_size) + "_gs_" + "_no_pca_birch_cluster_label.png"

    # Read in VMA smap data. Really just used to filter out memory addresses we don't want to examine (libraries etc.)
    if smap_file is not None:
        vma_df = (pd.read_csv(smap_file))

        next_rno = vma_df['rno'].max() + 1 # When we split up large regions, start indexing new rno from here.

        vma_df['start'] = vma_df['start'].apply(lambda x: int(x,16))
        vma_df['end'] = vma_df['end'].apply(lambda x: int(x,16))
        print(vma_df)

        # Get only vma with no pathname (anon region) and a size over 2 MB
        filtered_vma_df = (vma_df[pd.isna(vma_df['pathname']) & (vma_df['size'] >= (1<<21))])
    else:
        print("No smap file provided. Proceeding without VMA filtering.")
        vma_df = None
        filtered_vma_df = None

    # Not currently splitting large VMA into sub groups, so this function isn't used.
    def split_large_rows(df, next_rno, size_threshold=(1<<20)):
        new_rows = []

        for _, row in df.iterrows():
            if row['size'] > size_threshold:
                # Calculate number of chunks needed
                num_chunks = int(row['size'] // size_threshold)
                last_chunk_size = row['size'] % size_threshold

                # Split into chunks
                start = row['start']
                for i in range(num_chunks):
                    new_row = row.copy()
                    new_row['rno'] = next_rno
                    new_row['start'] = start
                    new_row['end'] = start + size_threshold * (1<<10)
                    new_row['size'] = size_threshold
                    new_rows.append(new_row)
                    start += size_threshold * (1<<10)
                    next_rno += 1

                # Last chunk (if any remainder)
                if last_chunk_size > 0:
                    new_row = row.copy()
                    new_row['rno'] = next_rno
                    new_row['start'] = start
                    new_row['end'] = start + last_chunk_size * (1<<10)
                    new_row['size'] = last_chunk_size
                    new_rows.append(new_row)
                    next_rno += 1
            else:
                new_rows.append(row)

        return pd.DataFrame(new_rows)

    #split_vma_df = (split_large_rows(filtered_vma_df, next_rno)).reset_index(drop=True)

    # Read in pebs data and bin in N second intervals
    df = prepare_pebs_df(pebs_file)
    df['time_bin'] = (df['epoch'] // N).astype(int)
    print(df)
    dfs_by_interval = {
        f"{N * bin}s_to_{N * (bin + 1)}s": group.drop(columns='time_bin')
        for bin, group in df.groupby('time_bin')
    }

    # Apply cluster labels in parallel for each binned df
    labeled_dfs = []
    print("Applying cluster labels to epochs...")
    dfs = list(dfs_by_interval.values())

    cluster_times = []
    cluster_mem = []
    if not is_birch and not mem_prof:
        # Parallel DBSCAN clustering (parallel for faster offline clustering)
        partial_func = partial(process_interval, split_vma_df=filtered_vma_df, pebs_rate=pebs_rate)
        with Pool(processes=cpu_count()) as pool:
            pool_results = pool.map(partial_func, dfs)

        pool_results = [r for r in pool_results if r is not None]
        results = [r['result'] for r in pool_results]
        cluster_times = [(r['count'], r['time']) for r in pool_results]
    else:
        # Iterative online learning with birch
        # Load BIRCH and IPCA models if present, otherwise create
        birch = None
        ipca = None
        if is_birch:
            if os.path.exists(birch_path):
                birch = joblib.load(birch_path)
            else:
                birch = Birch(n_clusters=None, threshold=1.5)
                #birch = Birch(n_clusters=DBSCAN(eps=1.8), threshold=1)
                #birch = Birch(n_clusters=DBSCAN(eps=1.0, min_samples=5), threshold=1)

                #birch = Birch(n_clusters=None, threshold=1)
            if os.path.exists(ipca_path):
                ipca = joblib.load(ipca_path)
            else:
                ipca = IncrementalPCA(n_components=2)

        # Begin iterative online clustering
        if is_fig:
            cluster_map = None #get_labeled_data(N, birch)

        i = 0
        results = []
        for df in dfs:
            if mem_prof: # Start memory tracing
                tracemalloc.start()

            result_dict = process_interval(df, filtered_vma_df, pebs_rate, birch, ipca, group_size)

            if mem_prof: # Collect memory stat (in B) and cleanup
                current, peak = tracemalloc.get_traced_memory()
                #print(f"Current: {current / 1024:.1f} KB; Peak: {peak / 1024:.1f} KB")
                tracemalloc.stop()
                gc.collect()

            if result_dict != None:
                results.append(result_dict['result'])
                cluster_times.append((result_dict['count'], result_dict['time']))

                if mem_prof:
                    cluster_mem.append((result_dict['count'], peak))

                print("{}/{} : {} s".format(i, len(dfs)-1, result_dict['time']))
            else:
                print("{}/{} : -----> Returned {}".format(i, len(dfs)-1, result_dict))

            i+=1

        # Save BIRCH and IPCA models
        if not is_fig: # Don't save update when creating figures for consistency
            joblib.dump(birch, birch_path)
            joblib.dump(ipca, ipca_path)

    # Filter out None results
    labeled_dfs = [df for df in results if df is not None]
    i = 0
    for df in labeled_dfs:
        df['cluster_epoch'] = i
        i+=1

    # Show clustered page region map
    final_df = pd.concat(labeled_dfs, ignore_index=True)

    if not is_birch:
        # Remove unclustered data points, if using DBSCAN
        final_df = final_df[final_df['cluster'] != -1.0]

    print(final_df)

    if not mem_prof:
        # Log Timing info for performance analysis
        if is_birch:
            clustering_time_file = "./birch_cluster_time.log"
        else:
            clustering_time_file = "./dbscan_cluster_time.log"

        workload_name = os.path.splitext(os.path.basename(pebs_file))[0]
        with open(clustering_time_file, 'a') as f:
            f.write(workload_name + "\n")
            f.write(str(N) + "\n")
            f.write(str(pebs_rate) + "\n")
            for entry in cluster_times:
                f.write(str(entry[0]) + "," + str(entry[1]) + "\n")
            f.write("---\n")
    else:
        # Log Memory Usage info for performance analysis
        if is_birch:
            clustering_time_file = "./birch_cluster_memory.log"
        else:
            clustering_time_file = "./dbscan_cluster_memory.log"

        workload_name = os.path.splitext(os.path.basename(pebs_file))[0]
        with open(clustering_time_file, 'a') as f:
            f.write(workload_name + "\n")
            f.write(str(N) + "\n")
            f.write(str(pebs_rate) + "\n")
            for entry in cluster_mem:
                f.write(str(entry[0]) + "," + str(entry[1]) + "\n")
            f.write("---\n")

    if not is_fig:
        exit()

    print("Generating cluster figure...")

    # Save cluster labels for all VMA regions in case we want to look at libraries etc.
    final_df.to_csv(csv_output_file, index=False)

    print("filtering pages...")
    filter_s = time.time()
    # Filter out pages that aren't in the region we want to plot.
    if filtered_vma_df is not None:
        unique_pages = pd.DataFrame({'PageFrame': final_df['PageFrame'].unique()})
        unique_pages['rno'] = unique_pages.apply(lambda row: find_region_id(row, filtered_vma_df), axis=1)
        unique_pages = unique_pages.dropna().reset_index(drop=True)

        final_df = final_df[final_df['PageFrame'].isin(unique_pages['PageFrame'])]
    else:
        print("No VMA filtering applied - using all pages")
    filter_e = time.time()
    print("Done filter {} s".format(filter_e - filter_s))

    #final_df = final_df.merge(cluster_map, on='cluster', how='left')

    save_cluster_fig(cluster_fig_output_file, final_df, 'cluster')
    save_cluster_fig(label_fig_output_file, final_df, 'label')

    def generate_pebs_figure(file):
        base,_ = os.path.splitext(file)
        output_file = base + "_pebs_heatmap.png"
        print("Checking {}".format(output_file))

        if os.path.isfile(output_file):
            print("Skipping {}".format(output_file))
            return

        df = prepare_pebs_df(file)
        df = df[df['value'] != 0.0] # Filter out 0 value entries
        plt.figure(figsize=(12, 12))
        #sns.heatmap(df, cmap="viridis", cbar=True, norm=LogNorm())

        #xmin = df['epoch'].min()
        #xmax = df['epoch'].max()

        # Draw a horizontal line at y = some_value
        if not final_df.empty:
            ymax = final_df['PageFrame'].max()
            ymin = final_df['PageFrame'].min()
            #plt.hlines(y=ymax, xmin=xmin, xmax=xmax, colors='red', linestyles='dashed')
            #plt.hlines(y=ymin, xmin=xmin, xmax=xmax, colors='red', linestyles='dashed')

            df = df[df['PageFrame'] >= ymin]
            df = df[df['PageFrame'] <= ymax]
        # If we want to use plt instead of sns
        plt.scatter(df['epoch'], df['PageFrame'], c=df['value'], s=50, norm=LogNorm(), edgecolor='none', rasterized=True, alpha=0.7, marker='.')

        ax = plt.gca()
        ## 1) Define a hex‐formatter: takes a float x and returns e.g. '0x1a3f'
        hex_formatter = FuncFormatter(lambda x, pos: hex(int(x)))

        ## 2) Install it on the y‐axis
        ax.yaxis.set_major_formatter(hex_formatter)
        ax.invert_yaxis()

        plt.xlabel("Time (s)")
        plt.ylabel("Page Frame")
        plt.title(file + ": PEBS")
        #plt.show()
        plt.savefig(output_file, dpi=300, bbox_inches="tight")

    generate_pebs_figure(pebs_file)
