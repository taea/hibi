// わしの日々 — Workers の玄関番（第4工区・2026-07-05）
//
//   POST /letter … お手紙を受けて Slack #letters へ飛脚📮
//   それ以外     … 静的配信（dist/ の ASSETS に委譲）
//
// お手紙の掟（sizu.me / はくたけ式）: 名前欄なし・非公開・返信なし
// スパム対策: honeypot（website 欄）+ 本文 1〜2000 字
// Slack webhook は Secret（LETTERS_WEBHOOK）。コードには書かない

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/letter") {
      return handleLetter(request, env);
    }
    return env.ASSETS.fetch(request);
  },
};

async function handleLetter(request, env) {
  const json = (status, body) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json; charset=utf-8" },
    });

  let form;
  try {
    form = await request.formData();
  } catch {
    return json(400, { ok: false, error: "bad-request" });
  }

  // honeypot: 人間には見えない欄。埋まってたら bot（成功したふりで帰す）
  if ((form.get("website") || "").toString() !== "") {
    return json(200, { ok: true });
  }

  const body = (form.get("body") || "").toString().trim();
  const page = (form.get("page") || "").toString().slice(0, 200);
  if (body.length < 1) return json(400, { ok: false, error: "empty" });
  if (body.length > 2000) return json(400, { ok: false, error: "too-long" });

  if (!env.LETTERS_WEBHOOK) {
    // Secret 未設定のうちは受け取れない（設定漏れが黙って握り潰されないように）
    return json(500, { ok: false, error: "letterbox-not-ready" });
  }

  // Slack の作法: & < > だけエスケープ
  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const quoted = esc(body).split("\n").map((l) => `> ${l}`).join("\n");
  const text = `📮 お手紙が届いたぜ\n${quoted}\n\n🔗 https://taea.kani.show${esc(page)}`;

  const res = await fetch(env.LETTERS_WEBHOOK, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ text }),
  });
  if (!res.ok) return json(502, { ok: false, error: "hikyaku-failed" });

  return json(200, { ok: true });
}
