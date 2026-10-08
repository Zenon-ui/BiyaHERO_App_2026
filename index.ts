// ============================================================
// create-admin — Supabase Edge Function
// ============================================================
// This is the ONLY place in the entire system that can create a new
// Admin account. It is deliberately NOT a table write from the browser,
// because creating a brand-new authenticated user requires Supabase's
// service-role "admin" API (auth.admin.createUser) — a privilege that
// must never be shipped to a public anon-key client. A plain
// supabaseClient.auth.signUp() call from the browser also would not
// work here even if it were otherwise safe, because signUp() replaces
// the CURRENT session with the newly created user's session — which
// would sign the acting admin out of their own account the moment they
// tried to create someone else's.
//
// Security model (read this before changing anything below):
//   - The caller's identity comes ONLY from the Supabase session JWT in
//     the Authorization header, verified with auth.getUser(). Nothing in
//     the request BODY is ever trusted for identity or role.
//   - Whether the caller is allowed to do this comes ONLY from a fresh
//     read of public.profiles for that verified user id, via the
//     service-role client (bypasses RLS on purpose, since it's the one
//     place that needs to see the row directly). If that row doesn't say
//     role = 'admin' and status = 'active', the request is rejected with
//     403 — no exceptions, no "trust the frontend already checked."
//   - Every validation rule (email domain, password strength) is
//     re-implemented here and re-run from scratch. BiyaHERO.js enforcing
//     the same rules client-side is a UX nicety, not a security control —
//     someone could call this endpoint directly with curl and skip the
//     browser entirely, and it must still refuse a weak password or a
//     non-Gmail address.
//   - The new user is created via auth.admin.createUser(), which does
//     NOT touch the caller's own session at all.
//   - handle_new_user() (see supabase-setup.sql) fires automatically on
//     that insert and creates a profiles row with role='user' (the safe
//     default for literally every other signup path in this app). This
//     function then explicitly UPDATEs that specific row to role='admin'
//     — using the service-role client, which is the one caller the
//     prevent_role_self_escalation trigger is written to let through
//     (see the auth.role() <> 'service_role' check in that trigger).
//
// ------------------------------------------------------------
// DEPLOYMENT (one-time setup)
// ------------------------------------------------------------
//   1. Install the Supabase CLI if you don't have it:
//        npm install -g supabase
//   2. From your project root (the folder containing this `supabase/`
//      directory), log in and link your project:
//        supabase login
//        supabase link --project-ref <your-project-ref>
//      (Your project ref is the subdomain in your Supabase URL, e.g.
//      "dqfwdgymsehynrsanquk" for https://dqfwdgymsehynrsanquk.supabase.co)
//   3. Deploy this function:
//        supabase functions deploy create-admin
//   4. That's it — no manual secrets to set. Supabase automatically
//      injects SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY into every
//      Edge Function's environment at runtime. Do NOT put the service
//      role key in traffic-config.js/supabase-config.js or anywhere else
//      that ships to the browser — it only ever lives here, server-side.
//   5. Test it once from your browser console while logged in as your
//      bootstrapped first admin (see the ADMIN BOOTSTRAPPING note in
//      supabase-setup.sql for how to create that first admin):
//        await supabaseClient.functions.invoke('create-admin', {
//          body: { name: 'Test Admin', email: 'test.admin@gmail.com', password: 'Str0ng!Pass' }
//        });
//      BiyaHERO.js's Admin Management tab calls this exact same function
//      the same way — you don't need to wire anything else up.
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Mirrors BiyaHERO.js's own rules exactly (isGmailAddress / passwordIssue
// / usernameIssue in BiyaHERO.js). Keep these in sync if you ever change
// one.
const GMAIL_ONLY_REGEX = /^[^\s@]+@gmail\.com$/i;
const USERNAME_REGEX = /^[A-Za-z0-9_]{3,20}$/;
const UPPER_REGEX = /[A-Z]/;
const LOWER_REGEX = /[a-z]/;
const NUMBER_REGEX = /[0-9]/;
const SYMBOL_REGEX = /[!@#$%^&*(),.?":{}|<>_\-\[\]\\/;'`~+=]/;
const MIN_PASSWORD_LENGTH = 8;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function passwordIssue(pass: string): string | null {
  if (typeof pass !== "string" || pass.length < MIN_PASSWORD_LENGTH) {
    return `Password must be at least ${MIN_PASSWORD_LENGTH} characters.`;
  }
  if (!UPPER_REGEX.test(pass)) return "Password must contain at least one uppercase letter.";
  if (!LOWER_REGEX.test(pass)) return "Password must contain at least one lowercase letter.";
  if (!NUMBER_REGEX.test(pass)) return "Password must contain at least one number.";
  if (!SYMBOL_REGEX.test(pass)) return "Password must contain at least one symbol (e.g. ! @ # $ %).";
  return null;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed." }, 405);
  }

  // ---- Step 1: who is calling? (identity from the JWT only) ----
  const authHeader = req.headers.get("Authorization") || "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "").trim();
  if (!jwt) {
    return json({ error: "Missing or invalid session." }, 401);
  }

  // service-role client: bypasses RLS by design, used only for the two
  // trusted reads/writes this function needs (verify caller, then act).
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: callerAuth, error: callerAuthErr } = await admin.auth.getUser(jwt);
  if (callerAuthErr || !callerAuth?.user) {
    return json({ error: "Missing or invalid session." }, 401);
  }
  const callerId = callerAuth.user.id;

  // ---- Step 2: is that caller actually an admin, right now? (from the
  // database, never from anything the client claims) ----
  const { data: callerProfile, error: callerProfileErr } = await admin
    .from("profiles")
    .select("role, status")
    .eq("id", callerId)
    .single();

  if (
    callerProfileErr ||
    !callerProfile ||
    callerProfile.role !== "admin" ||
    callerProfile.status === "disabled"
  ) {
    // Deliberately generic — never reveal *why* (e.g. "account is
    // disabled" vs "not an admin") to avoid leaking account details to
    // an unauthorized caller probing this endpoint.
    return json({ error: "Forbidden — admin privileges required." }, 403);
  }

  // ---- Step 3: validate the input fresh, server-side ----
  let body: { name?: string; email?: string; password?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid request body." }, 400);
  }

  const name = typeof body.name === "string" ? body.name.trim() : "";
  const email = typeof body.email === "string" ? body.email.trim() : "";
  const password = typeof body.password === "string" ? body.password : "";

  if (!name || !email || !password) {
    return json({ error: "Please complete all fields." }, 400);
  }
  if (!USERNAME_REGEX.test(name)) {
    return json({ error: "Username must be 3–20 characters, using only letters, numbers, and underscores." }, 400);
  }
  if (!GMAIL_ONLY_REGEX.test(email)) {
    return json({ error: "Please use a valid email address ending in @gmail.com." }, 400);
  }
  const pwIssue = passwordIssue(password);
  if (pwIssue) {
    return json({ error: pwIssue }, 400);
  }

  // Same case-insensitive uniqueness profiles_username_unique (see
  // supabase-setup.sql) enforces for every other signup path — checked
  // here too so an admin gets a clear "that username is taken" instead
  // of createUser() succeeding and then handle_new_user()'s own insert
  // failing against the index underneath it. service-role bypasses RLS,
  // so this can query profiles directly rather than needing the public
  // is_username_taken() RPC regular signups go through.
  const { data: existingName } = await admin
    .from("profiles")
    .select("id")
    .ilike("name", name)
    .maybeSingle();
  if (existingName) {
    return json({ error: "That username is already taken." }, 400);
  }

  // ---- Step 4: create the auth user (service-role only; never touches
  // the calling admin's own session) ----
  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true, // an admin-provisioned account shouldn't need an email click to be usable
    user_metadata: { name },
  });

  if (createErr || !created?.user) {
    const msg = /already registered|already exists/i.test(createErr?.message || "")
      ? "An account with that email already exists."
      : /username|profiles_username_unique|duplicate key.*name/i.test(createErr?.message || "")
      ? "That username is already taken."
      : "Could not create account.";
    return json({ error: msg }, 400);
  }

  const newUserId = created.user.id;

  // handle_new_user() (supabase-setup.sql) already fired on that insert
  // and created a profiles row with role='user' — the same safe default
  // every other signup path gets. Promote it explicitly, as the
  // service-role caller the trigger is written to allow through.
  const { error: promoteErr } = await admin
    .from("profiles")
    .update({ role: "admin" })
    .eq("id", newUserId);

  if (promoteErr) {
    // The auth user exists but wasn't promoted — don't claim success.
    return json(
      { error: "Account was created but could not be granted admin access. Please retry or check the profiles table." },
      500,
    );
  }

  return json({ success: true, id: newUserId, name, email });
});
