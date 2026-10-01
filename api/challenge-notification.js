import { timingSafeEqual } from "node:crypto";
import nodemailer from "nodemailer";
import { createClient } from "@supabase/supabase-js";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function equalSecret(actual, expected) {
  if (!actual || !expected) return false;
  const left = Buffer.from(actual);
  const right = Buffer.from(expected);
  return left.length === right.length && timingSafeEqual(left, right);
}

function response(status, body) {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}

export function makeHandler({ dbFactory = createClient, mailerFactory = nodemailer.createTransport } = {}) {
return async function handler(request) {
  if (request.method !== "POST") return response(405, { error: "Method not allowed" });

  const secret = process.env.CHALLENGE_WEBHOOK_SECRET;
  if (!equalSecret(request.headers.get("x-challenge-webhook-secret"), secret)) {
    return response(401, { error: "Unauthorized" });
  }

  const required = [
    "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "SMTP_HOST",
    "SMTP_PORT", "SMTP_USER", "SMTP_PASSWORD", "SMTP_FROM"
  ];
  if (required.some(key => !process.env[key])) {
    console.error("Challenge notification configuration is incomplete");
    return response(503, { error: "Notifications are not configured" });
  }

  let payload;
  try {
    payload = await request.json();
  } catch {
    return response(400, { error: "Invalid JSON" });
  }
  if (payload?.type !== "INSERT" || payload?.table !== "challenges" ||
      payload?.schema !== "public" || !UUID.test(payload?.record?.id || "")) {
    return response(400, { error: "Invalid challenge event" });
  }

  const db = dbFactory(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
  });
  const { data: challenge, error: challengeError } = await db
    .from("challenges")
    .select("id,status,created_at,challenger_team_id,challenged_team_id")
    .eq("id", payload.record.id).single();
  if (challengeError || !challenge) {
    console.error("Challenge notification lookup failed", challengeError);
    return response(500, { error: "Could not load challenge" });
  }
  if (challenge.status !== "Pending") {
    return response(200, { skipped: "Challenge is no longer pending" });
  }

  const { data: teams, error: teamError } = await db.from("ladder_teams")
    .select("id,name,club_id,ladder")
    .in("id", [challenge.challenger_team_id, challenge.challenged_team_id]);
  if (teamError || teams?.length !== 2) {
    console.error("Challenge notification team lookup failed", teamError);
    return response(500, { error: "Could not load teams" });
  }
  const challenger = teams.find(team => team.id === challenge.challenger_team_id);
  const challenged = teams.find(team => team.id === challenge.challenged_team_id);
  if (!challenger || !challenged || !challenger.club_id ||
      challenger.club_id !== challenged.club_id ||
      challenger.ladder !== challenged.ladder) {
    return response(400, { error: "Challenge team mismatch" });
  }

  const { data: members, error: memberError } = await db.from("team_members")
    .select("email").eq("team_id", challenged.id);
  if (memberError) {
    console.error("Challenge notification recipient lookup failed", memberError);
    return response(500, { error: "Could not load recipients" });
  }
  const recipients = [...new Set((members || [])
    .map(member => String(member.email || "").trim().toLowerCase())
    .filter(email => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)))].slice(0, 2);
  if (!recipients.length) {
    console.warn("No player emails assigned to challenged team", challenged.id);
    return response(200, { skipped: "No assigned player emails" });
  }

  const port = Number(process.env.SMTP_PORT);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    return response(503, { error: "Invalid SMTP port" });
  }
  const transport = mailerFactory({
    host: process.env.SMTP_HOST,
    port,
    secure: port === 465,
    requireTLS: port !== 465,
    auth: { user: process.env.SMTP_USER, pass: process.env.SMTP_PASSWORD },
    connectionTimeout: 10000,
    greetingTimeout: 10000,
    socketTimeout: 15000
  });

  const deadline = new Date(new Date(challenge.created_at).getTime() + 72 * 60 * 60 * 1000);
  const deadlineText = deadline.toLocaleString("en-CA", {
    timeZone: "America/Vancouver", year: "numeric", month: "short", day: "numeric",
    hour: "numeric", minute: "2-digit", timeZoneName: "short"
  });
  const siteUrl = "https://pickleball-paddleladder.vercel.app/";
  const message = [
    `Your team, ${challenged.name}, has received a Pickleball PaddleLadder challenge from ${challenger.name}.`,
    "",
    `Please sign in and accept or decline by ${deadlineText}.`,
    "",
    `Open the ladder: ${siteUrl}`,
    "",
    "If you are not part of this team, let the club organizer know."
  ].join("\n");

  let sent = 0;
  let duplicate = 0;
  let failed = 0;
  for (const email of recipients) {
    // The primary key makes repeat webhook deliveries safe.
    const { error: claimError } = await db.from("challenge_email_notices")
      .insert({ challenge_id: challenge.id, email });
    if (claimError?.code === "23505") {
      duplicate++;
      continue;
    }
    if (claimError) {
      console.error("Could not reserve notification", claimError);
      failed++;
      continue;
    }
    try {
      await transport.sendMail({
        from: process.env.SMTP_FROM,
        to: email,
        subject: "New PaddleLadder challenge for your team",
        text: message
      });
      const { error: markError } = await db.from("challenge_email_notices")
        .update({ sent_at: new Date().toISOString() })
        .eq("challenge_id", challenge.id).eq("email", email);
      if (markError) console.error("Notification sent but timestamp update failed", markError);
      sent++;
    } catch (error) {
      console.error("Could not send challenge notification", error);
      // A later webhook retry can try again after an explicit SMTP failure.
      const { error: releaseError } = await db.from("challenge_email_notices")
        .delete().eq("challenge_id", challenge.id).eq("email", email);
      if (releaseError) console.error("Could not release failed notification", releaseError);
      failed++;
    }
  }
  return response(failed ? 503 : 200, { sent, duplicate, failed });
};
}

export default makeHandler();
