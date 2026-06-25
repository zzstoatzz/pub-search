import { ImageResponse } from "workers-og";

const API_URL = "https://leaflet-search-backend.fly.dev";

function stripQuotes(s) {
  return s.replace(/^"+|"+$/g, "");
}

const DATE_PRESET_LABELS = {
  week: "last week",
  month: "last month",
  year: "last year",
};

// reverse-map a since ISO date to a human label
function labelFromSince(since) {
  if (!since) return null;
  const now = new Date();
  const d = new Date(since);
  const days = Math.round((now - d) / (1000 * 60 * 60 * 24));
  if (days <= 8) return DATE_PRESET_LABELS.week;
  if (days <= 32) return DATE_PRESET_LABELS.month;
  if (days <= 370) return DATE_PRESET_LABELS.year;
  return since; // fallback to raw date
}

// chip colors matching the frontend
const CHIP_COLORS = {
  tag: { bg: "rgba(27, 115, 64, 0.3)", border: "#1B7340", text: "#2a9d5c" },
  platform: {
    bg: "rgba(180, 100, 64, 0.3)",
    border: "#d4956a",
    text: "#d4956a",
  },
  date: { bg: "rgba(14, 165, 233, 0.3)", border: "#0ea5e9", text: "#38bdf8" },
  mode: { bg: "rgba(139, 92, 246, 0.3)", border: "#8b5cf6", text: "#a78bfa" },
};

function truncate(str, max) {
  if (!str) return "";
  return str.length > max ? str.slice(0, max) + "..." : str;
}

function buildChip(label, type) {
  const c = CHIP_COLORS[type] || CHIP_COLORS.tag;
  return {
    type: "div",
    props: {
      style: {
        background: c.bg,
        border: `1px solid ${c.border}`,
        color: c.text,
        padding: "6px 16px",
        borderRadius: "6px",
        fontSize: "22px",
        fontFamily: '"JetBrains Mono", monospace',
      },
      children: label,
    },
  };
}

async function fetchSearchResults(params) {
  const url = new URL(`${API_URL}/search`);
  url.searchParams.set("format", "v2");
  url.searchParams.set("limit", "3");
  if (params.q) url.searchParams.set("q", params.q);
  if (params.tag) url.searchParams.set("tag", params.tag);
  if (params.platform) url.searchParams.set("platform", params.platform);
  if (params.since) url.searchParams.set("since", params.since);
  if (params.mode) url.searchParams.set("mode", params.mode);

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2000);
  try {
    const res = await fetch(url.toString(), { signal: controller.signal });
    clearTimeout(timeout);
    const data = await res.json();
    return {
      results: data.results || [],
      total: data.total || (data.results ? data.results.length : 0),
    };
  } catch {
    clearTimeout(timeout);
    return null;
  }
}

async function fetchCurators(since) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2000);
  const qs = since && since !== "all" ? `?since=${encodeURIComponent(since)}&limit=10` : `?limit=10`;
  try {
    const res = await fetch(`${API_URL}/curators${qs}`, { signal: controller.signal });
    clearTimeout(timeout);
    return await res.json();
  } catch {
    clearTimeout(timeout);
    return null;
  }
}

function buildCuratorsImage(rows, since, handleMap) {
  const top = (rows || []).slice(0, 6);
  const totalRecs = (rows || []).reduce((s, r) => s + (r.totalRecommends || 0), 0);
  const windowLabel = since && WINDOW_LABELS[since] ? WINDOW_LABELS[since] : "all-time";
  const handles = handleMap || new Map();

  const shortDid = (did) => {
    const parts = String(did || "").split(":");
    const last = parts[parts.length - 1] || did || "";
    return last.length > 14 ? last.slice(0, 14) + "…" : last;
  };

  const headerBlock = {
    type: "div",
    props: {
      style: { display: "flex", flexDirection: "column", gap: "10px" },
      children: [
        {
          type: "div",
          props: {
            style: { display: "flex", alignItems: "center", gap: "10px", color: "#888", fontSize: "24px" },
            children: [
              "pub search",
              { type: "span", props: { style: { color: "#444" }, children: "/" } },
              { type: "span", props: { style: { color: "#555" }, children: "curators" } },
            ],
          },
        },
        {
          type: "div",
          props: {
            style: {
              color: "#fff",
              fontSize: "44px",
              letterSpacing: "-0.5px",
              lineHeight: "1",
              display: "flex",
              alignItems: "baseline",
              gap: "14px",
              flexWrap: "wrap",
            },
            children: [
              "top curators",
              { type: "div", props: { style: { color: "#38bdf8", fontSize: "22px" }, children: windowLabel } },
            ],
          },
        },
      ],
    },
  };

  const list = top.map((c, i) => ({
    type: "div",
    props: {
      style: {
        display: "flex",
        alignItems: "center",
        gap: "20px",
        padding: "10px 0",
        borderBottom: "1px solid #1d1d1d",
      },
      children: [
        {
          type: "div",
          props: {
            style: {
              color: i < 3 ? "#2a9d5c" : "#555",
              fontSize: "22px",
              width: "56px",
              textAlign: "right",
            },
            children: `#${i + 1}`,
          },
        },
        {
          type: "div",
          props: {
            style: { display: "flex", flexDirection: "column", flex: "1", minWidth: "0", gap: "4px" },
            children: [
              {
                type: "div",
                props: {
                  style: { color: "#fff", fontSize: "22px" },
                  children: handles.get(c.did) ? "@" + handles.get(c.did) : shortDid(c.did),
                },
              },
              {
                type: "div",
                props: {
                  style: { color: "#555", fontSize: "15px" },
                  children: `${c.uniqueDocs || 0} docs recommended`,
                },
              },
            ],
          },
        },
        {
          type: "div",
          props: {
            style: {
              color: i < 3 ? "#2a9d5c" : "#888",
              fontSize: "24px",
              fontVariantNumeric: "tabular-nums",
            },
            children: String(c.totalRecommends || c.recommendCount || 0),
          },
        },
      ],
    },
  }));

  const listBlock = {
    type: "div",
    props: { style: { display: "flex", flexDirection: "column" }, children: list },
  };

  const footerBlock = totalRecs > 0
    ? {
        type: "div",
        props: {
          style: { color: "#444", fontSize: "16px" },
          children: `${totalRecs.toLocaleString()} recommends given by the top 10 · pub-search.waow.tech/curators`,
        },
      }
    : null;

  const outerChildren = [headerBlock, listBlock];
  if (footerBlock) outerChildren.push(footerBlock);

  return {
    type: "div",
    props: {
      style: {
        display: "flex",
        flexDirection: "column",
        width: "1200px",
        height: "630px",
        background: "#050505",
        padding: "40px 56px 32px 56px",
        fontFamily: '"JetBrains Mono", monospace',
        gap: "16px",
      },
      children: outerChildren,
    },
  };
}

