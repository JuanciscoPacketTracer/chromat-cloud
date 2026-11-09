export function buildTelegramMessage({
  sourceName,
  crop,
  eventId,
  fromStage,
  toStage,
  occurredAt,
  panelUrl,
}) {
  return [
    "CHROMAT: cambio de etapa",
    `Fuente: ${sourceName}`,
    `Cultivo: ${crop}`,
    `Evento: ${eventId}`,
    `Etapa: ${fromStage ?? "-"} -> ${toStage}`,
    `Momento: ${occurredAt}`,
    `Panel: ${panelUrl}`,
  ].join("\n");
}

export function classifyTelegramResponse(statusCode, body) {
  if (statusCode >= 200 && statusCode < 300 && body?.ok === true) {
    return { kind: "sent" };
  }
  if (statusCode === 429) {
    const retryAfterSeconds = Number(body?.parameters?.retry_after);
    return {
      kind: "retry",
      retryAfterSeconds: Number.isFinite(retryAfterSeconds)
        ? Math.max(1, retryAfterSeconds)
        : 60,
      error: "telegram_rate_limited",
    };
  }
  if (statusCode >= 400 && statusCode < 500) {
    return {
      kind: "permanent",
      error: String(body?.description ?? "telegram_request_rejected").slice(0, 255),
    };
  }
  return {
    kind: "retry",
    retryAfterSeconds: 60,
    error: String(body?.description ?? "telegram_unavailable").slice(0, 255),
  };
}
