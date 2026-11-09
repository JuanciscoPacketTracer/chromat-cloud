const DEFAULT_CONFIDENCE_THRESHOLD = 0.8;
const DEFAULT_CONSECUTIVE_EVENTS = 3;
const DEFAULT_MAXIMUM_AGE_MS = 7 * 24 * 60 * 60 * 1000;
const DEFAULT_MINIMUM_ALERT_INTERVAL_MS = 0;

function isValidDate(value) {
  return typeof value === "string" && !Number.isNaN(Date.parse(value));
}

export function applyObservation(state = {}, observation, config = {}) {
  const confidenceThreshold = config.confidenceThreshold ?? DEFAULT_CONFIDENCE_THRESHOLD;
  const consecutiveEvents = config.consecutiveEvents ?? DEFAULT_CONSECUTIVE_EVENTS;
  const maximumAgeMs = config.maximumAgeMs ?? DEFAULT_MAXIMUM_AGE_MS;
  const minimumAlertIntervalMs =
    config.minimumAlertIntervalMs ?? DEFAULT_MINIMUM_ALERT_INTERVAL_MS;
  const now = isValidDate(config.now) ? Date.parse(config.now) : Date.now();
  const occurredAt = isValidDate(observation.occurredAt)
    ? Date.parse(observation.occurredAt)
    : NaN;
  const invalid =
    !isValidDate(observation.occurredAt) ||
    observation.clockSuspect === true ||
    observation.reprocessing === true ||
    observation.isTest === true ||
    observation.official === false ||
    typeof observation.classification !== "string" ||
    typeof observation.confidence !== "number" ||
    observation.confidence < confidenceThreshold ||
    now - occurredAt > maximumAgeMs ||
    (state.lastOccurredAt && occurredAt <= Date.parse(state.lastOccurredAt));
  if (invalid) {
    return { accepted: false, state, transition: null };
  }

  const candidateStage = observation.classification;
  const consecutiveStage = state.consecutiveStage === candidateStage
    ? state.consecutiveStage
    : candidateStage;
  const consecutiveCount = state.consecutiveStage === candidateStage
    ? (state.consecutiveCount ?? 0) + 1
    : 1;
  const nextState = {
    ...state,
    consecutiveStage,
    consecutiveCount,
    lastOccurredAt: observation.occurredAt,
    lastConfidence: observation.confidence,
  };
  const historyEntry = {
    classification: candidateStage,
    confidence: observation.confidence,
    occurredAt: observation.occurredAt,
    consecutiveStage,
    consecutiveCount,
    currentStage: state.currentStage ?? null,
    episodeSeq: state.episodeSeq ?? 0,
    transition: null,
  };
  if (
    consecutiveCount < consecutiveEvents ||
    state.currentStage === candidateStage
  ) {
    return {
      accepted: true,
      state: { ...nextState, historyEntry },
      transition: null,
    };
  }

  const transition = {
    fromStage: state.currentStage ?? null,
    toStage: candidateStage,
    episodeSeq: (state.episodeSeq ?? 0) + 1,
    alertEligible: !(
      candidateStage === "maduro" &&
      isValidDate(state.lastAlertAt) &&
      now - Date.parse(state.lastAlertAt) < minimumAlertIntervalMs
    ),
  };
  const transitionedHistoryEntry = {
    ...historyEntry,
    currentStage: candidateStage,
    episodeSeq: transition.episodeSeq,
    transition,
  };
  return {
    accepted: true,
    state: {
      ...nextState,
      currentStage: candidateStage,
      episodeSeq: transition.episodeSeq,
      historyEntry: transitionedHistoryEntry,
    },
    transition,
  };
}