async function fetchRecommended(since, sort, author, curator) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2000);
  const params = new URLSearchParams({ limit: "20" });
  if (since && since !== "all") params.set("since", since);
  if (sort && sort !== "top") params.set("sort", sort);
  // curator beats author (matches backend precedence)
  if (curator) params.set("curator", curator);
  else if (author) params.set("author", author);
  try {
    const res = await fetch(`${API_URL}/recommended?${params.toString()}`, {
      signal: controller.signal,
    });
    clearTimeout(timeout);
    return await res.json();
  } catch {
    clearTimeout(timeout);
    return null;
  }
}

// Identity lookups go through typeahead.waow.tech (drop-in for
// app.bsky.actor.getProfiles) so the OG worker doesn't hit
// public.api.bsky.app directly. Both single + batch use the plural
// endpoint — `getProfile` (singular) isn't exposed by typeahead.
const TYPEAHEAD_BASE = "https://typeahead.waow.tech";

async function resolveHandles(actors) {
  const out = new Map();
  if (!actors || actors.length === 0) return out;
  const unique = Array.from(new Set(actors.filter(Boolean))).slice(0, 25);
  if (unique.length === 0) return out;
  const qs = unique.map((a) => "actors=" + encodeURIComponent(a)).join("&");
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 1500);
  try {
    const res = await fetch(
      `${TYPEAHEAD_BASE}/xrpc/app.bsky.actor.getProfiles?${qs}`,
      { signal: controller.signal },
    );
    clearTimeout(timeout);
    if (!res.ok) return out;
    const d = await res.json();
    if (d && Array.isArray(d.profiles)) {
      for (const p of d.profiles) {
        if (p.handle && p.did) out.set(p.did, p.handle);
      }
    }
    return out;
  } catch {
    clearTimeout(timeout);
    return out;
  }
}

async function resolveHandle(didOrHandle) {
  if (!didOrHandle) return null;
  if (!didOrHandle.startsWith("did:")) return didOrHandle.replace(/^@/, "");
  const map = await resolveHandles([didOrHandle]);
  return map.get(didOrHandle) || null;
}

function shortDidImg(did) {
  const parts = String(did || "").split(":");
  const last = parts[parts.length - 1] || did || "";
  return last.length > 14 ? last.slice(0, 14) + "…" : last;
}

const WINDOW_LABELS = {
  day: "in the last day",
  week: "this week",
  month: "this month",
  year: "this year",
};

