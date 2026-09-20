import {
  base64UrlDecode,
  decryptString,
  encryptString,
  hmacSha256,
  randomToken,
  sha256,
  timingSafeEqual,
} from "./crypto.js";
import {
  ApiError,
  assertInstallationId,
  parseFeedbackPayload,
  parseReturnUrl,
  parseSearchPayload,
  parseSyncPayload,
} from "./validation.js";

const API_PREFIX = "/api/silica";
const NOTION_VERSION = "2026-03-11";
const MAX_BODY_BYTES = 220_000;
const SIGNATURE_MAX_AGE_SECONDS = 300;
const OAUTH_STATE_TTL_SECONDS = 600;
const NONCE_TTL_SECONDS = 600;

const DEFAULT_WEB_ORIGIN = "http://localhost:3000";
const DEFAULT_RETURN_URL = `${DEFAULT_WEB_ORIGIN}/silica?notion=connected`;
const DEFAULT_ALLOWED_ORIGINS = [
  DEFAULT_WEB_ORIGIN,
  "http://localhost:3000",
  "http://localhost:3001",
];

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

function json(request, payload, status = 200, extraHeaders = {}, env) {
  const headers = new Headers({
    "Cache-Control": "no-store",
    "Content-Type": "application/json; charset=utf-8",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "Permissions-Policy": "geolocation=(), microphone=(), camera=()",
    ...extraHeaders,
  });
  applyCors(request, headers, env);
  return new Response(JSON.stringify(payload), { status, headers });
}

function redirect(location) {
  return new Response(null, {
    status: 302,
    headers: {
      "Cache-Control": "no-store",
      Location: location,
      "Referrer-Policy": "no-referrer",
    },
  });
}

function allowedOrigins(env) {
  const configured = env.ALLOWED_ORIGINS
    ?.split(",")
    .map((origin) => origin.trim())
    .filter(Boolean);
  return configured?.length ? configured : DEFAULT_ALLOWED_ORIGINS;
}

function applyCors(request, headers, env) {
  const origin = request.headers.get("Origin");
  if (!origin || !allowedOrigins(env).includes(origin)) return;
  headers.set("Access-Control-Allow-Origin", origin);
  headers.set("Access-Control-Allow-Credentials", "false");
  headers.set("Vary", "Origin");
}

function applyPreflight(request, env) {
  const origin = request.headers.get("Origin");
  if (origin && !allowedOrigins(env).includes(origin)) {
    return json(request, { error: "origin_not_allowed" }, 403, {}, env);
  }

  const headers = new Headers({
    "Access-Control-Allow-Headers": [
      "Content-Type",
      "X-Silica-Installation",
      "X-Silica-Timestamp",
      "X-Silica-Nonce",
      "X-Silica-Signature",
    ].join(", "),
    "Access-Control-Allow-Methods": "DELETE, GET, OPTIONS, POST",
    "Access-Control-Max-Age": "600",
    "Cache-Control": "no-store",
  });
  applyCors(request, headers, env);
  return new Response(null, { status: 204, headers });
}

function safeNumber(value) {
  const number = Number(value);
  return Number.isSafeInteger(number) ? number : undefined;
}

async function readJson(request) {
  const contentLength = safeNumber(request.headers.get("Content-Length"));
  if (contentLength && contentLength > MAX_BODY_BYTES) {
    throw new ApiError("payload_too_large", 413);
  }

  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > MAX_BODY_BYTES) {
    throw new ApiError("payload_too_large", 413);
  }
  if (!text) return { bodyText: "", body: {} };

  try {
    return { bodyText: text, body: JSON.parse(text) };
  } catch {
    throw new ApiError("invalid_json");
  }
}

async function clientIpHash(request, env) {
  const rawIp =
    request.headers.get("CF-Connecting-IP") ??
    request.headers.get("X-Forwarded-For")?.split(",")[0]?.trim() ??
    "unknown";
  return sha256(`${env.TOKEN_ENCRYPTION_KEY}:${rawIp}`);
}

