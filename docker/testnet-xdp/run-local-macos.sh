#!/bin/bash
# Run a local testnet node on macOS (UDP fallback, no AF_XDP)
# This acts as the "second machine" connecting to the Docker testnet
#
# Usage:
#   ./run-local-macos.sh [shard]
#   ./run-local-macos.sh 0        # join shard 0
#   ./run-local-macos.sh meta     # join metachain
#
# Prerequisites:
#   - mx-chain-go built: cd cmd/node && go build
#   - Docker testnet running: docker compose up -d
#
# XDP behavior on macOS:
#   - Phase 1 (custom XDP): falls back to UDP socket (no AF_XDP)
#   - Phase 2 (QUIC accel): falls back to net.ListenUDP (standard kernel)
#   - All libp2p features work normally

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
NODE_BIN="$ROOT_DIR/cmd/node/node"
CONFIG_DIR="$ROOT_DIR/cmd/node/config"
DATA_DIR="/tmp/mx-testnet-local"
SHARD="${1:-0}"

# Docker testnet seednode address (adjust if using remote Coolify)
SEEDNODE_ADDR="/ip4/127.0.0.1/tcp/9999/p2p/16Uiu2HAkw5SNNtSvH1zJiQ6Gc3WoGNSxiyNueRKe6fuAuh57G3Bk"

echo "=== MultiversX Local Testnet Node (macOS) ==="
echo "Shard: $SHARD"
echo "Data dir: $DATA_DIR"
echo "Seednode: $SEEDNODE_ADDR"
echo ""

# Build if needed
if [ ! -f "$NODE_BIN" ]; then
    echo "Building node binary..."
    cd "$ROOT_DIR/cmd/node" && go build -v
fi

# Create data directory
mkdir -p "$DATA_DIR"

# Create local p2p config with XDP enabled (will use UDP fallback on macOS)
cat > "$DATA_DIR/p2p.toml" << 'EOF'
[Node]
    Port = "37380-37390"
    ThresholdMinConnectedPeers = 2
    MinNumPeersToWaitForOnBootstrap = 2

    [Node.Transports]
        QUICAddress = "/ip4/0.0.0.0/udp/%d/quic-v1"
        WebSocketAddress = ""
        WebTransportAddress = ""
        [Node.Transports.TCP]
            ListenAddress = "/ip4/0.0.0.0/tcp/%d"
            PreventPortReuse = false

    [Node.ResourceLimiter]
        Type = "default autoscale"

[KadDhtPeerDiscovery]
    Enabled = true
    Type = "optimized"
    RefreshIntervalInSec = 10
    ProtocolIDs = ["/erd/kad/1.0.0", "xdp-testnet"]
EOF

# Append seednode address
echo "    InitialPeerList = [\"$SEEDNODE_ADDR\"]" >> "$DATA_DIR/p2p.toml"

cat >> "$DATA_DIR/p2p.toml" << 'EOF'
    BucketSize = 100
    RoutingTableRefreshIntervalInSec = 300

[Sharding]
    TargetPeerCount = 10
    MaxIntraShardValidators = 3
    MaxCrossShardValidators = 3
    MaxIntraShardObservers = 2
    MaxCrossShardObservers = 2
    MaxSeeders = 2
    Type = "ListsSharder"

[XDP]
    Enabled = true
    AccelerateQUIC = true
    Port = 37374
    Interface = ""
    QueueSize = 2048
    BatchSize = 64

    [XDP.Security]
        KeyRotationIntervalSec = 86400
        ReplayWindowSize = 100000
        TimestampToleranceSec = 60
EOF

echo "Starting node..."
echo "(XDP will use UDP fallback on macOS — this is expected)"
echo ""

# Determine shard flag
if [ "$SHARD" = "meta" ] || [ "$SHARD" = "metachain" ]; then
    SHARD_FLAG="--destination-shard-as-observer=metachain"
else
    SHARD_FLAG="--destination-shard-as-observer=$SHARD"
fi

exec "$NODE_BIN" \
    --rest-api-interface=0.0.0.0:8084 \
    --config="$CONFIG_DIR/config.toml" \
    --p2p-config="$DATA_DIR/p2p.toml" \
    --working-directory="$DATA_DIR" \
    $SHARD_FLAG