function buildRecommendedImage(rows, params) {
  const { since, sort, author, curator, handle } = params || {};
  const top = (rows || []).slice(0, 6);
  const totalRecs = (rows || []).reduce((s, r) => s + (r.recommendCount || 0), 0);
  const windowLabel = since && WINDOW_LABELS[since] ? WINDOW_LABELS[since] : "all-time";

  // Title varies with sort, author, curator:
  //   curator    → "posts recommended by @handle"
  //   author     → "@handle's most-recommended posts" / "@handle's trending posts"
  //   trending   → "trending posts"
  //   default    → "most-recommended posts"
  const actor = curator || author;
  const actorLabel = actor
    ? (handle ? "@" + handle : "@" + shortDidImg(actor))
    : null;
  let title;
  if (curator && actorLabel) {
    title = `posts recommended by ${actorLabel}`;
  } else if (author && actorLabel) {
    title = sort === "trending"
      ? `${actorLabel}'s trending posts`
      : `${actorLabel}'s most-recommended posts`;
  } else if (sort === "trending") {
    title = "trending posts";
  } else {
    title = "most-recommended posts";
  }

  // header block: "pub search / recommended" tag, then the page title.
  // Putting these inside a flex column with explicit gap is more reliable
  // in satori than mixing marginTop on siblings.
  const headerBlock = {
    type: "div",
    props: {
      style: {
        display: "flex",
        flexDirection: "column",
        gap: "10px",
      },
      children: [
        {
          type: "div",
          props: {
            style: {
              display: "flex",
              alignItems: "center",
              gap: "10px",
              color: "#888",
              fontSize: "24px",
            },
            children: [
              "pub search",
              { type: "span", props: { style: { color: "#444" }, children: "/" } },
              { type: "span", props: { style: { color: "#555" }, children: "recommended" } },
            ],
          },
        },
        {
          type: "div",
          props: {
            style: {
              color: "#fff",
              fontSize: "44px",
              letterSpacing: "-0.5px",
              lineHeight: "1",
              display: "flex",
              alignItems: "baseline",
              gap: "14px",
              flexWrap: "wrap",
            },
            children: [
              title,
              {
                type: "div",
                props: {
                  style: { color: "#38bdf8", fontSize: "22px" },
                  children: windowLabel,
                },
              },
            ],
          },
        },
      ],
    },
  };

  // each row of the leaderboard
  const list = top.map((doc, i) => ({
    type: "div",
    props: {
      style: {
        display: "flex",
        alignItems: "center",
        gap: "20px",
        padding: "10px 0",
        borderBottom: "1px solid #1d1d1d",
      },
      children: [
        {
          type: "div",
          props: {
            style: {
              color: i < 3 ? "#2a9d5c" : "#555",
              fontSize: "22px",
              width: "56px",
              textAlign: "right",
            },
            children: `#${i + 1}`,
          },
        },
        {
          type: "div",
          props: {
            style: {
              display: "flex",
              flexDirection: "column",
              flex: "1",
              minWidth: "0",
              gap: "4px",
            },
            children: [
              {
                type: "div",
                props: {
                  style: {
                    color: "#fff",
                    fontSize: "22px",
                    overflow: "hidden",
                  },
                  children: truncate(doc.title || "untitled", 52),
                },
              },
              {
                type: "div",
                props: {
                  style: {
                    color: "#555",
                    fontSize: "15px",
                  },
                  children: doc.basePath || doc.publicationName || doc.platform || "",
                },
              },
            ],
          },
        },
        // heart + count
        {
          type: "div",
          props: {
            style: {
              color: i < 3 ? "#2a9d5c" : "#888",
              fontSize: "24px",
              fontVariantNumeric: "tabular-nums",
            },
            children: String(doc.recommendCount || 0),
          },
        },
      ],
    },
  }));

  // wrap the list in its own flex column so we can rely on `gap`
  // instead of per-row marginTop (which is flaky in satori).
  const listBlock = {
    type: "div",
    props: {
      style: {
        display: "flex",
        flexDirection: "column",
      },
      children: list,
    },
  };

  const footerBlock = totalRecs > 0
    ? {
        type: "div",
        props: {
          style: {
            color: "#444",
            fontSize: "16px",
          },
          children: `${totalRecs.toLocaleString()} total recommends across the top 50 · pub-search.waow.tech/recommended`,
        },
      }
    : null;

  // Outer layout: explicit gap between header / list / footer.
  // Padding leaves real breathing room on all sides.
  const outerChildren = [headerBlock, listBlock];
  if (footerBlock) outerChildren.push(footerBlock);

  return {
    type: "div",
    props: {
      style: {
        display: "flex",
        flexDirection: "column",
        width: "1200px",
        height: "630px",
        background: "#050505",
        padding: "40px 56px 32px 56px",
        fontFamily: '"JetBrains Mono", monospace',
        gap: "16px",
      },
      children: outerChildren,
    },
  };
}

async function fetchSubscribed(view, since) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2000);
  const params = new URLSearchParams({ limit: "10" });
  if (view === "people") params.set("view", "people");
  if (since && since !== "all") params.set("since", since);
  try {
    const res = await fetch(`${API_URL}/subscribed?${params.toString()}`, {
      signal: controller.signal,
    });
    clearTimeout(timeout);
    return await res.json();
  } catch {
    clearTimeout(timeout);
    return null;
  }
}