async function consumeRateLimit(env, key, limit, windowSeconds) {
  const current = nowSeconds();
  const windowStart = current - (current % windowSeconds);
  await env.DB.prepare(
    `INSERT INTO rate_limits (key, window_start, count)
     VALUES (?, ?, 1)
     ON CONFLICT(key) DO UPDATE SET
       count = CASE
         WHEN rate_limits.window_start = excluded.window_start THEN rate_limits.count + 1
         ELSE 1
       END,
       window_start = excluded.window_start`,
  )
    .bind(key, windowStart)
    .run();

  const row = await env.DB.prepare("SELECT count FROM rate_limits WHERE key = ?")
    .bind(key)
    .first();
  return Number(row?.count ?? 0) <= limit;
}

async function authenticateSignedRequest(request, env, bodyText) {
  const installationId = assertInstallationId(
    request.headers.get("X-Silica-Installation"),
  );
  const timestamp = Number(request.headers.get("X-Silica-Timestamp"));
  const nonce = request.headers.get("X-Silica-Nonce") ?? "";
  const signature = request.headers.get("X-Silica-Signature") ?? "";

  if (!Number.isInteger(timestamp) || Math.abs(nowSeconds() - timestamp) > SIGNATURE_MAX_AGE_SECONDS) {
    throw new ApiError("stale_request", 401);
  }
  if (!/^[A-Za-z0-9_-]{16,120}$/.test(nonce) || !/^[A-Za-z0-9_-]{40,100}$/.test(signature)) {
    throw new ApiError("invalid_signature", 401);
  }

  const installation = await env.DB.prepare(
    "SELECT secret_ciphertext FROM installations WHERE installation_id = ?",
  )
    .bind(installationId)
    .first();
  if (!installation) throw new ApiError("invalid_installation", 401);

  const secret = await decryptString(
    installation.secret_ciphertext,
    env.TOKEN_ENCRYPTION_KEY,
  );
  const signingPayload = [
    timestamp,
    nonce,
    request.method.toUpperCase(),
    new URL(request.url).pathname,
    bodyText,
  ].join("\n");
  const expectedSignature = await hmacSha256(secret, signingPayload);
  if (!timingSafeEqual(expectedSignature, signature)) {
    throw new ApiError("invalid_signature", 401);
  }

  const nonceResult = await env.DB.prepare(
    "INSERT OR IGNORE INTO request_nonces (nonce, installation_id, expires_at) VALUES (?, ?, ?)",
  )
    .bind(nonce, installationId, nowSeconds() + NONCE_TTL_SECONDS)
    .run();
  if (Number(nonceResult.meta?.changes ?? 0) !== 1) {
    throw new ApiError("replayed_request", 401);
  }

  await env.DB.prepare(
    "UPDATE installations SET last_seen_at = ? WHERE installation_id = ?",
  )
    .bind(nowSeconds(), installationId)
    .run();

  return installationId;
}

function requireConfigured(env, keys) {
  for (const key of keys) {
    if (!env[key]) throw new ApiError("server_not_configured", 500);
  }
}

async function handleBootstrap(request, env) {
  requireConfigured(env, ["DB", "TOKEN_ENCRYPTION_KEY"]);
  const ipHash = await clientIpHash(request, env);
  if (!(await consumeRateLimit(env, `bootstrap:${ipHash}`, 5, 3600))) {
    throw new ApiError("rate_limited", 429);
  }

  const installationId = `si_${randomToken(18)}`;
  const installationSecret = randomToken(32);
  await env.DB.prepare(
    `INSERT INTO installations
      (installation_id, secret_ciphertext, created_at, last_seen_at)
     VALUES (?, ?, ?, ?)`,
  )
    .bind(
      installationId,
      await encryptString(installationSecret, env.TOKEN_ENCRYPTION_KEY),
      nowSeconds(),
      nowSeconds(),
    )
    .run();

  return json(request, { installationId, installationSecret }, 201, {}, env);
}

