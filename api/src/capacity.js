export function isBelowFreeSpaceThreshold(
  { availableBytes, totalBytes },
  minimumFreePercent,
) {
  if (
    !Number.isFinite(availableBytes) ||
    !Number.isFinite(totalBytes) ||
    totalBytes <= 0 ||
    availableBytes < 0
  ) {
    throw new Error("invalid_storage_stats");
  }
  return (availableBytes / totalBytes) * 100 < minimumFreePercent;
}
