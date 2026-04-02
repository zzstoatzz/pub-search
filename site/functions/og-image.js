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

// platform colors for constellation OG image (core colors from the canvas)
const PLATFORM_DOTS = [
  { color: "#4ade80", label: "leaflet" },
  { color: "#60a5fa", label: "whitewind" },
  { color: "#fbbf24", label: "pckt" },
  { color: "#fb7185", label: "offprint" },
  { color: "#2dd4bf", label: "greengale" },
  { color: "#9ca3af", label: "other" },
];

// deterministic "random" positions for constellation dots
function constellationDots() {
  const dots = [];
  const positions = [
    [180, 200], [340, 150], [520, 280], [700, 180], [850, 250],
    [240, 350], [450, 180], [620, 340], [780, 300], [950, 200],
    [300, 260], [500, 400], [680, 220], [400, 320], [560, 160],
    [820, 380], [200, 420], [730, 400], [900, 340], [380, 220],
    [150, 300], [480, 250], [650, 380], [770, 160], [920, 420],
  ];
  for (let i = 0; i < positions.length; i++) {
    const platform = PLATFORM_DOTS[i % PLATFORM_DOTS.length];
    const size = 4 + (i % 3) * 2;
    const opacity = 0.4 + (i % 4) * 0.15;
    dots.push({
      type: "div",
      props: {
        style: {
          position: "absolute",
          left: `${positions[i][0]}px`,
          top: `${positions[i][1]}px`,
          width: `${size}px`,
          height: `${size}px`,
          borderRadius: "50%",
          background: platform.color,
          opacity: opacity,
        },
        children: "",
      },
    });
  }
  return dots;
}

function buildConstellationImage(docCount) {
  const children = [];

  // scattered dots as background decoration
  children.push(...constellationDots());

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

  // title
  children.push({
    type: "div",
    props: {
      style: {
        color: "#fff",
        fontSize: "48px",
        fontFamily: '"JetBrains Mono", monospace',
        marginTop: "16px",
      },
      children: "constellation",
    },
  });

  // subtitle
  children.push({
    type: "div",
    props: {
      style: {
        color: "#555",
        fontSize: "24px",
        fontFamily: '"JetBrains Mono", monospace',
        marginTop: "12px",
      },
      children: "2d semantic map of the document index",
    },
  });

  // platform legend
  children.push({
    type: "div",
    props: {
      style: {
        display: "flex",
        gap: "16px",
        marginTop: "32px",
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
                },
                children: "",
              },
            },
            {
              type: "div",
              props: {
                style: {
                  color: "#666",
                  fontSize: "18px",
                  fontFamily: '"JetBrains Mono", monospace',
                },
                children: p.label,
              },
            },
          ],
        },
      })),
    },
  });

  // footer
  const footerText = docCount
    ? `${docCount.toLocaleString()} documents · explore the index`
    : "explore the index";
  children.push({
    type: "div",
    props: {
      style: {
        color: "#555",
        fontSize: "20px",
        fontFamily: '"JetBrains Mono", monospace',
        marginTop: "auto",
      },
      children: footerText,
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
      },
      children,
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

  // constellation page
  if (page === "constellation") {
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