function defaultReturnUrl(env) {
  return env.PUBLIC_WEB_ORIGIN
    ? `${env.PUBLIC_WEB_ORIGIN.replace(/\/$/, "")}/silica?notion=connected`
    : DEFAULT_RETURN_URL;
}

function isAllowedReturnUrl(value, env) {
  if (!value) return defaultReturnUrl(env);
  const webOrigin = (env.PUBLIC_WEB_ORIGIN || DEFAULT_WEB_ORIGIN).replace(/\/$/, "");
  const configured = env.NOTION_RETURN_URLS
    ?.split(",")
    .map((url) => url.trim())
    .filter(Boolean);
  const allowed = new Set([
    `${webOrigin}/silica?notion=connected`,
    `${webOrigin}/ja/silica?notion=connected`,
    "silica://notion/callback",
    ...(configured ?? []),
  ]);
  if (!allowed.has(value)) throw new ApiError("invalid_return_url");
  return value;
}

async function handleNotionAuthorize(request, env, bodyText, body) {
  requireConfigured(env, [
    "DB",
    "NOTION_CLIENT_ID",
    "NOTION_CLIENT_SECRET",
    "NOTION_REDIRECT_URI",
    "TOKEN_ENCRYPTION_KEY",
  ]);
  const installationId = await authenticateSignedRequest(request, env, bodyText);
  // Older apps cannot prove that the OAuth result returned to the initiating app.
  if (body.completionMode !== "app") throw new ApiError("notion_app_update_required", 426);
  const requestedReturnUrl = parseReturnUrl(body.returnUrl);
  const returnUrl = isAllowedReturnUrl(requestedReturnUrl, env);
  const state = randomToken(32);
  const current = nowSeconds();

  await env.DB.prepare(
    `INSERT INTO oauth_states
      (state_hash, installation_id, return_url, created_at, expires_at)
     VALUES (?, ?, ?, ?, ?)`,
  )
    .bind(
      await sha256(state),
      installationId,
      returnUrl,
      current,
      current + OAUTH_STATE_TTL_SECONDS,
    )
    .run();

  const authorizationUrl = new URL("https://api.notion.com/v1/oauth/authorize");
  authorizationUrl.searchParams.set("client_id", env.NOTION_CLIENT_ID);
  authorizationUrl.searchParams.set("response_type", "code");
  authorizationUrl.searchParams.set("owner", "user");
  authorizationUrl.searchParams.set("redirect_uri", env.NOTION_REDIRECT_URI);
  authorizationUrl.searchParams.set("state", state);

  return json(request, {
    authorizationUrl: authorizationUrl.toString(),
    expiresIn: OAUTH_STATE_TTL_SECONDS,
  }, 200, {}, env);
}

async function readOAuthState(env, state) {
  const row = await env.DB.prepare(
    `SELECT state_hash, installation_id, return_url
     FROM oauth_states
     WHERE state_hash = ? AND consumed_at IS NULL AND expires_at > ?`,
  )
    .bind(await sha256(state), nowSeconds())
    .first();
  if (!row) throw new ApiError("invalid_oauth_state", 400);

  const consumed = await env.DB.prepare(
    "UPDATE oauth_states SET consumed_at = ? WHERE state_hash = ? AND consumed_at IS NULL",
  )
    .bind(nowSeconds(), row.state_hash)
    .run();
  if (Number(consumed.meta?.changes ?? 0) !== 1) {
    throw new ApiError("invalid_oauth_state", 400);
  }
  return row;
}

function redirectWithStatus(returnUrl, status) {
  const destination = new URL(returnUrl);
  destination.searchParams.set("notion", status);
  return redirect(destination.toString());
}

