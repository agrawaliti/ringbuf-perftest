#!/bin/bash
set -euo pipefail

# Install Retina on a cluster with specified buffer mode
# Usage: ./2-setup-retina.sh <cluster-name> <resource-group> <disabled|enabled>

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> <resource-group> <disabled|enabled>}"
RG="${2:?Usage: $0 <cluster-name> <resource-group> <disabled|enabled>}"
RINGBUF_MODE="${3:?Usage: $0 <cluster-name> <resource-group> <disabled|enabled>}"

echo "============================================"
echo "Setting up Retina on: $CLUSTER_NAME"
echo "Ring buffer mode:     $RINGBUF_MODE"
echo "============================================"

# Get credentials
az aks get-credentials --resource-group "$RG" --name "$CLUSTER_NAME" --overwrite-existing

# Install Retina via Helm
helm upgrade --install retina-perf oci://ghcr.io/microsoft/retina/charts/retina \
    --version v1.2.0 \
    --namespace kube-system \
    --set os.linux=true \
    --set os.windows=false \
    --set operator.enabled=false \
    --set logLevel=info \
    --set enabledPlugin_linux='["linuxutil"\,"packetforward"\,"packetparser"\,"dns"\,"dropreason"]' \
    --set image.tag=v1.2.0 \
    --set agent.enabled=true \
    --set enablePodLevel=true \
    --set enableTelemetry=false \
    --set packetParserRingBuffer="$RINGBUF_MODE" \
    --set packetParserRingBufferSize=8388608

echo ""
echo "Waiting for Retina pods to be ready..."
kubectl rollout status daemonset/retina-agent -n kube-system --timeout=120s 2>/dev/null || sleep 30

# Handle Eno-managed configmap conflict (AKS-managed retina override)
# Check if configmap has stale values
CM_TELEMETRY=$(kubectl get configmap retina-config -n kube-system -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -c "enableTelemetry: true" || true)
if [[ "$CM_TELEMETRY" -gt 0 ]]; then
    echo "Fixing Eno-managed configmap..."
    kubectl label configmap retina-config -n kube-system app.kubernetes.io/managed-by=Helm --overwrite

    if [[ "$RINGBUF_MODE" == "enabled" ]]; then
        RINGBUF_CONFIG="packetParserRingBuffer: enabled\npacketParserRingBufferSize: 8388608"
    else
        RINGBUF_CONFIG="packetParserRingBuffer: disabled\npacketParserRingBufferSize: 8388608"
    fi

    kubectl patch configmap retina-config -n kube-system --type merge -p "{\"data\":{\"config.yaml\":\"apiServer:\\n  host: \\\"0.0.0.0\\\"\\n  port: 10093\\nlogLevel: info\\nenabledPlugin: [\\\"linuxutil\\\",\\\"packetforward\\\",\\\"packetparser\\\",\\\"dns\\\",\\\"dropreason\\\"]\\nmetricsInterval: 10s\\nmetricsIntervalDuration: 10s\\nenableTelemetry: false\\nenablePodLevel: true\\nenableConntrackMetrics: false\\nremoteContext: false\\nenableAnnotations: false\\nbypassLookupIPOfInterest: false\\ndataAggregationLevel: low\\ntelemetryInterval: 15m\\ndataSamplingRate: 1\\n${RINGBUF_CONFIG}\\nfilterMapMaxEntries: 255\"}}"

    echo "Restarting Retina pods..."
    kubectl delete pods -n kube-system -l k8s-app=retina
    sleep 15
fi

# Verify pods are running
echo ""
echo "Retina pod status:"
kubectl get pods -n kube-system -l k8s-app=retina -o wide

echo ""
echo "Verifying packetparser config:"
RETINA_POD=$(kubectl get pods -n kube-system -l k8s-app=retina -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n kube-system "$RETINA_POD" 2>&1 | grep -i "ring\|perf.*reader\|Initializing" | head -5 || echo "  (no matching log lines yet)"

echo ""
echo "Retina setup complete for $CLUSTER_NAME (mode=$RINGBUF_MODE)"