// Subscription leaderboard card. Mirrors buildRecommendedImage / buildCuratorsImage
// (same header tag + windowLabel + 6-row list). Two views:
//   publications → name + host + subscriber count
//   people       → @handle + "N publications" + subscriber count (handle-resolved)
function buildSubscribedImage(rows, params) {
  const { view, since, handleMap } = params || {};
  const isPeople = view === "people";
  const top = (rows || []).slice(0, 6);
  // show the WINDOWED subscriber count — it's what drives the rank, so the
  // numbers descend in order (mirrors the recommended card's recommendCount).
  // For all-time it equals totalCount anyway.
  const subCount = (r) => (r.subscriberCount != null ? r.subscriberCount : r.totalCount || 0);
  const totalSubs = (rows || []).reduce((s, r) => s + subCount(r), 0);
  const windowLabel = since && WINDOW_LABELS[since] ? WINDOW_LABELS[since] : "all-time";
  const handles = handleMap || new Map();
  const title = isPeople ? "most-subscribed people" : "most-subscribed publications";

  const shortDid = (did) => {
    const parts = String(did || "").split(":");
    const last = parts[parts.length - 1] || did || "";
    return last.length > 14 ? last.slice(0, 14) + "…" : last;
  };

  const headerBlock = {
    type: "div",
    props: {
      style: { display: "flex", flexDirection: "column", gap: "10px" },
      children: [
        {
          type: "div",
          props: {
            style: { display: "flex", alignItems: "center", gap: "10px", color: "#888", fontSize: "24px" },
            children: [
              "pub search",
              { type: "span", props: { style: { color: "#444" }, children: "/" } },
              { type: "span", props: { style: { color: "#555" }, children: "subscribed" } },
            ],
          },
        },
        {
          type: "div",
          props: {
            style: {
              color: "#fff",
              fontSize: "44px",
              letterSpacing: "-0.5px",
              lineHeight: "1",
              display: "flex",
              alignItems: "baseline",
              gap: "14px",
              flexWrap: "wrap",
            },
            children: [
              title,
              { type: "div", props: { style: { color: "#38bdf8", fontSize: "22px" }, children: windowLabel } },
            ],
          },
        },
      ],
    },
  };

  const list = top.map((r, i) => {
    const primary = isPeople
      ? (handles.get(r.did) ? "@" + handles.get(r.did) : shortDid(r.did))
      : truncate(r.name || r.basePath || "untitled", 52);
    const secondary = isPeople
      ? `${r.pubCount || 0} publication${(r.pubCount || 0) === 1 ? "" : "s"}`
      : (r.basePath || r.platform || "");
    const count = subCount(r);
    return {
      type: "div",
      props: {
        style: {
          display: "flex",
          alignItems: "center",
          gap: "20px",
          padding: "10px 0",
          borderBottom: "1px solid #1d1d1d",
        },
        children: [
          {
            type: "div",
            props: {
              style: { color: i < 3 ? "#2a9d5c" : "#555", fontSize: "22px", width: "56px", textAlign: "right" },
              children: `#${i + 1}`,
            },
          },
          {
            type: "div",
            props: {
              style: { display: "flex", flexDirection: "column", flex: "1", minWidth: "0", gap: "4px" },
              children: [
                { type: "div", props: { style: { color: "#fff", fontSize: "22px", overflow: "hidden" }, children: primary } },
                { type: "div", props: { style: { color: "#555", fontSize: "15px" }, children: secondary } },
              ],
            },
          },
          {
            type: "div",
            props: {
              style: { color: i < 3 ? "#2a9d5c" : "#888", fontSize: "24px", fontVariantNumeric: "tabular-nums" },
              children: String(count),
            },
          },
        ],
      },
    };
  });

  const listBlock = {
    type: "div",
    props: { style: { display: "flex", flexDirection: "column" }, children: list },
  };

  const footerBlock = totalSubs > 0
    ? {
        type: "div",
        props: {
          style: { color: "#444", fontSize: "16px" },
          children: `${totalSubs.toLocaleString()} subscribers across the top ${top.length} · pub-search.waow.tech/subscribed`,
        },
      }
    : null;

  const outerChildren = [headerBlock, listBlock];
  if (footerBlock) outerChildren.push(footerBlock);

  return {
    type: "div",
    props: {
      style: {
        display: "flex",
        flexDirection: "column",
        width: "1200px",
        height: "630px",
        background: "#050505",
        padding: "40px 56px 32px 56px",
        fontFamily: '"JetBrains Mono", monospace',
        gap: "16px",
      },
      children: outerChildren,
    },
  };
}

async function fetchStats() {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2000);
  try {
    const res = await fetch(`${API_URL}/stats`, {
      signal: controller.signal,
    });
    clearTimeout(timeout);
    return await res.json();
  } catch {
    clearTimeout(timeout);
    return null;
  }
}

// platform colors for atlas OG image (core colors from the canvas)
const PLATFORM_DOTS = [
  { color: "#4ade80", label: "leaflet" },
  { color: "#60a5fa", label: "whitewind" },
  { color: "#fbbf24", label: "pckt" },
  { color: "#fb7185", label: "offprint" },
  { color: "#2dd4bf", label: "greengale" },
  { color: "#9ca3af", label: "other" },
];