async function exchangeNotionCode(env, code) {
  const basic = btoa(`${env.NOTION_CLIENT_ID}:${env.NOTION_CLIENT_SECRET}`);
  const response = await fetch("https://api.notion.com/v1/oauth/token", {
    method: "POST",
    headers: {
      Accept: "application/json",
      Authorization: `Basic ${basic}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      grant_type: "authorization_code",
      code,
      redirect_uri: env.NOTION_REDIRECT_URI,
    }),
  });
  if (!response.ok) {
    console.error("Notion OAuth token exchange failed", { status: response.status });
    throw new ApiError("notion_oauth_failed", 502);
  }
  const payload = await response.json();
  if (typeof payload.access_token !== "string" || payload.access_token.length < 20) {
    throw new ApiError("notion_oauth_failed", 502);
  }
  return payload;
}

async function handleNotionCallback(request, env) {
  requireConfigured(env, [
    "DB",
    "NOTION_CLIENT_ID",
    "NOTION_CLIENT_SECRET",
    "NOTION_REDIRECT_URI",
    "TOKEN_ENCRYPTION_KEY",
  ]);
  const url = new URL(request.url);
  const state = url.searchParams.get("state");
  if (!state) throw new ApiError("invalid_oauth_state");
  const oauthState = await readOAuthState(env, state);

  if (url.searchParams.get("error")) {
    return redirectWithStatus(oauthState.return_url, "denied");
  }

  const code = url.searchParams.get("code");
  if (!code || code.length > 500) throw new ApiError("missing_oauth_code");
  const token = await exchangeNotionCode(env, code);
  const ownerUserId = token.owner?.user?.id ?? null;
  const current = nowSeconds();
  const completionToken = randomToken(32);

  await env.DB.prepare(
    `INSERT INTO notion_pending_connections
      (completion_hash, installation_id, access_token_ciphertext, workspace_id,
       workspace_name, workspace_icon, bot_id, owner_user_id, created_at, expires_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      await sha256(completionToken),
      oauthState.installation_id,
      await encryptString(token.access_token, env.TOKEN_ENCRYPTION_KEY),
      token.workspace_id ?? null,
      token.workspace_name ?? null,
      token.workspace_icon ?? null,
      token.bot_id ?? null,
      ownerUserId,
      current,
      current + OAUTH_STATE_TTL_SECONDS,
    )
    .run();

  // Only the approving browser receives this proof. Knowing the original state
  // or polling status must not let another installation activate the connection.
  const destination = new URL(oauthState.return_url);
  destination.searchParams.set("notion", "pending");
  destination.searchParams.set("completionToken", completionToken);
  return redirect(destination.toString());
}

async function handleNotionComplete(request, env, bodyText, body) {
  requireConfigured(env, ["DB", "TOKEN_ENCRYPTION_KEY"]);
  const installationId = await authenticateSignedRequest(request, env, bodyText);
  if (typeof body.completionToken !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(body.completionToken)) {
    throw new ApiError("invalid_oauth_completion", 401);
  }
  const completionHash = await sha256(body.completionToken);
  const current = nowSeconds();
  // D1 batches are transactions: activation and proof consumption are atomic.
  const [activated] = await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO notion_connections
        (installation_id, access_token_ciphertext, workspace_id, workspace_name,
         workspace_icon, bot_id, owner_user_id, created_at, updated_at)
       SELECT installation_id, access_token_ciphertext, workspace_id, workspace_name,
              workspace_icon, bot_id, owner_user_id, created_at, ?
       FROM notion_pending_connections
       WHERE completion_hash = ? AND installation_id = ? AND expires_at > ?
       ON CONFLICT(installation_id) DO UPDATE SET
         access_token_ciphertext = excluded.access_token_ciphertext,
         workspace_id = excluded.workspace_id,
         workspace_name = excluded.workspace_name,
         workspace_icon = excluded.workspace_icon,
         bot_id = excluded.bot_id,
         owner_user_id = excluded.owner_user_id,
         updated_at = excluded.updated_at`,
    ).bind(current, completionHash, installationId, current),
    env.DB.prepare(
      "DELETE FROM notion_pending_connections WHERE completion_hash = ? AND installation_id = ?",
    ).bind(completionHash, installationId),
  ]);
  if (Number(activated.meta?.changes ?? 0) !== 1) {
    throw new ApiError("invalid_oauth_completion", 401);
  }
  return json(request, { connected: true }, 200, {}, env);
}

async function getNotionConnection(env, installationId) {
  const row = await env.DB.prepare(
    `SELECT installation_id, access_token_ciphertext, workspace_id,
       workspace_name, workspace_icon, updated_at
     FROM notion_connections WHERE installation_id = ?`,
  )
    .bind(installationId)
    .first();
  if (!row) throw new ApiError("notion_not_connected", 409);
  return {
    ...row,
    accessToken: await decryptString(row.access_token_ciphertext, env.TOKEN_ENCRYPTION_KEY),
  };
}

async function notionRequest(env, accessToken, path, init = {}) {
  const headers = new Headers(init.headers);
  headers.set("Accept", "application/json");
  headers.set("Authorization", `Bearer ${accessToken}`);
  headers.set("Notion-Version", NOTION_VERSION);
  if (init.body) headers.set("Content-Type", "application/json");

  const response = await fetch(`https://api.notion.com${path}`, {
    ...init,
    headers,
  });
  const text = await response.text();
  let payload = {};
  try {
    payload = text ? JSON.parse(text) : {};
  } catch {
    payload = {};
  }

  if (!response.ok) {
    console.error("Notion API request failed", { path, status: response.status });
    if (response.status === 401 || response.status === 403) {
      throw new ApiError("notion_reauthorization_required", 401);
    }
    if (response.status === 429) throw new ApiError("notion_rate_limited", 429);
    throw new ApiError("notion_request_failed", 502);
  }
  return payload;
}

async function handleNotionStatus(request, env, bodyText) {
  requireConfigured(env, ["DB", "TOKEN_ENCRYPTION_KEY"]);
  const installationId = await authenticateSignedRequest(request, env, bodyText);
  const row = await env.DB.prepare(
    `SELECT workspace_id, workspace_name, workspace_icon, updated_at
     FROM notion_connections WHERE installation_id = ?`,
  )
    .bind(installationId)
    .first();
  return json(request, {
    connected: Boolean(row),
    workspace: row
      ? {
          id: row.workspace_id,
          name: row.workspace_name,
          icon: row.workspace_icon,
        }
      : null,
    updatedAt: row?.updated_at ?? null,
  }, 200, {}, env);
}

async function handleNotionSearch(request, env, bodyText, body) {
  requireConfigured(env, ["DB", "TOKEN_ENCRYPTION_KEY"]);
  const installationId = await authenticateSignedRequest(request, env, bodyText);
  const query = parseSearchPayload(body);
  const connection = await getNotionConnection(env, installationId);
  const payload = await notionRequest(env, connection.accessToken, "/v1/search", {
    method: "POST",
    body: JSON.stringify({
      ...(query.query ? { query: query.query } : {}),
      ...(query.startCursor ? { start_cursor: query.startCursor } : {}),
      page_size: 100,
    }),
  });
  return json(request, {
    results: payload.results ?? [],
    nextCursor: payload.next_cursor ?? null,
    hasMore: Boolean(payload.has_more),
  }, 200, {}, env);
}

export function prepareNotionMarkdown(markdown) {
  return markdown
    .replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n?/, "")
    .replace(/^(?:\r?\n)+/, "");
}

