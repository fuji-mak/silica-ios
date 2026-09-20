import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import worker from "../src/index.js";
import { decryptString, hmacSha256, randomToken } from "../src/crypto.js";

function setup(t) {
  const sqlite = new DatabaseSync(":memory:");
  const migrations = new URL("../migrations/", import.meta.url);
  for (const file of readdirSync(migrations).filter((name) => name.endsWith(".sql")).sort()) {
    sqlite.exec(readFileSync(new URL(file, migrations), "utf8"));
  }
  t.after(() => sqlite.close());
  const DB = {
    prepare(sql) {
      let values = [];
      return {
        bind(...input) { values = input; return this; },
        async first() { return sqlite.prepare(sql).get(...values) ?? null; },
        execute() { return { meta: { changes: Number(sqlite.prepare(sql).run(...values).changes) } }; },
        async run() { return this.execute(); },
      };
    },
    async batch(statements) {
      sqlite.exec("BEGIN");
      try {
        const results = statements.map((statement) => statement.execute());
        sqlite.exec("COMMIT");
        return results;
      } catch (error) {
        sqlite.exec("ROLLBACK");
        throw error;
      }
    },
  };
  const env = {
    DB,
    TOKEN_ENCRYPTION_KEY: randomToken(32),
    NOTION_CLIENT_ID: "synthetic-client",
    NOTION_CLIENT_SECRET: "synthetic-secret",
    NOTION_REDIRECT_URI: "https://silica.invalid/api/silica/notion/callback",
  };
  const tokenFor = (code) => `synthetic-notion-token-for-${code}`;
  const notionCalls = [];
  t.mock.method(globalThis, "fetch", async (url, init) => {
    notionCalls.push({ url, init });
    if (url === "https://api.notion.com/v1/oauth/token") {
      const { code } = JSON.parse(init.body);
      return Response.json({ access_token: tokenFor(code), workspace_name: code });
    }
    if (url === "https://api.notion.com/v1/search") {
      return Response.json({ results: [{ id: "synthetic-page" }] });
    }
    if (url === "https://api.notion.com/v1/pages/synthetic-page/markdown") {
      return Response.json({ url: "https://notion.invalid/synthetic-page" });
    }
    throw new Error("Unexpected network request in isolated test");
  });
  const send = (path, init) => worker.fetch(new Request(`https://silica.invalid/api/silica${path}`, init), env, {});
  async function bootstrap() {
    const response = await send("/session/bootstrap", { method: "POST" });
    assert.equal(response.status, 201);
    return response.json();
  }
  async function signed(identity, path, body, method = "POST") {
    const bodyText = body === undefined ? "" : JSON.stringify(body);
    const timestamp = Math.floor(Date.now() / 1000);
    const nonce = randomToken(18);
    const signature = await hmacSha256(identity.installationSecret,
      [timestamp, nonce, method, `/api/silica${path}`, bodyText].join("\n"));
    return send(path, {
      method,
      headers: {
        "X-Silica-Installation": identity.installationId,
        "X-Silica-Timestamp": String(timestamp),
        "X-Silica-Nonce": nonce,
        "X-Silica-Signature": signature,
        "Content-Type": "application/json",
      },
      ...(bodyText ? { body: bodyText } : {}),
    });
  }
  async function authorize(identity) {
    const response = await signed(identity, "/notion/authorize", {
      returnUrl: "silica://notion/callback", completionMode: "app",
    });
    assert.equal(response.status, 200);
    return new URL((await response.json()).authorizationUrl).searchParams.get("state");
  }
  async function callback(state, code = "owner") {
    return send(`/notion/callback?state=${encodeURIComponent(state)}&code=${code}`);
  }
  async function pending(identity, code) {
    const response = await callback(await authorize(identity), code);
    assert.equal(response.status, 302);
    const redirect = new URL(response.headers.get("Location"));
    assert.equal(redirect.searchParams.get("notion"), "pending");
    return redirect.searchParams.get("completionToken");
  }
  const complete = (identity, token) => signed(identity, "/notion/complete", { completionToken: token });
  const status = async (identity) => (await signed(identity, "/notion/status", undefined, "GET")).json();
  return { sqlite, env, notionCalls, tokenFor, send, bootstrap, signed, authorize, callback, pending, complete, status };
}