// seeded PRNG (mulberry32) for deterministic constellation
function mulberry32(seed) {
  return function () {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// box-muller gaussian from uniform random
function gaussian(rng) {
  const u1 = rng(), u2 = rng();
  return Math.sqrt(-2 * Math.log(u1 + 0.0001)) * Math.cos(2 * Math.PI * u2);
}

// platform weights matching real index distribution
const PLATFORM_WEIGHTS = [0.45, 0.20, 0.08, 0.05, 0.07, 0.15];

function pickPlatform(rng) {
  let r = rng(), acc = 0;
  for (let i = 0; i < PLATFORM_WEIGHTS.length; i++) {
    acc += PLATFORM_WEIGHTS[i];
    if (r < acc) return i;
  }
  return 0;
}

function atlasConstellation() {
  const rng = mulberry32(42);
  const dots = [];
  // center of the constellation, offset right to leave space for text
  const cx = 740, cy = 310;

  // generate ~180 dots with organic cluster shape
  for (let i = 0; i < 180; i++) {
    const pi = pickPlatform(rng);
    const platform = PLATFORM_DOTS[pi];

    // gaussian distribution with elliptical stretch
    let dx = gaussian(rng) * 140;
    let dy = gaussian(rng) * 120;

    // slight rotation to feel organic
    const angle = 0.3;
    const rx = dx * Math.cos(angle) - dy * Math.sin(angle);
    const ry = dx * Math.sin(angle) + dy * Math.cos(angle);

    let x = cx + rx;
    let y = cy + ry;

    // clamp to image bounds with padding
    x = Math.max(20, Math.min(1170, x));
    y = Math.max(20, Math.min(610, y));

    // distance from center determines size and brightness
    const dist = Math.sqrt(rx * rx + ry * ry);
    const isCore = dist < 100;
    const isMid = dist < 180;

    // size: core dots slightly larger, some random "bright stars"
    const isStar = rng() < 0.06;
    let size;
    if (isStar) size = 6 + Math.floor(rng() * 5);
    else if (isCore) size = 2 + Math.floor(rng() * 3);
    else size = 2 + Math.floor(rng() * 2);

    // opacity: denser and brighter in core
    let opacity;
    if (isStar) opacity = 0.85 + rng() * 0.15;
    else if (isCore) opacity = 0.5 + rng() * 0.3;
    else if (isMid) opacity = 0.3 + rng() * 0.25;
    else opacity = 0.15 + rng() * 0.2;

    const style = {
      position: "absolute",
      left: `${Math.round(x)}px`,
      top: `${Math.round(y)}px`,
      width: `${size}px`,
      height: `${size}px`,
      borderRadius: "50%",
      background: platform.color,
      opacity: opacity,
    };

    // bright stars get a glow
    if (isStar) {
      style.boxShadow = `0 0 ${size * 2}px ${platform.color}`;
    }

    dots.push({
      type: "div",
      props: { style, children: "" },
    });
  }

  // add a few distant outlier dots for depth
  const outliers = [
    [120, 180], [90, 400], [1050, 120], [1100, 480],
    [200, 520], [1020, 80], [350, 100], [950, 530],
  ];
  for (let i = 0; i < outliers.length; i++) {
    const pi = pickPlatform(rng);
    dots.push({
      type: "div",
      props: {
        style: {
          position: "absolute",
          left: `${outliers[i][0]}px`,
          top: `${outliers[i][1]}px`,
          width: "3px",
          height: "3px",
          borderRadius: "50%",
          background: PLATFORM_DOTS[pi].color,
          opacity: 0.25 + rng() * 0.15,
        },
        children: "",
      },
    });
  }

  return dots;
}

function buildConstellationImage(docCount) {
  const children = [];

  // dense constellation as background
  children.push(...atlasConstellation());

  // subtle center glow behind the cluster
  children.push({
    type: "div",
    props: {
      style: {
        position: "absolute",
        left: "540px",
        top: "110px",
        width: "400px",
        height: "400px",
        borderRadius: "50%",
        background: "radial-gradient(circle, rgba(74,222,128,0.04) 0%, rgba(74,222,128,0.01) 40%, transparent 70%)",
      },
      children: "",
    },
  });

  // text container on the left with subtle gradient fade
  children.push({
    type: "div",
    props: {
      style: {
        position: "absolute",
        left: "0",
        top: "0",
        bottom: "0",
        width: "520px",
        background: "linear-gradient(to right, #050505 60%, transparent 100%)",
      },
      children: "",
    },
  });

  // text content (positioned above the gradient)
  children.push({
    type: "div",
    props: {
      style: {
        position: "relative",
        display: "flex",
        flexDirection: "column",
        height: "100%",
        padding: "0",
        maxWidth: "440px",
      },
      children: [
        // header
        {
          type: "div",
          props: {
            style: {
              color: "#666",
              fontSize: "26px",
              fontFamily: '"JetBrains Mono", monospace',
            },
            children: "pub search",
          },
        },
        // title
        {
          type: "div",
          props: {
            style: {
              color: "#fff",
              fontSize: "52px",
              fontFamily: '"JetBrains Mono", monospace',
              marginTop: "16px",
              letterSpacing: "2px",
            },
            children: "atlas",
          },
        },
        // subtitle
        {
          type: "div",
          props: {
            style: {
              color: "#555",
              fontSize: "20px",
              fontFamily: '"JetBrains Mono", monospace',
              marginTop: "14px",
              lineHeight: "1.5",
            },
            children: "2d semantic map of atproto publishing platforms",
          },
        },
        // platform legend
        {
          type: "div",
          props: {
            style: {
              display: "flex",
              flexWrap: "wrap",
              gap: "12px",
              marginTop: "36px",
            },
            children: PLATFORM_DOTS.slice(0, 5).map((p) => ({
              type: "div",
              props: {
                style: {
                  display: "flex",
                  alignItems: "center",
                  gap: "6px",
                },
                children: [
                  {
                    type: "div",
                    props: {
                      style: {
                        width: "8px",
                        height: "8px",
                        borderRadius: "50%",
                        background: p.color,
                        boxShadow: `0 0 6px ${p.color}`,
                      },
                      children: "",
                    },
                  },
                  {
                    type: "div",
                    props: {
                      style: {
                        color: "#555",
                        fontSize: "16px",
                        fontFamily: '"JetBrains Mono", monospace',
                      },
                      children: p.label,
                    },
                  },
                ],
              },
            })),
          },
        },
        // footer
        {
          type: "div",
          props: {
            style: {
              color: "#444",
              fontSize: "18px",
              fontFamily: '"JetBrains Mono", monospace',
              marginTop: "auto",
            },
            children: docCount
              ? `${docCount.toLocaleString()} documents`
              : "explore the index",
          },
        },
      ],
    },
  });

  return {
    type: "div",
    props: {
      style: {
        display: "flex",
        flexDirection: "column",
        position: "relative",
        width: "1200px",
        height: "630px",
        background: "#050505",
        padding: "48px 56px",
        fontFamily: '"JetBrains Mono", monospace',
        overflow: "hidden",
      },
      children,
    },
  };
}

// ---------- /wrapped (one identity's long-form atmosphere) ----------

async function fetchWrapped(didOrHandle) {
  if (!didOrHandle) return null;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2000);
  const key = didOrHandle.startsWith("did:") ? "did" : "handle";
  try {
    const res = await fetch(
      `${API_URL}/wrapped?${key}=${encodeURIComponent(didOrHandle)}`,
      { signal: controller.signal },
    );
    clearTimeout(timeout);
    if (!res.ok) return null;
    return await res.json();
  } catch {
    clearTimeout(timeout);
    return null;
  }
}

// full profile (handle + displayName) for the header, via typeahead getProfiles.
async function resolveProfile(didOrHandle) {
  if (!didOrHandle) return null;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 1500);
  try {
    const res = await fetch(
      `${TYPEAHEAD_BASE}/xrpc/app.bsky.actor.getProfiles?actors=${encodeURIComponent(didOrHandle)}`,
      { signal: controller.signal },
    );
    clearTimeout(timeout);
    if (!res.ok) return null;
    const d = await res.json();
    const p = d && Array.isArray(d.profiles) ? d.profiles[0] : null;
    return p ? { handle: p.handle || null, displayName: p.displayName || null } : null;
  } catch {
    clearTimeout(timeout);
    return null;
  }
}