export function buildNotionReplacePayload(markdown) {
  return {
    type: "replace_content",
    replace_content: {
      new_str: prepareNotionMarkdown(markdown),
      allow_deleting_content: false,
    },
  };
}

function dateFromMarkdown(markdown) {
  const match = markdown.match(/^date:\s*(\d{4}-\d{2}-\d{2})\s*$/m);
  return match?.[1] ?? null;
}

function syncPageTitle(sync) {
  return sync.date ?? dateFromMarkdown(sync.markdown) ?? "Silica Location Log";
}

function buildNotionTitleProperty(title) {
  return {
    title: [
      {
        type: "text",
        text: { content: title },
      },
    ],
  };
}

export function buildNotionCreatePayload({ parent, title, markdown, titlePropertyName = "title" }) {
  return {
    parent,
    properties: {
      [titlePropertyName]: buildNotionTitleProperty(title),
    },
    markdown: prepareNotionMarkdown(markdown),
  };
}

function childPageTitle(block) {
  const title = block?.child_page?.title;
  if (Array.isArray(title)) {
    return title.map((text) => text?.plain_text ?? text?.text?.content ?? "").join("").trim();
  }
  return typeof title === "string" ? title.trim() : "";
}

async function findChildPageByTitle(env, accessToken, parentPageId, title) {
  let startCursor;
  do {
    const params = new URLSearchParams({ page_size: "100" });
    if (startCursor) params.set("start_cursor", startCursor);
    const payload = await notionRequest(
      env,
      accessToken,
      `/v1/blocks/${encodeURIComponent(parentPageId)}/children?${params.toString()}`,
    );
    const match = (payload.results ?? []).find(
      (block) => block?.type === "child_page" && childPageTitle(block) === title,
    );
    if (match?.id) return { pageId: match.id, url: null };
    startCursor = payload.has_more ? payload.next_cursor : null;
  } while (startCursor);
  return null;
}

