// gym-event-kids（2026-11-17 メイ）
// 子どもの人数で数えるイベント（男子新体操 体験会など）を、クラブアプリから申し込むための受け口。
// ・クラブアプリのログイン（クラブ用Supabase）を確認してから、体操教室DBに申し込みを入れる
// ・定員は体操教室アプリと合算（gym_event_entries を共有）
// ・設定：Verify JWT は OFF（クラブ側のトークンで来るため。中で必ず確認しています）
import { createClient } from "jsr:@supabase/supabase-js@2";

const APPS: Record<string, { url: string; key: string }> = {
  club: { url: "https://iioiizauksrawbriyegf.supabase.co", key: "sb_publishable_WWuX924pUHB2JKEt-g-TMQ_tEy_4rUX" },
};
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sowers-app",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const J = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

const jstToday = () => new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10);
function ageOf(birth: string | null): number | null {
  if (!birth) return null;
  const [y, m, d] = String(birth).slice(0, 10).split("-").map(Number);
  if (!y) return null;
  const [ty, tm, td] = jstToday().split("-").map(Number);
  let a = ty - y;
  if (tm < m || (tm === m && td < d)) a--;
  return a;
}
const errMsg = (e: { message?: string } | null) => String((e && e.message) || "処理に失敗しました").replace(/^.*?ERROR:\s*/, "");
const nKids = (x: { kids?: unknown[]; guests?: unknown[] }) => (x.kids || []).length + (x.guests || []).length;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const app = (req.headers.get("x-sowers-app") || "").trim();
    const A = APPS[app];
    if (!A) return J({ error: "このアプリからは申し込めません" }, 400);
    const tok = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (!tok) return J({ error: "ログインし直してください" }, 401);
    const ext = (path: string) => fetch(A.url + path, { headers: { apikey: A.key, Authorization: "Bearer " + tok } });
    const ur = await ext("/auth/v1/user");
    if (!ur.ok) return J({ error: "ログインし直してください" }, 401);
    const user = await ur.json();
    const uid = String(user && user.id || "");
    if (!uid) return J({ error: "ログインし直してください" }, 401);
    const b = await req.json().catch(() => ({}));
    const action = String(b.action || "");

    if (action === "state") {
      const { data: evs, error } = await db.from("gym_events").select("*").eq("cap_unit", "kids").contains("apps", [app]).gte("date", jstToday());
      if (error) return J({ error: errMsg(error) }, 500);
      const ids = (evs || []).map((e) => e.id);
      const counts: Record<string, { kids: number; waiting: number }> = {};
      const mine: unknown[] = [];
      if (ids.length) {
        const { data: en } = await db.from("gym_event_entries").select("*").in("event_id", ids).eq("status", "active");
        (en || []).forEach((x) => {
          const o = counts[x.event_id] || (counts[x.event_id] = { kids: 0, waiting: 0 });
          o[x.waitlist ? "waiting" : "kids"] += nKids(x);
          if (x.source === app && x.ext_user === uid) mine.push(x);
        });
      }
      return J({ events: evs || [], counts, mine });
    }

    if (action === "apply") {
      const want: { id: string; age?: string | number }[] = (Array.isArray(b.kids) ? b.kids : []).filter((k: { id?: unknown }) => k && k.id);
      let kids: unknown[] = [];
      if (want.length) {
        const ids = want.map((k) => encodeURIComponent(String(k.id))).join(",");
        const r = await ext(`/rest/v1/children?select=id,name,nick,birth,graduated_at,guardian_id&guardian_id=eq.${encodeURIComponent(uid)}&id=in.(${ids})`);
        const rows: { id: string; name?: string; nick?: string; birth?: string; graduated_at?: string }[] = r.ok ? await r.json() : [];
        kids = rows.filter((c) => !c.graduated_at).map((c) => {
          const w = want.find((k) => String(k.id) === String(c.id));
          const a = ageOf(c.birth || null);
          return { id: c.id, name: c.name || c.nick || "", classroom: "クラブ", class_name: "", age: a != null ? a : (w && w.age !== "" && w.age != null ? Number(w.age) : null) };
        });
      }
      let pname = "";
      try {
        const pr = await ext(`/rest/v1/profiles?select=name,nick&id=eq.${encodeURIComponent(uid)}`);
        const p = pr.ok ? (await pr.json())[0] : null;
        pname = (p && (p.name || p.nick)) || "";
      } catch (_) { /* 名前が取れなくても申し込みは続ける */ }
      const guests = (Array.isArray(b.guests) ? b.guests : []).map((g: { name?: string; age?: unknown }) => ({ name: String(g && g.name || "").trim(), age: g && g.age }));
      const { data, error } = await db.rpc("gym_event_apply_kids_ext", {
        p_event_id: String(b.event_id || ""), p_source: app, p_ext_user: uid, p_parent_name: pname,
        p_kids: kids, p_guests: guests, p_note: String(b.note || "").slice(0, 300),
      });
      if (error) return J({ error: errMsg(error) }, 400);
      return J({ entry: Array.isArray(data) ? data[0] : data });
    }

    if (action === "cancel" || action === "attend") {
      const fn = action === "cancel" ? "gym_event_cancel_kids_ext" : "gym_event_attend_kids_ext";
      const { error } = await db.rpc(fn, { p_event_id: String(b.event_id || ""), p_source: app, p_ext_user: uid });
      if (error) return J({ error: errMsg(error) }, 400);
      return J({ ok: true });
    }
    return J({ error: "unknown action" }, 400);
  } catch (_e) {
    return J({ error: "処理に失敗しました" }, 500);
  }
});
