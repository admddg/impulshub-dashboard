import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function json(body: Record<string, unknown>, status = 200) {
  return Response.json(body, { status, headers: { ...headers, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return json({ ok: false, error: "method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authorization = req.headers.get("Authorization");
  if (!supabaseUrl || !anonKey || !serviceKey) return json({ ok: false, error: "service unavailable" }, 503);
  if (!authorization?.startsWith("Bearer ")) return json({ ok: false, error: "unauthorized" }, 401);

  const token = authorization.slice("Bearer ".length);
  const caller = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { data: userData, error: userError } = await caller.auth.getUser(token);
  const actorId = userData.user?.id;
  if (userError || !actorId) return json({ ok: false, error: "unauthorized" }, 401);

  let onboardingId: unknown;
  try {
    onboardingId = (await req.json()).onboarding_id;
  } catch {
    return json({ ok: false, error: "invalid request" }, 400);
  }
  if (typeof onboardingId !== "string" || !uuid.test(onboardingId)) return json({ ok: false, error: "invalid request" }, 400);

  const db = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
  const { data: agency, error: agencyError } = await db
    .from("client_users")
    .select("id")
    .eq("user_id", actorId)
    .eq("role", "agency")
    .eq("is_active", true)
    .limit(1)
    .maybeSingle();
  if (agencyError || !agency) return json({ ok: false, error: "forbidden" }, 403);

  const { data: onboarding, error: onboardingError } = await db
    .from("internal_onboardings")
    .select("client_id")
    .eq("id", onboardingId)
    .maybeSingle();
  if (onboardingError || !onboarding) return json({ ok: false, error: "not found" }, 404);

  const { data: pending, error: pendingError } = await db
    .from("internal_onboarding_users")
    .select("id, email, profile, onboarding_id")
    .eq("onboarding_id", onboardingId)
    .eq("invite_status", "pending_auth");
  if (pendingError) return json({ ok: false, error: "unable to load pending users" }, 503);

  let invited = 0;
  let failed = 0;
  for (const user of pending ?? []) {
    const { data: invitedUser, error: inviteError } = await db.auth.admin.inviteUserByEmail(user.email, {
      data: { onboarding_id: onboardingId, onboarding_profile: user.profile },
    });
    let authUser = invitedUser.user;
    if (inviteError || !authUser) {
      const existing = await db.auth.admin.listUsers({ page: 1, perPage: 1000 });
      authUser = existing.data?.users.find((candidate) => candidate.email?.toLowerCase() === user.email.toLowerCase()) ?? null;
    }
    if (!authUser) {
      failed += 1;
      continue;
    }

    const { error: linkError } = await caller.rpc("link_internal_onboarding_user", {
      p_onboarding_user_id: user.id,
      p_auth_user_id: authUser.id,
    });
    if (linkError) {
      failed += 1;
      continue;
    }
    invited += 1;
  }

  return json({ ok: failed === 0, invited, failed });
});