async function retrieveDataSource(env, accessToken, dataSourceId) {
  return notionRequest(
    env,
    accessToken,
    `/v1/data_sources/${encodeURIComponent(dataSourceId)}`,
  );
}

function titlePropertyName(dataSource) {
  const property = Object.entries(dataSource?.properties ?? {}).find(
    ([, value]) => value?.type === "title",
  );
  return property?.[0] ?? "title";
}

async function findDataSourcePageByTitle(env, accessToken, dataSourceId, propertyName, title) {
  let startCursor;
  do {
    const payload = await notionRequest(
      env,
      accessToken,
      `/v1/data_sources/${encodeURIComponent(dataSourceId)}/query`,
      {
        method: "POST",
        body: JSON.stringify({
          filter: { property: propertyName, title: { equals: title } },
          page_size: 100,
          ...(startCursor ? { start_cursor: startCursor } : {}),
        }),
      },
    );
    const match = (payload.results ?? []).find((page) => page?.object === "page");
    if (match?.id) return { pageId: match.id, url: match.url ?? null };
    startCursor = payload.has_more ? payload.next_cursor : null;
  } while (startCursor);
  return null;
}

async function updateNotionPage(env, accessToken, pageId, markdown) {
  const payload = await notionRequest(
    env,
    accessToken,
    `/v1/pages/${encodeURIComponent(pageId)}/markdown`,
    {
      method: "PATCH",
      body: JSON.stringify(buildNotionReplacePayload(markdown)),
    },
  );
  return {
    mode: "updated",
    pageId,
    url: payload.url ?? null,
    truncated: payload.truncated ?? payload.page_markdown?.truncated ?? false,
  };
}

async function handleNotionSync(request, env, bodyText, body) {
  requireConfigured(env, ["DB", "TOKEN_ENCRYPTION_KEY"]);
  const installationId = await authenticateSignedRequest(request, env, bodyText);
  const sync = parseSyncPayload(body);
  const connection = await getNotionConnection(env, installationId);

  if (sync.pageId) {
    return json(
      request,
      await updateNotionPage(env, connection.accessToken, sync.pageId, sync.markdown),
      200,
      {},
      env,
    );
  }

  const parent = sync.parentPageId
    ? { page_id: sync.parentPageId }
    : { data_source_id: sync.dataSourceId };
  const title = syncPageTitle(sync);
  let existingPage;
  let dataSourceTitleProperty = "title";

  if (sync.parentPageId) {
    existingPage = await findChildPageByTitle(
      env,
      connection.accessToken,
      sync.parentPageId,
      title,
    );
  } else {
    const dataSource = await retrieveDataSource(
      env,
      connection.accessToken,
      sync.dataSourceId,
    );
    dataSourceTitleProperty = titlePropertyName(dataSource);
    existingPage = await findDataSourcePageByTitle(
      env,
      connection.accessToken,
      sync.dataSourceId,
      dataSourceTitleProperty,
      title,
    );
  }

  if (existingPage?.pageId) {
    const result = await updateNotionPage(
      env,
      connection.accessToken,
      existingPage.pageId,
      sync.markdown,
    );
    return json(request, { ...result, url: existingPage.url ?? result.url }, 200, {}, env);
  }

  const payload = await notionRequest(env, connection.accessToken, "/v1/pages", {
    method: "POST",
    body: JSON.stringify(buildNotionCreatePayload({
      parent,
      title,
      markdown: sync.markdown,
      titlePropertyName: dataSourceTitleProperty,
    })),
  });
  return json(request, {
    mode: "created",
    pageId: payload.id,
    url: payload.url ?? null,
  }, 201, {}, env);
}

