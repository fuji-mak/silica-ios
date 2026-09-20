export class ApiError extends Error {
  constructor(code, status = 400) {
    super(code);
    this.name = "ApiError";
    this.code = code;
    this.status = status;
  }
}

const INSTALLATION_ID_PATTERN = /^si_[A-Za-z0-9_-]{16,80}$/;
const NOTION_ID_PATTERN = /^[A-Za-z0-9_-]{8,80}$/;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const ISO_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

function stringField(value, name, maxLength, { required = false } = {}) {
  if (value === undefined || value === null) {
    if (required) throw new ApiError(`missing_${name}`);
    return undefined;
  }

  if (typeof value !== "string") throw new ApiError(`invalid_${name}`);
  const normalized = value.replaceAll("\u0000", "").trim();

  if (required && normalized.length === 0) throw new ApiError(`missing_${name}`);
  if (normalized.length > maxLength) throw new ApiError(`${name}_too_long`, 413);
  return normalized;
}

function objectPayload(payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new ApiError("invalid_payload");
  }
  return payload;
}

export function assertInstallationId(value) {
  if (typeof value !== "string" || !INSTALLATION_ID_PATTERN.test(value)) {
    throw new ApiError("invalid_installation", 401);
  }
  return value;
}

export function assertNotionId(value, name) {
  if (typeof value !== "string" || !NOTION_ID_PATTERN.test(value)) {
    throw new ApiError(`invalid_${name}`);
  }
  return value;
}

export function parseReturnUrl(value) {
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value !== "string" || value.length > 240) {
    throw new ApiError("invalid_return_url");
  }
  return value;
}

export function parseFeedbackPayload(payload) {
  const body = objectPayload(payload);
  const kind = stringField(body.kind, "kind", 16, { required: true });
  if (!["bug", "feature", "question", "other"].includes(kind)) {
    throw new ApiError("invalid_kind");
  }

  const title = stringField(body.title, "title", 160, { required: true });
  const message = stringField(body.message, "message", 6000, { required: true });
  const contactEmail = stringField(body.contactEmail, "contact_email", 240);

  if (contactEmail && !EMAIL_PATTERN.test(contactEmail)) {
    throw new ApiError("invalid_contact_email");
  }

  return {
    kind,
    title,
    message,
    contactEmail,
    appVersion: stringField(body.appVersion, "app_version", 48),
    osVersion: stringField(body.osVersion, "os_version", 80),
    deviceModel: stringField(body.deviceModel, "device_model", 100),
    locale: stringField(body.locale, "locale", 24),
    hasPro: typeof body.hasPro === "boolean" ? body.hasPro : undefined,
  };
}

export function parseSearchPayload(payload) {
  const body = objectPayload(payload);
  return {
    query: stringField(body.query, "query", 200),
    startCursor: stringField(body.startCursor, "start_cursor", 120),
  };
}

export function parseSyncPayload(payload) {
  const body = objectPayload(payload);
  const markdown = stringField(body.markdown, "markdown", 200_000, { required: true });
  const date = stringField(body.date, "date", 10);
  if (date && !ISO_DATE_PATTERN.test(date)) {
    throw new ApiError("invalid_date");
  }
  const pageId = body.pageId ? assertNotionId(body.pageId, "page_id") : undefined;
  const parentPageId = body.parentPageId
    ? assertNotionId(body.parentPageId, "parent_page_id")
    : undefined;
  const dataSourceId = body.dataSourceId
    ? assertNotionId(body.dataSourceId, "data_source_id")
    : undefined;

  if (!pageId && !parentPageId && !dataSourceId) {
    throw new ApiError("parent_required");
  }

  if (pageId && (parentPageId || dataSourceId)) {
    throw new ApiError("ambiguous_parent");
  }

  return { markdown, date, pageId, parentPageId, dataSourceId };
}