test("OAuth activates only after the initiating installation returns the completion proof, once", async (t) => {
  const h = setup(t);
  const owner = await h.bootstrap();
  const proof = await h.pending(owner, "owner");
  assert.equal((await h.status(owner)).connected, false);
  const completions = await Promise.all([h.complete(owner, proof), h.complete(owner, proof)]);
  assert.deepEqual(completions.map((response) => response.status).sort(), [200, 401]);
  assert.equal((await h.status(owner)).connected, true);
  const stored = h.sqlite.prepare("SELECT access_token_ciphertext FROM notion_connections").get();
  assert.notEqual(stored.access_token_ciphertext, h.tokenFor("owner"));
  assert.equal(await decryptString(stored.access_token_ciphertext, h.env.TOKEN_ENCRYPTION_KEY), h.tokenFor("owner"));
  assert.equal((await h.signed(owner, "/notion/search", {})).status, 200);
});

test("forwarded authorization URL does not grant the sender access to the approving user's pages", async (t) => {
  const h = setup(t);
  const sender = await h.bootstrap();
  const approvingUser = await h.bootstrap();
  const proofReceivedByApprovingUser = await h.pending(sender, "approving-user");
  assert.equal((await h.status(sender)).connected, false);
  assert.equal((await h.signed(sender, "/notion/search", {})).status, 409);
  assert.equal((await h.signed(sender, "/notion/sync", { pageId: "synthetic-page", markdown: "Synthetic" })).status, 409);
  assert.equal((await h.complete(sender, randomToken(32))).status, 401);
  assert.equal((await h.complete(approvingUser, proofReceivedByApprovingUser)).status, 401);
  assert.equal((await h.status(sender)).connected, false);
  assert.equal(h.notionCalls.length, 1); // Only the code exchange, no resource access.
});

test("expired completion proofs and expired or replayed OAuth states are rejected", async (t) => {
  const h = setup(t);
  const owner = await h.bootstrap();
  const state = await h.authorize(owner);
  assert.equal((await h.callback(state)).status, 302);
  assert.equal((await h.callback(state)).status, 400);
  const proof = await h.pending(owner, "expired");
  h.sqlite.exec("UPDATE notion_pending_connections SET expires_at = 0");
  assert.equal((await h.complete(owner, proof)).status, 401);
  const expiredState = await h.authorize(owner);
  h.sqlite.exec("UPDATE oauth_states SET expires_at = 0");
  assert.equal((await h.callback(expiredState)).status, 400);
  assert.equal((await h.status(owner)).connected, false);
});

test("existing connections survive pending reauthorization; disconnect cancels pending completion", async (t) => {
  const h = setup(t);
  const owner = await h.bootstrap();
  assert.equal((await h.complete(owner, await h.pending(owner, "original"))).status, 200);
  const replacement = await h.pending(owner, "replacement");
  assert.equal((await h.status(owner)).workspace.name, "original");
  assert.equal((await h.signed(owner, "/notion/disconnect", undefined, "DELETE")).status, 200);
  assert.equal((await h.complete(owner, replacement)).status, 401);
  assert.equal((await h.status(owner)).connected, false);
});

test("old apps cannot start the unbound flow and denying consent creates no pending connection", async (t) => {
  const h = setup(t);
  const owner = await h.bootstrap();
  assert.equal((await h.signed(owner, "/notion/authorize", { returnUrl: "silica://notion/callback" })).status, 426);
  const state = await h.authorize(owner);
  const response = await h.send(`/notion/callback?state=${encodeURIComponent(state)}&error=access_denied`);
  assert.equal(response.status, 302);
  assert.equal(new URL(response.headers.get("Location")).searchParams.get("notion"), "denied");
  assert.equal(h.sqlite.prepare("SELECT COUNT(*) AS count FROM notion_pending_connections").get().count, 0);
  assert.equal(h.notionCalls.length, 0);
});
