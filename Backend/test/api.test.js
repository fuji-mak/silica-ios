import test from "node:test";
import assert from "node:assert/strict";
import {
  buildDiscordPayload,
  buildNotionCreatePayload,
  buildNotionReplacePayload,
} from "../src/index.js";
import { parseFeedbackPayload, parseSyncPayload } from "../src/validation.js";

test("feedback payload accepts supported fields and rejects oversized content", () => {
  const feedback = parseFeedbackPayload({
    kind: "bug",
    title: "ログが表示されない",
    message: "再起動しても今日のログが空です。",
    appVersion: "1.0.0",
    osVersion: "iOS 26.5",
    deviceModel: "iPhone",
    hasPro: true,
  });

  assert.equal(feedback.kind, "bug");
  assert.equal(feedback.hasPro, true);
  assert.equal(parseFeedbackPayload({ kind: "other", title: "その他", message: "補足" }).kind, "other");
  assert.throws(
    () => parseFeedbackPayload({ kind: "bug", title: "x", message: "x".repeat(6001) }),
    /message_too_long/,
  );
});

test("sync payload requires exactly one destination mode", () => {
  const update = parseSyncPayload({ pageId: "page_12345678", date: "2026-07-29", markdown: "# Today" });
  assert.equal(update.pageId, "page_12345678");
  assert.equal(update.date, "2026-07-29");
  assert.throws(
    () => parseSyncPayload({ markdown: "# Today" }),
    /parent_required/,
  );
  assert.throws(
    () => parseSyncPayload({ pageId: "page_12345678", parentPageId: "parent_12345678", markdown: "# Today" }),
    /ambiguous_parent/,
  );
  assert.throws(
    () => parseSyncPayload({ parentPageId: "parent_12345678", date: "2026/07/29", markdown: "# Today" }),
    /invalid_date/,
  );
});

test("Discord payload suppresses all mentions", () => {
  const payload = buildDiscordPayload(
    {
      kind: "question",
      title: "@everyone please help",
      message: "<@123456789> what does this do?",
      appVersion: "1.0.0",
    },
    "si_abcdefghijklmnop",
    "fb_test",
  );

  assert.deepEqual(payload.allowed_mentions, { parse: [] });
  assert.equal(payload.embeds[0].title.includes("@\u200beveryone"), true);
  assert.equal(payload.embeds[0].description.includes("@\u200b"), true);
});

test("Notion replace payload uses the enhanced Markdown command shape", () => {
  assert.deepEqual(buildNotionReplacePayload("---\ntitle: Today\n---\n\n# Today"), {
    type: "replace_content",
    replace_content: {
      new_str: "# Today",
      allow_deleting_content: false,
    },
  });
});

test("Notion create payload sets a stable page title", () => {
  assert.deepEqual(buildNotionCreatePayload({
    parent: { page_id: "parent_12345678" },
    title: "2026-07-29",
    markdown: "---\ndate: 2026-07-29\n---\n\n## 位置ログ",
  }), {
    parent: { page_id: "parent_12345678" },
    properties: {
      title: {
        title: [
          {
            type: "text",
            text: { content: "2026-07-29" },
          },
        ],
      },
    },
    markdown: "## 位置ログ",
  });
});