async function handleNotionDisconnect(request, env, bodyText) {
  requireConfigured(env, ["DB", "TOKEN_ENCRYPTION_KEY"]);
  const installationId = await authenticateSignedRequest(request, env, bodyText);
  await env.DB.batch([
    env.DB.prepare("DELETE FROM notion_connections WHERE installation_id = ?").bind(installationId),
    env.DB.prepare("DELETE FROM notion_pending_connections WHERE installation_id = ?").bind(installationId),
    env.DB.prepare("DELETE FROM oauth_states WHERE installation_id = ?").bind(installationId),
  ]);
  return json(request, { connected: false }, 200, {}, env);
}

function neutralizeDiscord(value) {
  return value.replaceAll("@", "@\u200b").replaceAll("```", "''' ");
}

function discordField(name, value, inline = false) {
  return {
    name,
    value: value ? neutralizeDiscord(String(value)).slice(0, 1024) : "-",
    inline,
  };
}

function feedbackColor(kind) {
  return { bug: 0xf04f5f, feature: 0x1488f5, question: 0x8c65d8, other: 0x70757d }[kind] ?? 0x70757d;
}

export function buildDiscordPayload(feedback, installationId, feedbackId) {
  const kindLabel = {
    bug: "Bug",
    feature: "Feature request",
    question: "Question",
    other: "Other",
  }[feedback.kind];
  const fields = [
    discordField("Type", kindLabel, true),
    discordField("App version", feedback.appVersion, true),
    discordField("OS", feedback.osVersion, true),
    discordField("Device", feedback.deviceModel, true),
    discordField("Locale", feedback.locale, true),
    discordField("Pro", feedback.hasPro === undefined ? undefined : feedback.hasPro ? "yes" : "no", true),
    discordField("Installation", installationId.slice(0, 15), true),
  ];
  if (feedback.contactEmail) fields.push(discordField("Reply to", feedback.contactEmail));

  return {
    username: "Silica Support",
    allowed_mentions: { parse: [] },
    embeds: [
      {
        title: `[${kindLabel}] ${neutralizeDiscord(feedback.title).slice(0, 200)}`,
        description: neutralizeDiscord(feedback.message).slice(0, 4096),
        color: feedbackColor(feedback.kind),
        fields,
        footer: { text: `Silica API · ${feedbackId}` },
        timestamp: new Date().toISOString(),
      },
    ],
  };
}

async function sendToDiscord(env, payload) {
  requireConfigured(env, ["DISCORD_WEBHOOK_URL"]);
  let webhookUrl;
  try {
    webhookUrl = new URL(env.DISCORD_WEBHOOK_URL);
  } catch {
    throw new ApiError("server_not_configured", 500);
  }
  if (!/^(discord\.com|discordapp\.com)$/.test(webhookUrl.hostname)) {
    throw new ApiError("server_not_configured", 500);
  }
  webhookUrl.searchParams.set("wait", "true");

  const response = await fetch(webhookUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    console.error("Discord feedback delivery failed", { status: response.status });
    if (response.status === 429) throw new ApiError("feedback_rate_limited", 503);
    throw new ApiError("feedback_delivery_failed", 502);
  }
}

