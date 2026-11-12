import { applyObservation } from "./aggregation.js";
import { buildAlertCandidate } from "./alerts.js";
import { mysqlToIso, toMysqlTimestamp } from "./time.js";

export async function updateAggregatedState(
  connection,
  job,
  officialResult,
  aggregationConfig,
) {
  const [eventRows] = await connection.query(
    `SELECT e.occurred_at, e.clock_suspect, e.crop, s.is_test,
            a.chat_id
       FROM monitoring_events e
       JOIN monitoring_sources s ON s.source_id = e.source_id
       LEFT JOIN monitoring_source_alerts a
         ON a.source_id = e.source_id AND a.crop = e.crop
      WHERE e.source_id = ? AND e.event_id = ?
      FOR UPDATE`,
    [job.source_id, job.event_id],
  );
  const event = eventRows[0];
  if (!event) throw new Error("event_missing_for_aggregation");
  const [stateRows] = await connection.query(
    `SELECT current_stage, episode_seq, consecutive_stage, consecutive_count,
            last_occurred_at, last_confidence, aggregation_rule_version,
            aggregation_config, last_alert_at
       FROM monitoring_states
      WHERE source_id = ? AND crop = ?
      FOR UPDATE`,
    [job.source_id, event.crop],
  );
  const state = stateRows[0]
    ? {
        currentStage: stateRows[0].current_stage,
        episodeSeq: Number(stateRows[0].episode_seq),
        consecutiveStage: stateRows[0].consecutive_stage,
        consecutiveCount: Number(stateRows[0].consecutive_count),
        lastOccurredAt: stateRows[0].last_occurred_at
          ? mysqlToIso(stateRows[0].last_occurred_at)
          : null,
        lastConfidence: stateRows[0].last_confidence == null
          ? null
          : Number(stateRows[0].last_confidence),
        aggregationRuleVersion: stateRows[0].aggregation_rule_version,
        aggregationConfig: typeof stateRows[0].aggregation_config === "string"
          ? JSON.parse(stateRows[0].aggregation_config)
          : stateRows[0].aggregation_config,
        lastAlertAt: stateRows[0].last_alert_at
          ? mysqlToIso(stateRows[0].last_alert_at)
          : null,
      }
    : {};
  const result = applyObservation(
    state,
    {
      classification: officialResult.classification,
      confidence: officialResult.confidence,
      occurredAt: mysqlToIso(event.occurred_at),
      clockSuspect: Boolean(event.clock_suspect),
      isTest: Boolean(event.is_test),
      official: true,
      reprocessing: Boolean(job.reprocessing),
    },
    aggregationConfig,
  );
  if (!result.accepted) return;
  const historyEntry = result.state.historyEntry;
  await connection.query(
    `INSERT INTO monitoring_state_history
      (source_id, crop, event_id, occurred_at, classification, confidence,
       consecutive_stage, consecutive_count, current_stage, episode_seq,
       transition, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, UTC_TIMESTAMP(3))`,
    [
      job.source_id,
      event.crop,
      job.event_id,
      toMysqlTimestamp(new Date(historyEntry.occurredAt)),
      historyEntry.classification,
      historyEntry.confidence,
      historyEntry.consecutiveStage,
      historyEntry.consecutiveCount,
      historyEntry.currentStage,
      historyEntry.episodeSeq,
      historyEntry.transition ? JSON.stringify(historyEntry.transition) : null,
    ],
  );
  const configurationJson = JSON.stringify(aggregationConfig);
  const [ruleRows] = await connection.query(
    `SELECT configuration
       FROM aggregation_rule_versions
      WHERE rule_version = ?
      FOR UPDATE`,
    [aggregationConfig.ruleVersion],
  );
  if (ruleRows.length > 0) {
    const storedConfiguration = typeof ruleRows[0].configuration === "string"
      ? JSON.parse(ruleRows[0].configuration)
      : ruleRows[0].configuration;
    if (JSON.stringify(storedConfiguration) !== configurationJson) {
      throw new Error("aggregation_rule_version_mismatch");
    }
  } else {
    await connection.query(
      `INSERT INTO aggregation_rule_versions
        (rule_version, configuration, created_at)
       VALUES (?, ?, UTC_TIMESTAMP(3))`,
      [aggregationConfig.ruleVersion, configurationJson],
    );
  }
  await connection.query(
    `INSERT INTO monitoring_states
      (source_id, crop, current_stage, episode_seq, consecutive_stage,
       consecutive_count, last_occurred_at, last_confidence,
       aggregation_rule_version, aggregation_config, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, UTC_TIMESTAMP(3))
     ON DUPLICATE KEY UPDATE
       current_stage = VALUES(current_stage),
       episode_seq = VALUES(episode_seq),
       consecutive_stage = VALUES(consecutive_stage),
       consecutive_count = VALUES(consecutive_count),
       last_occurred_at = VALUES(last_occurred_at),
       last_confidence = VALUES(last_confidence),
       aggregation_rule_version = VALUES(aggregation_rule_version),
       aggregation_config = VALUES(aggregation_config),
       updated_at = VALUES(updated_at)`,
    [
      job.source_id,
      event.crop,
      result.state.currentStage ?? null,
      result.state.episodeSeq ?? 0,
      result.state.consecutiveStage ?? null,
      result.state.consecutiveCount ?? 0,
      result.state.lastOccurredAt
        ? toMysqlTimestamp(new Date(result.state.lastOccurredAt))
        : null,
      result.state.lastConfidence ?? null,
      aggregationConfig.ruleVersion,
      JSON.stringify(aggregationConfig),
    ],
  );
  const alert = buildAlertCandidate({
    sourceId: job.source_id,
    crop: event.crop,
    eventId: job.event_id,
    occurredAt: historyEntry.occurredAt,
    transition: historyEntry.transition,
    chatId: event.chat_id ?? null,
    isTest: Boolean(event.is_test),
  });
  if (alert) {
    const [alertInsert] = await connection.query(
      `INSERT IGNORE INTO monitoring_alerts
        (source_id, crop, event_id, from_stage, to_stage, episode_seq,
         chat_id, status, attempts, available_at, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, UTC_TIMESTAMP(3),
               UTC_TIMESTAMP(3))`,
      [
        alert.sourceId,
        alert.crop,
        alert.eventId,
        alert.fromStage,
        alert.toStage,
        alert.episodeSeq,
        alert.chatId,
      ],
    );
    if (alertInsert.affectedRows === 1) {
      await connection.query(
        `UPDATE monitoring_states
            SET last_alert_at = UTC_TIMESTAMP(3)
          WHERE source_id = ? AND crop = ?`,
        [job.source_id, event.crop],
      );
    }
  }
}