function buildWrappedImage(data, profile) {
  const accent = "#2a9d5c";
  const pub = (data && data.publisher) || {};
  const cur = (data && data.curator) || {};
  const rdr = (data && data.reader) || {};

  const handle = profile && profile.handle ? profile.handle : null;
  const displayName = profile && profile.displayName ? profile.displayName : null;
  const headline = displayName || (handle ? "@" + handle : "your") + "";
  const subhandle = displayName && handle ? "@" + handle : null;

  const rankStr = (rank, total) =>
    rank ? `#${rank}${total ? " of " + total.toLocaleString() : ""}` : null;

  const lenses = [
    {
      label: "as a publisher",
      value: pub.totalSubscribers || 0,
      unit: (pub.totalSubscribers === 1 ? "subscriber" : "subscribers"),
      rank: rankStr(pub.rank, pub.totalOwners),
    },
    {
      label: "as a curator",
      value: cur.totalRecommends || 0,
      unit: (cur.totalRecommends === 1 ? "recommend" : "recommends"),
      rank: rankStr(cur.rank, cur.totalCurators),
    },
    {
      label: "as a reader",
      value: rdr.subscriptionCount || 0,
      unit: (rdr.subscriptionCount === 1 ? "subscription" : "subscriptions"),
      rank: null,
    },
  ];

  const lensCard = (l) => ({
    type: "div",
    props: {
      style: {
        display: "flex",
        flexDirection: "column",
        flex: "1",
        gap: "8px",
        padding: "28px 26px",
        background: "#0d0d0d",
        border: "1px solid #1d1d1d",
        borderRadius: "14px",
      },
      children: [
        {
          type: "div",
          props: {
            style: { color: "#888", fontSize: "20px", textTransform: "uppercase", letterSpacing: "1px" },
            children: l.label,
          },
        },
        {
          type: "div",
          props: {
            style: { color: accent, fontSize: "58px", lineHeight: "1", fontVariantNumeric: "tabular-nums" },
            children: l.value.toLocaleString(),
          },
        },
        {
          type: "div",
          props: { style: { color: "#aaa", fontSize: "22px" }, children: l.unit },
        },
        {
          type: "div",
          props: {
            style: { color: l.rank ? "#666" : "#0d0d0d", fontSize: "18px", marginTop: "2px" },
            children: l.rank || "·",
          },
        },
      ],
    },
  });

  const headerChildren = [
    {
      type: "div",
      props: {
        style: { display: "flex", alignItems: "center", gap: "10px", color: "#888", fontSize: "24px" },
        children: [
          "pub search",
          { type: "span", props: { style: { color: "#444" }, children: "/" } },
          { type: "span", props: { style: { color: "#555" }, children: "wrapped" } },
        ],
      },
    },
    {
      type: "div",
      props: {
        style: { color: "#fff", fontSize: "48px", lineHeight: "1.05", letterSpacing: "-0.5px" },
        children: truncate(headline, 30),
      },
    },
  ];
  if (subhandle) {
    headerChildren.push({
      type: "div",
      props: { style: { color: accent, fontSize: "24px" }, children: truncate(subhandle, 36) },
    });
  }
  headerChildren.push({
    type: "div",
    props: { style: { color: "#666", fontSize: "22px", marginTop: "2px" }, children: "their long-form atmosphere" },
  });

  return {
    type: "div",
    props: {
      style: {
        display: "flex",
        flexDirection: "column",
        width: "1200px",
        height: "630px",
        background: "#050505",
        padding: "52px 56px",
        fontFamily: '"JetBrains Mono", monospace',
        justifyContent: "space-between",
      },
      children: [
        {
          type: "div",
          props: { style: { display: "flex", flexDirection: "column", gap: "8px" }, children: headerChildren },
        },
        {
          type: "div",
          props: { style: { display: "flex", gap: "20px" }, children: lenses.map(lensCard) },
        },
        {
          type: "div",
          props: {
            style: { color: "#444", fontSize: "18px" },
            children: "what you publish, who reads it, and what you recommend · pub-search.waow.tech/wrapped",
          },
        },
      ],
    },
  };
}

