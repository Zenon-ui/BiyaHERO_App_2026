/* ============================================================
   SUPABASE CONFIG — fill these in with your own project's values
   ============================================================
   1. Create a free project at https://supabase.com
   2. In your project: Settings -> API
        - "Project URL"       -> paste into SUPABASE_URL below
        - "anon public" key   -> paste into SUPABASE_ANON_KEY below
   3. Run supabase-setup.sql once in the SQL Editor of your project
      (creates the `profiles` table + auth triggers).
   4. (Recommended) Authentication -> Providers -> Email:
        - Set "Minimum password length" to 6, to match this app's
          own rule, as defense-in-depth alongside the frontend check.
   The anon key is safe to ship in a public, static site like this
   one — it only grants the access your Row Level Security policies
   (see supabase-setup.sql) allow, never raw database access.
   ============================================================ */

const SUPABASE_URL = "https://dqfwdgymsehynrsanquk.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRxZndkZ3ltc2VoeW5yc2FucXVrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc1ODIzMzMsImV4cCI6MjEwMzE1ODMzM30.YhjmtxSgdAbTEVjmT0XcQu16ICNMHImsxmSo4NMbJ-k";

// `supabase` here is the global UMD export from the supabase-js CDN
// script tag loaded in BiyaHERO.html, right before this file.
export const supabaseClient =
  (typeof supabase !== "undefined" &&
    SUPABASE_URL &&
    SUPABASE_ANON_KEY &&
    SUPABASE_URL.startsWith("http"))
    ? supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY)
    : null;

if (!supabaseClient) {
  // Fails loudly in the console (not silently) so a developer notices
  // right away if they forgot to fill in their project's keys above.
  console.warn(
    "[BiyaHERO] Supabase is not configured yet — edit supabase-config.js " +
    "with your project URL and anon key. Login/signup will not work " +
    "until this is set up."
  );
}
