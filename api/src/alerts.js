export function buildAlertCandidate({
  sourceId,
  crop,
  eventId,
  occurredAt,
  transition,
  chatId,
  isTest,
}) {
  if (
    isTest ||
    !transition ||
    transition.toStage !== "maduro" ||
    transition.alertEligible === false
  ) return null;
  return {
    sourceId,
    crop,
    eventId,
    occurredAt,
    fromStage: transition.fromStage,
    toStage: transition.toStage,
    episodeSeq: transition.episodeSeq,
    chatId,
    status: "pending",
  };
}
