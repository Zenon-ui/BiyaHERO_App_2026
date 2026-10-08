/* ============================================================
   TRAFFIC CONFIG — optional, for live per-segment traffic colors
   ============================================================
   BiyaHERO's route line and speedometer already reflect REAL data
   with zero setup:
     - The speed shown always comes from the phone's actual GPS
       (see GPSManager in BiyaHERO.js) — never a fake/simulated number.
     - The route itself is a real, road-following path from OSRM.
   What this file adds on top is OPTIONAL: live, segment-by-segment
   congestion color (green = low, yellow = moderate, orange = heavy,
   red = severe) painted onto the route line itself, sourced from a
   real traffic provider — TomTom's Traffic Flow API — instead of
   everywhere just being a single flat color. The 4-way color scale
   itself lives in classifyTrafficRatio() in BiyaHERO.js, not here —
   this file only turns the feature on/off and holds the key.

   Without a key here, BiyaHERO does NOT invent or simulate a fake
   traffic pattern. The route simply renders in a single neutral
   color, and the speedometer/traffic label still reflects your
   real GPS speed. Nothing about accuracy is lost — you just don't
   get the green/yellow/red paint job on the line itself.

   To turn that on:
     1. Create a free account at https://developer.tomtom.com
     2. Create an API key (Dashboard -> My Apps -> your app -> Keys).
        The free tier includes a daily quota that's generous for a
        single phone's normal use.
     3. Paste that key below.
   No backend or billing setup is required for the free tier.
   ============================================================ */

const TOMTOM_TRAFFIC_API_KEY = ""; // e.g. "AbCdEfGhIjKlMnOpQrStUvWxYz123456"

const TrafficConfig = {
  enabled: Boolean(TOMTOM_TRAFFIC_API_KEY && TOMTOM_TRAFFIC_API_KEY.trim().length > 0),
  apiKey: TOMTOM_TRAFFIC_API_KEY.trim()
};

// BiyaHERO.js is an ES module, so this file's top-level const is private to it.
// Export it (and mirror on window for console debugging) so the traffic
// overlay code can actually see the key / enabled flag.
export { TrafficConfig };
if (typeof window !== 'undefined') window.TrafficConfig = TrafficConfig;

if (!TrafficConfig.enabled) {
  console.info(
    "[BiyaHERO] No TomTom traffic key configured (traffic-config.js) — " +
    "routes will render in a single neutral color instead of live " +
    "green/yellow/red congestion. Real GPS speed still drives the " +
    "speedometer either way."
  );
}
