export function toMysqlTimestamp(timestamp) {
  return timestamp.toISOString().replace("T", " ").replace("Z", "");
}

export function mysqlToIso(value) {
  if (value instanceof Date) return value.toISOString();
  return `${value.replace(" ", "T")}Z`;
}