// generic, identity-free card for the bare /wrapped route.
function buildWrappedIntroImage() {
  const accent = "#2a9d5c";
  return {
    type: "div",
    props: {
      style: {
        display: "flex",
        flexDirection: "column",
        width: "1200px",
        height: "630px",
        background: "#050505",
        padding: "0 80px",
        fontFamily: '"JetBrains Mono", monospace',
        justifyContent: "center",
        gap: "24px",
      },
      children: [
        {
          type: "div",
          props: {
            style: { display: "flex", alignItems: "center", gap: "10px", color: "#888", fontSize: "26px" },
            children: [
              "pub search",
              { type: "span", props: { style: { color: "#444" }, children: "/" } },
              { type: "span", props: { style: { color: "#555" }, children: "wrapped" } },
            ],
          },
        },
        {
          type: "div",
          props: {
            style: { color: "#fff", fontSize: "76px", lineHeight: "1.05", letterSpacing: "-1px" },
            children: "your long-form atmosphere",
          },
        },
        {
          type: "div",
          props: {
            style: { color: "#aaa", fontSize: "30px", lineHeight: "1.4", maxWidth: "900px" },
            children: "what you publish, who reads it, your semantic neighborhoods, and what you recommend.",
          },
        },
        {
          type: "div",
          props: { style: { color: accent, fontSize: "24px", marginTop: "8px" }, children: "pub-search.waow.tech/wrapped" },
        },
      ],
    },
  };
}

