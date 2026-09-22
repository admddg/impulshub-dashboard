import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const WINDOW_MS = 10 * 60 * 1000;
const IP_LIMIT = 10;
const TOKEN_LIMIT = 60;
const genericError = () => Response.json({ ok: false, error: "unable to process submission" }, { status: 400 });

function text(value: unknown, max = 500): string | null {
  if (typeof value !== "string") return null;
  const v = value.trim();
  return v.length > 0 && v.length <= max ? v : null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return new Response("service unavailable", { status: 503 });
  const db = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return genericError();
  }
  if (text(body.honeypot, 200)) return Response.json({ ok: true });
  const clientSlug = text(body.client_slug, 100);
  const formToken = text(body.form_intake_token ?? body.form_token, 100);
  const fullName = text(body.name ?? body.full_name, 200);
  const phone = text(body.phone, 80);
  const email = text(body.email, 320);
  if (!clientSlug || !formToken || !fullName || (!phone && !email)) return genericError();
  const tokenUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(formToken);
  if (!tokenUuid) return genericError();

  const ip = (req.headers.get("x-forwarded-for") ?? req.headers.get("x-real-ip") ?? "127.0.0.1").split(",")[0].trim();
  const windowStarted = new Date(Math.floor(Date.now() / WINDOW_MS) * WINDOW_MS).toISOString();
  const { data: ipRows } = await db.from("form_intake_rate_limit").select("request_count")
    .eq("window_started", windowStarted).eq("ip", ip).eq("form_intake_token", formToken);
  const ipCount = Number(ipRows?.[0]?.request_count ?? 0);
  if (ipCount >= IP_LIMIT) return genericError();
  const { data: tokenRows } = await db.from("form_intake_rate_limit").select("request_count")
    .eq("window_started", windowStarted).eq("ip", "0.0.0.0").eq("form_intake_token", formToken);
  const tokenCount = Number(tokenRows?.[0]?.request_count ?? 0);
  if (tokenCount >= TOKEN_LIMIT) return genericError();
  const { error: ipRateError } = await db.from("form_intake_rate_limit").upsert({ window_started: windowStarted, ip, form_intake_token: formToken, request_count: ipCount + 1 });
  const { error: tokenRateError } = await db.from("form_intake_rate_limit").upsert({ window_started: windowStarted, ip: "0.0.0.0", form_intake_token: formToken, request_count: tokenCount + 1 });
  if (ipRateError || tokenRateError) return new Response("service unavailable", { status: 503 });

  const { data, error } = await db.rpc("intake_form_lead", {
    p_client_slug: clientSlug, p_form_intake_token: formToken, p_full_name: fullName,
    p_phone: phone, p_email: email, p_gclid: text(body.gclid, 500), p_gbraid: text(body.gbraid, 500),
    p_wbraid: text(body.wbraid, 500), p_utm_source: text(body.utm_source, 200), p_utm_medium: text(body.utm_medium, 200),
    p_utm_campaign: text(body.utm_campaign, 200), p_utm_content: text(body.utm_content, 200), p_utm_term: text(body.utm_term, 200),
    p_page_url: text(body.page_url, 2000),
  });
  if (error) return genericError();
  return Response.json({ ok: true, deduped: Boolean(data?.deduped) });
});
