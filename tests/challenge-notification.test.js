import test from "node:test";
import assert from "node:assert/strict";
import { makeHandler, makeVercelHandler } from "../api/challenge-notification.js";

const originalEnv = { ...process.env };
const secret = "test-webhook-secret";
const challengeId = "047d9c57-b48d-4ef8-8b28-61b90346b325";
const challengerId = "245f7ecf-5fd4-486b-b280-57c65180ea90";
const challengedId = "23d3198e-26f4-4286-80c3-f31a32a40425";

function configure() {
  Object.assign(process.env, {
    CHALLENGE_WEBHOOK_SECRET: secret, SUPABASE_URL: "https://example.supabase.co",
    SUPABASE_SERVICE_ROLE_KEY: "test-secret", SMTP_HOST: "smtp.example.com",
    SMTP_PORT: "465", SMTP_USER: "sender@example.com",
    SMTP_PASSWORD: "test-password", SMTP_FROM: "PaddleLadder <sender@example.com>"
  });
}

function event(header = secret) {
  return new Request("https://example.com/api/challenge-notification", {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-challenge-webhook-secret": header },
    body: JSON.stringify({
      type: "INSERT", schema: "public", table: "challenges", record: { id: challengeId }
    })
  });
}

function mocks({ failEmail = "" } = {}) {
  const claims = new Set();
  const messages = [];
  const db = {
    rpc(name, args) {
      assert.equal(name, "challenge_notification_recipients_secure");
      assert.equal(args.requested_challenge_id, challengeId);
      return Promise.resolve({ data: [
        { email: "first@example.com" }, { email: "second@example.com" }
      ], error: null });
    },
    from(table) {
      if (table === "challenges") return {
        select: () => ({ eq: () => ({ single: async () => ({
          data: {
            id: challengeId, status: "Pending", created_at: "2026-10-01T12:00:00Z",
            challenger_team_id: challengerId, challenged_team_id: challengedId
          }, error: null
        }) }) })
      };
      if (table === "ladder_teams") return {
        select: () => ({ in: async () => ({ data: [
          { id: challengerId, name: "Challengers", club_id: "club", ladder: "mixed" },
          { id: challengedId, name: "Defenders", club_id: "club", ladder: "mixed" }
        ], error: null }) })
      };
      if (table === "challenge_email_notices") return {
        insert: async ({ email }) => {
          if (claims.has(email)) return { error: { code: "23505" } };
          claims.add(email);
          return { error: null };
        },
        update: () => ({ eq: () => ({ eq: async () => ({ error: null }) }) }),
        delete: () => ({ eq: () => ({ eq: async (_, email) => {
          claims.delete(email);
          return { error: null };
        } }) })
      };
      throw Error("Unexpected table " + table);
    }
  };
  const mailer = {
    async sendMail(message) {
      if (message.to === failEmail) throw Error("SMTP unavailable");
      messages.push(message);
    }
  };
  const options = { dbFactory: () => db, mailerFactory: () => mailer };
  return { claims, messages, handler: makeHandler(options), vercelHandler: makeVercelHandler(options) };
}

test.after(() => { process.env = originalEnv; });

test("rejects requests without the webhook secret", async () => {
  configure();
  const { handler, messages } = mocks();
  assert.equal((await handler(event("wrong"))).status, 401);
  assert.equal(messages.length, 0);
});

test("emails each assigned player once and handles duplicate webhook delivery", async () => {
  configure();
  const { handler, messages, claims } = mocks();
  const first = await handler(event());
  assert.equal(first.status, 200);
  assert.equal((await first.json()).sent, 2);
  assert.deepEqual(messages.map(message => message.to), [
    "first@example.com", "second@example.com"
  ]);
  assert.match(messages[0].text, /accept or decline by/);
  assert.match(messages[0].text, /pickleball-paddleladder\.vercel\.app/);
  assert.equal(claims.size, 2);
  const second = await handler(event());
  assert.equal((await second.json()).duplicate, 2);
  assert.equal(messages.length, 2);
});

test("releases an explicit SMTP failure so a retry can send that recipient", async () => {
  configure();
  const { handler, messages, claims } = mocks({ failEmail: "first@example.com" });
  const result = await handler(event());
  assert.equal(result.status, 503);
  assert.deepEqual([...claims], ["second@example.com"]);
  assert.equal(messages.length, 1);
});

test("Vercel Node request and response deliver challenge email", async () => {
  configure();
  const { vercelHandler, messages } = mocks();
  const result = { headers: {} };
  const res = {
    setHeader(key, value) { result.headers[key] = value; },
    status(status) { result.status = status; return this; },
    json(body) { result.body = body; return this; }
  };
  await vercelHandler({
    method: "POST",
    headers: { "x-challenge-webhook-secret": secret },
    body: { type: "INSERT", schema: "public", table: "challenges", record: { id: challengeId } }
  }, res);
  assert.equal(result.status, 200);
  assert.equal(result.body.sent, 2);
  assert.equal(result.headers["Cache-Control"], "no-store");
  assert.equal(messages.length, 2);
});