export async function onRequest(context) {
  const url = new URL(context.request.url);
  const page = url.searchParams.get("page");
  const q = url.searchParams.get("q");
  const tag = url.searchParams.get("tag");
  const platform = url.searchParams.get("platform");
  const since = url.searchParams.get("since");
  const mode = url.searchParams.get("mode");

  // atlas page
  if (page === "atlas") {
    const stats = await fetchStats();
    const html = buildConstellationImage(stats ? stats.documents : null);
    return new ImageResponse(html, {
      width: 1200,
      height: 630,
      fonts: [
        {
          name: "JetBrains Mono",
          data: await loadGoogleFont("JetBrains Mono"),
          style: "normal",
        },
      ],
      headers: {
        "Cache-Control": "public, max-age=3600",
      },
    });
  }

  // wrapped — one identity's standing (or a generic intro for the bare route)
  if (page === "wrapped") {
    const actor = url.searchParams.get("did") || url.searchParams.get("handle");
    if (!actor) {
      const html = buildWrappedIntroImage();
      return new ImageResponse(html, {
        width: 1200,
        height: 630,
        fonts: [{ name: "JetBrains Mono", data: await loadGoogleFont("JetBrains Mono"), style: "normal" }],
        headers: { "Cache-Control": "public, max-age=3600" },
      });
    }
    const [data, profile] = await Promise.all([fetchWrapped(actor), resolveProfile(actor)]);
    const html = data ? buildWrappedImage(data, profile) : buildWrappedIntroImage();
    return new ImageResponse(html, {
      width: 1200,
      height: 630,
      fonts: [{ name: "JetBrains Mono", data: await loadGoogleFont("JetBrains Mono"), style: "normal" }],
      headers: { "Cache-Control": "public, max-age=1800" },
    });
  }

  // curators leaderboard page
  if (page === "curators") {
    const since = url.searchParams.get("since");
    const rows = await fetchCurators(since);
    // resolve handles for the rows that will actually render on the card
    // so the leaderboard shows @handles instead of raw DID stems.
    const topDids = (rows || []).slice(0, 6).map((r) => r.did).filter(Boolean);
    const handles = await resolveHandles(topDids);
    const html = buildCuratorsImage(rows, since, handles);
    return new ImageResponse(html, {
      width: 1200,
      height: 630,
      fonts: [{ name: "JetBrains Mono", data: await loadGoogleFont("JetBrains Mono"), style: "normal" }],
      headers: { "Cache-Control": "public, max-age=1800" },
    });
  }

  // recommended leaderboard page
  if (page === "recommended") {
    const since = url.searchParams.get("since");
    const sort = url.searchParams.get("sort");
    const author = url.searchParams.get("author");
    const curator = url.searchParams.get("curator");
    // resolve handle for the actor in the header (curator wins over author,
    // matching backend precedence) in parallel with the leaderboard fetch.
    const actor = curator || author;
    const [rows, handle] = await Promise.all([
      fetchRecommended(since, sort, author, curator),
      actor ? resolveHandle(actor) : Promise.resolve(null),
    ]);
    const html = buildRecommendedImage(rows, { since, sort, author, curator, handle });
    return new ImageResponse(html, {
      width: 1200,
      height: 630,
      fonts: [
        {
          name: "JetBrains Mono",
          data: await loadGoogleFont("JetBrains Mono"),
          style: "normal",
        },
      ],
      headers: {
        "Cache-Control": "public, max-age=1800",
      },
    });
  }

  // subscribed leaderboard page
  if (page === "subscribed") {
    const since = url.searchParams.get("since");
    const view = url.searchParams.get("view");
    const rows = await fetchSubscribed(view, since);
    // people view shows @handles — resolve the rows that will render
    let handleMap = new Map();
    if (view === "people") {
      const dids = (rows || []).slice(0, 6).map((r) => r.did).filter(Boolean);
      handleMap = await resolveHandles(dids);
    }
    const html = buildSubscribedImage(rows, { view, since, handleMap });
    return new ImageResponse(html, {
      width: 1200,
      height: 630,
      fonts: [{ name: "JetBrains Mono", data: await loadGoogleFont("JetBrains Mono"), style: "normal" }],
      headers: { "Cache-Control": "public, max-age=1800" },
    });
  }

  const hasParams = q || tag || platform || since;

  // build chips
  const chips = [];
  if (tag) chips.push(buildChip(`#${tag}`, "tag"));
  if (platform) chips.push(buildChip(platform, "platform"));
  if (since) {
    const label = labelFromSince(since);
    if (label) chips.push(buildChip(label, "date"));
  }
  if (mode && mode !== "keyword") chips.push(buildChip(mode, "mode"));

  let titles = [];
  let total = 0;
  let docCount = null;

  if (hasParams) {
    const data = await fetchSearchResults({ q, tag, platform, since, mode });
    if (data) {
      titles = data.results.map((r) => truncate(r.title || "untitled", 55));
      total = data.total;
    }
  } else {
    // homepage — show stats
    const stats = await fetchStats();
    if (stats) {
      docCount = stats.documents;
    }
  }

  // build the image JSX-like structure for workers-og
  const children = [];

  // header
  children.push({
    type: "div",
    props: {
      style: {
        color: "#888",
        fontSize: "28px",
        fontFamily: '"JetBrains Mono", monospace',
        marginBottom: "8px",
      },
      children: "pub search",
    },
  });

  if (hasParams) {
    // query
    if (q) {
      children.push({
        type: "div",
        props: {
          style: {
            color: "#fff",
            fontSize: "42px",
            fontFamily: '"JetBrains Mono", monospace',
            marginTop: "16px",
          },
          children: `"${truncate(stripQuotes(q), 45)}"`,
        },
      });
    }

    // chips row
    if (chips.length > 0) {
      children.push({
        type: "div",
        props: {
          style: {
            display: "flex",
            gap: "12px",
            marginTop: "20px",
          },
          children: chips.map((c) => c),
        },
      });
    }

    // divider
    children.push({
      type: "div",
      props: {
        style: {
          width: "100%",
          height: "1px",
          background: "#333",
          marginTop: "28px",
          marginBottom: "12px",
        },
        children: "",
      },
    });

    // result titles
    for (const title of titles) {
      children.push({
        type: "div",
        props: {
          style: {
            color: "#888",
            fontSize: "24px",
            fontFamily: '"JetBrains Mono", monospace',
            marginBottom: "8px",
            overflow: "hidden",
          },
          children: title,
        },
      });
    }

    if (titles.length === 0) {
      children.push({
        type: "div",
        props: {
          style: {
            color: "#555",
            fontSize: "24px",
            fontFamily: '"JetBrains Mono", monospace',
          },
          children: "no results",
        },
      });
    }

    // footer
    const footerParts = [];
    if (total > 0) footerParts.push(`${total} result${total === 1 ? "" : "s"}`);
    footerParts.push("search atproto publishing platforms");

    children.push({
      type: "div",
      props: {
        style: {
          color: "#555",
          fontSize: "20px",
          fontFamily: '"JetBrains Mono", monospace',
          marginTop: "auto",
        },
        children: footerParts.join(" · "),
      },
    });
  } else {
    // homepage image
    children.push({
      type: "div",
      props: {
        style: {
          color: "#555",
          fontSize: "24px",
          fontFamily: '"JetBrains Mono", monospace',
          marginTop: "24px",
        },
        children: "search atproto publishing platforms",
      },
    });

    // platform list
    const platforms = [
      "leaflet",
      "pckt",
      "offprint",
      "greengale",
      "whitewind",
    ];
    children.push({
      type: "div",
      props: {
        style: {
          display: "flex",
          gap: "12px",
          marginTop: "24px",
        },
        children: platforms.map((p) => buildChip(p, "platform")),
      },
    });

    if (docCount) {
      children.push({
        type: "div",
        props: {
          style: {
            color: "#555",
            fontSize: "20px",
            fontFamily: '"JetBrains Mono", monospace',
            marginTop: "auto",
          },
          children: `${docCount.toLocaleString()} documents indexed`,
        },
      });
    }
  }

  const html = {
    type: "div",
    props: {
      style: {
        display: "flex",
        flexDirection: "column",
        width: "1200px",
        height: "630px",
        background: "#0a0a0a",
        padding: "48px 56px",
        fontFamily: '"JetBrains Mono", monospace',
      },
      children,
    },
  };

  return new ImageResponse(html, {
    width: 1200,
    height: 630,
    fonts: [
      {
        name: "JetBrains Mono",
        data: await loadGoogleFont("JetBrains Mono"),
        style: "normal",
      },
    ],
    headers: {
      "Cache-Control": "public, max-age=3600",
    },
  });
}

async function loadGoogleFont(font) {
  const url = `https://fonts.googleapis.com/css2?family=${encodeURIComponent(font)}`;
  const css = await (
    await fetch(url, {
      headers: {
        "User-Agent":
          "Mozilla/5.0 (Macintosh; U; Intel Mac OS X 10_6_8; de-at) AppleWebKit/533.21.1 (KHTML, like Gecko) Version/5.0.5 Safari/533.21.1",
      },
    })
  ).text();

  const match = css.match(/src: url\((.+)\) format\('(opentype|truetype)'\)/);
  if (!match) {
    throw new Error(`Failed to load font: ${font}`);
  }

  return await (await fetch(match[1])).arrayBuffer();
}