async function handleFeedback(request, env, bodyText, body) {
  requireConfigured(env, ["DB", "TOKEN_ENCRYPTION_KEY", "DISCORD_WEBHOOK_URL"]);
  const installationId = await authenticateSignedRequest(request, env, bodyText);
  const feedback = parseFeedbackPayload(body);
  const ipHash = await clientIpHash(request, env);
  const installationAllowed = await consumeRateLimit(
    env,
    `feedback:installation:${installationId}`,
    3,
    3600,
  );
  const ipAllowed = await consumeRateLimit(env, `feedback:ip:${ipHash}`, 20, 3600);
  if (!installationAllowed || !ipAllowed) throw new ApiError("rate_limited", 429);

  const feedbackId = `fb_${randomToken(12)}`;
  await sendToDiscord(env, buildDiscordPayload(feedback, installationId, feedbackId));
  return json(request, { accepted: true, feedbackId }, 202, {}, env);
}

async function route(request, env, ctx) {
  const url = new URL(request.url);
  if (request.method === "OPTIONS") return applyPreflight(request, env);
  if (url.pathname === `${API_PREFIX}/health` && request.method === "GET") {
    return json(request, { ok: true, service: "silica-api" }, 200, {}, env);
  }
  if (!url.pathname.startsWith(`${API_PREFIX}/`)) {
    return json(request, { error: "not_found" }, 404, {}, env);
  }

  if (url.pathname === `${API_PREFIX}/session/bootstrap` && request.method === "POST") {
    return handleBootstrap(request, env);
  }

  if (url.pathname === `${API_PREFIX}/notion/callback` && request.method === "GET") {
    return handleNotionCallback(request, env);
  }

  const { bodyText, body } = ["POST", "DELETE"].includes(request.method)
    ? await readJson(request)
    : { bodyText: "", body: {} };

  if (url.pathname === `${API_PREFIX}/notion/authorize` && request.method === "POST") {
    return handleNotionAuthorize(request, env, bodyText, body);
  }
  if (url.pathname === `${API_PREFIX}/notion/complete` && request.method === "POST") {
    return handleNotionComplete(request, env, bodyText, body);
  }
  if (url.pathname === `${API_PREFIX}/notion/status` && request.method === "GET") {
    return handleNotionStatus(request, env, bodyText);
  }
  if (url.pathname === `${API_PREFIX}/notion/search` && request.method === "POST") {
    return handleNotionSearch(request, env, bodyText, body);
  }
  if (url.pathname === `${API_PREFIX}/notion/sync` && request.method === "POST") {
    return handleNotionSync(request, env, bodyText, body);
  }
  if (url.pathname === `${API_PREFIX}/notion/disconnect` && request.method === "DELETE") {
    return handleNotionDisconnect(request, env, bodyText);
  }
  if (url.pathname === `${API_PREFIX}/feedback` && request.method === "POST") {
    return handleFeedback(request, env, bodyText, body);
  }

  ctx?.waitUntil(
    env.DB?.prepare("DELETE FROM request_nonces WHERE expires_at < ?")
      .bind(nowSeconds())
      .run()
      .catch(() => undefined),
  );
  return json(request, { error: "not_found" }, 404, {}, env);
}

export default {
  async fetch(request, env, ctx) {
    try {
      return await route(request, env, ctx);
    } catch (error) {
      if (error instanceof ApiError) {
        return json(request, { error: error.code }, error.status, {}, env);
      }
      console.error("Silica API unhandled error", { message: error?.message });
      return json(request, { error: "internal_error" }, 500, {}, env);
    }
  },

  async scheduled(_event, env) {
    if (!env.DB) return;
    const current = nowSeconds();
    await env.DB.batch([
      env.DB.prepare(
        "DELETE FROM notion_pending_connections WHERE expires_at < ?",
      ).bind(current),
      env.DB.prepare(
        "DELETE FROM request_nonces WHERE expires_at < ?",
      ).bind(current),
      env.DB.prepare(
        "DELETE FROM oauth_states WHERE expires_at < ? OR (consumed_at IS NOT NULL AND consumed_at < ?)",
      ).bind(current, current - 86_400),
      env.DB.prepare(
        "DELETE FROM rate_limits WHERE window_start < ?",
      ).bind(current - 86_400),
    ]);
  },
};
