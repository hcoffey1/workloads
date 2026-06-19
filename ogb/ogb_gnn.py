import os
import time
import torch
import torch.nn.functional as F

# torch >=2.6 defaults torch.load(weights_only=True), which rejects the
# torch_geometric globals in OGB's processed .pt files. The dataset is generated
# locally by ogb (trusted), so restore the permissive load.
_orig_torch_load = torch.load
def _trusted_load(*args, **kwargs):
    kwargs.setdefault("weights_only", False)
    return _orig_torch_load(*args, **kwargs)
torch.load = _trusted_load

from ogb.nodeproppred import PygNodePropPredDataset
from torch_geometric.loader import NeighborLoader
from torch_geometric.nn import SAGEConv

# ---------------------------------------------------------------------------
# Configuration (env-driven so scripts/workloads/ogb.sh can drive runs without
# editing this file).  Defaults reproduce the original standalone behaviour.
# ---------------------------------------------------------------------------
DATASET = os.getenv("OGB_DATASET", "ogbn-products")
DATA_ROOT = os.getenv("OGB_DATA_ROOT", "dataset/")
EPOCHS = int(os.getenv("OGB_EPOCHS", "3"))
BATCH_SIZE = int(os.getenv("OGB_BATCH_SIZE", "1024"))
# DataLoader workers are *processes* (Python GIL), which escape /usr/bin/time -v
# and the harness PID tracking.  Default 0 keeps everything in one OMP-threaded
# process; set OGB_NUM_WORKERS>0 to opt back into cross-process sampler overlap.
NUM_WORKERS = int(os.getenv("OGB_NUM_WORKERS", "0"))
# Honour OMP_NUM_THREADS for the intra-op (GEMM / sampling) thread pool, exactly
# like the OpenMP workloads (gapbs, faiss).
_omp = os.getenv("OMP_NUM_THREADS")
if _omp:
    torch.set_num_threads(int(_omp))

# This harness measures host/NUMA memory behaviour (numactl, bwmon, HeMem
# tiering), so execution is pinned to the CPU regardless of GPU availability.
device = torch.device("cpu")

# 1. Load the OGB Dataset (downloads + formats for PyG on first use)
print(f"Loading OGB dataset {DATASET} from {DATA_ROOT} ...")
dataset = PygNodePropPredDataset(name=DATASET, root=DATA_ROOT)
data = dataset[0]
split_idx = dataset.get_idx_split()

# 2. Setup NeighborLoader (the source of concurrent memory patterns: sparse
# topology walks during sampling + random feature-row gathers).
# Samples 15 neighbors for the first hop and 10 for the second hop.
train_loader = NeighborLoader(
    data,
    num_neighbors=[15, 10],
    batch_size=BATCH_SIZE,
    input_nodes=split_idx["train"],
    shuffle=True,
    num_workers=NUM_WORKERS,
    persistent_workers=NUM_WORKERS > 0,
)

# 3. Define a 2-Layer GraphSAGE Model
class GraphSAGE(torch.nn.Module):
    def __init__(self, in_channels, hidden_channels, out_channels):
        super().__init__()
        self.conv1 = SAGEConv(in_channels, hidden_channels)
        self.conv2 = SAGEConv(hidden_channels, out_channels)

    def forward(self, x, edge_index):
        x = self.conv1(x, edge_index)
        x = F.relu(x)
        x = F.dropout(x, p=0.5, training=self.training)
        x = self.conv2(x, edge_index)
        return x

model = GraphSAGE(dataset.num_features, 256, dataset.num_classes).to(device)
optimizer = torch.optim.Adam(model.parameters(), lr=0.01)

print(
    f"device={device} threads={torch.get_num_threads()} "
    f"epochs={EPOCHS} batch_size={BATCH_SIZE} num_workers={NUM_WORKERS} "
    f"features={dataset.num_features} classes={dataset.num_classes}"
)

# 4. Training Loop (where the memory system gets thrashed)
model.train()
for epoch in range(1, EPOCHS + 1):
    start_time = time.time()
    total_loss = 0

    # Each iteration triggers concurrent topology-walks and feature-pulls.
    for step, batch in enumerate(train_loader):
        batch = batch.to(device)
        optimizer.zero_grad()

        # Forward pass on the dynamically constructed subgraph
        out = model(batch.x, batch.edge_index)

        # Compute loss only on the target "seed" nodes of the batch.
        # Labels can be float (e.g. ogbn-papers100M) so cast to long for NLL.
        target = batch.y[: batch.batch_size].squeeze().long()
        loss = F.cross_entropy(out[: batch.batch_size], target)
        loss.backward()
        optimizer.step()
        total_loss += loss.item()

    epoch_time = time.time() - start_time
    print(
        f"Epoch {epoch:02d} | Loss: {total_loss/len(train_loader):.4f} "
        f"| Time: {epoch_time:.2f}s"
    )
