// same-origin image proxy for publication avatar art.
// cdn.bsky.app sends no CORS headers, so the atlas can't getImageData on
// avatars loaded directly (tainted canvas). proxying through our origin
// sidesteps CORS entirely. locked to the bsky CDN so this isn't an open
// proxy; responses are edge-cached for a day.
export async function onRequestGet(context) {
  const url = new URL(context.request.url);
  const u = url.searchParams.get("u");
  if (!u) return new Response("missing u", { status: 400 });

  let upstream;
  try {
    upstream = new URL(u);
  } catch {
    return new Response("bad url", { status: 400 });
  }
  if (
    upstream.protocol !== "https:" ||
    upstream.hostname !== "cdn.bsky.app" ||
    !upstream.pathname.startsWith("/img/")
  ) {
    return new Response("forbidden", { status: 403 });
  }

  const cache = caches.default;
  const cacheKey = new Request(url.toString());
  const cached = await cache.match(cacheKey);
  if (cached) return cached;

  const up = await fetch(upstream.toString());
  if (!up.ok) return new Response("upstream " + up.status, { status: 502 });

  const resp = new Response(up.body, {
    headers: {
      "Content-Type": up.headers.get("Content-Type") || "image/jpeg",
      "Cache-Control": "public, max-age=86400, immutable",
      "Access-Control-Allow-Origin": "*",
    },
  });
  context.waitUntil(cache.put(cacheKey, resp.clone()));
  return resp;
}
