// dynamic OG tags for link previews
//
// Two pages get dynamic rewriting: `/` (search results) and `/recommended`
// (leaderboard variants). Other paths pass through to the static meta tags
// already in the HTML.
//
// The rewriting only kicks in when there are interesting URL params — sharing
// the bare `/` or bare `/recommended` keeps the static (cached) OG image so
// scrapers don't all stampede our backend for the same defaults.

const DATE_PRESET_LABELS = { week: 'last week', month: 'last month', year: 'last year' };
const WINDOW_LABELS = {
  day: 'today',
  week: 'this week',
  month: 'this month',
  year: 'this year',
};

function presetFromSince(since) {
  if (!since) return null;
  const now = new Date();
  const d = new Date(since);
  const days = Math.round((now - d) / (1000 * 60 * 60 * 24));
  if (days <= 8) return 'week';
  if (days <= 32) return 'month';
  if (days <= 370) return 'year';
  return null;
}

function stripQuotes(s) {
  return s.replace(/^"+|"+$/g, '');
}

function escapeAttr(str) {
  return str
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function shortDid(did) {
  const parts = String(did).split(':');
  const last = parts[parts.length - 1] || did;
  return last.length > 10 ? last.slice(0, 10) + '…' : last;
}

// ---------- homepage (search results) ----------

function buildHomeTitle(params) {
  const parts = [];
  if (params.q) parts.push(`"${stripQuotes(params.q)}"`);
  if (params.tag) parts.push(`#${params.tag}`);
  let suffix = '';
  const modifiers = [];
  if (params.author) modifiers.push(`by ${params.author}`);
  if (params.platform) modifiers.push(`on ${params.platform}`);
  if (params.since) {
    const preset = presetFromSince(params.since);
    const label = preset ? DATE_PRESET_LABELS[preset] : params.since;
    modifiers.push(label);
  }
  if (modifiers.length > 0) suffix = ` ${modifiers.join(', ')}`;
  if (parts.length === 0 && suffix) return `search${suffix} - pub search`;
  if (parts.length === 0) return null;
  return `${parts.join(' in ')}${suffix} - pub search`;
}

function buildHomeDescription(params) {
  const parts = [];
  if (params.q) parts.push(`search results for "${stripQuotes(params.q)}"`);
  else if (params.tag) parts.push(`documents tagged #${params.tag}`);
  else parts.push('search results');
  if (params.author) parts.push(`by ${params.author}`);
  if (params.platform) parts.push(`on ${params.platform}`);
  if (params.since) {
    const preset = presetFromSince(params.since);
    const label = preset ? DATE_PRESET_LABELS[preset] : params.since;
    parts.push(label);
  }
  return parts.join(', ');
}

async function handleHome(context, url) {
  const q = url.searchParams.get('q');
  const tag = url.searchParams.get('tag');
  const platform = url.searchParams.get('platform');
  const since = url.searchParams.get('since');
  const author = url.searchParams.get('author');
  const mode = url.searchParams.get('mode');

  if (!q && !tag && !platform && !since && !author) return context.next();

  const title = buildHomeTitle({ q, tag, platform, since, author });
  const description = buildHomeDescription({ q, tag, platform, since, author });

  const ogImageUrl = new URL('/og-image', url.origin);
  if (q) ogImageUrl.searchParams.set('q', q);
  if (tag) ogImageUrl.searchParams.set('tag', tag);
  if (platform) ogImageUrl.searchParams.set('platform', platform);
  if (since) ogImageUrl.searchParams.set('since', since);
  if (author) ogImageUrl.searchParams.set('author', author);
  if (mode) ogImageUrl.searchParams.set('mode', mode);

  const response = await context.next();
  return rewriteMeta(response, { title, description, ogUrl: url.toString(), ogImageUrl: ogImageUrl.toString() });
}

// ---------- /recommended (leaderboard) ----------

function actorLabel(actor) {
  if (actor.startsWith('did:')) return '@' + shortDid(actor);
  return actor.startsWith('@') ? actor : '@' + actor;
}

// Title for the meta tag. The og-image worker also derives its own header
// from the same params; we keep them aligned so the card preview and the
// scrape-time title tell the same story.
function buildRecommendedTitle(params) {
  const { since, sort, view, author, curator } = params;
  const isCurators = view === 'curators';

  let head;
  if (isCurators) {
    head = 'top curators';
  } else if (curator) {
    head = `posts recommended by ${actorLabel(curator)}`;
  } else if (author) {
    head = `${actorLabel(author)}'s ${sort === 'trending' ? 'trending posts' : 'most-recommended posts'}`;
  } else {
    head = sort === 'trending' ? 'trending posts' : 'most-recommended posts';
  }

  const win = since && since !== 'all' ? WINDOW_LABELS[since] || since : null;
  return `${head}${win ? ' ' + win : ''} · pub search`;
}

function buildRecommendedDescription(params) {
  const { since, sort, view, author, curator } = params;
  const isCurators = view === 'curators';

  let head;
  if (isCurators) {
    head = 'people who have recommended the most posts on atproto publishing platforms';
  } else if (curator) {
    head = `posts recommended by ${actorLabel(curator)} on atproto publishing platforms`;
  } else if (author) {
    head = sort === 'trending'
      ? `posts by ${actorLabel(author)} ranked by recent recommend velocity`
      : `most-recommended posts by ${actorLabel(author)}`;
  } else if (sort === 'trending') {
    head = 'posts gaining recommends fastest across atproto publishing platforms';
  } else {
    head = 'most-recommended posts across atproto publishing platforms';
  }

  const win = since && since !== 'all' ? WINDOW_LABELS[since] || since : null;
  return `${head}${win ? ' (' + win + ')' : ''}`;
}

async function handleRecommended(context, url) {
  const since = url.searchParams.get('since');
  const sort = url.searchParams.get('sort');
  const view = url.searchParams.get('view');
  const author = url.searchParams.get('author');
  const curator = url.searchParams.get('curator');

  // bare /recommended → static OG is fine (and likely already cached upstream).
  if (!since && !sort && !view && !author && !curator) return context.next();

  const title = buildRecommendedTitle({ since, sort, view, author, curator });
  const description = buildRecommendedDescription({ since, sort, view, author, curator });

  // og-image accepts page=curators OR page=recommended; the other params
  // (sort, since, author, curator) are honored by the worker for tailored cards.
  const isCurators = view === 'curators';
  const ogImageUrl = new URL('/og-image', url.origin);
  ogImageUrl.searchParams.set('page', isCurators ? 'curators' : 'recommended');
  if (since && since !== 'all') ogImageUrl.searchParams.set('since', since);
  if (!isCurators) {
    if (sort && sort !== 'top') ogImageUrl.searchParams.set('sort', sort);
    // curator wins over author (matches backend precedence)
    if (curator) ogImageUrl.searchParams.set('curator', curator);
    else if (author) ogImageUrl.searchParams.set('author', author);
  }

  const response = await context.next();
  return rewriteMeta(response, { title, description, ogUrl: url.toString(), ogImageUrl: ogImageUrl.toString() });
}

// ---------- /subscribed (leaderboard) ----------

function buildSubscribedTitle(params) {
  const { since, view } = params;
  const head = view === 'people' ? 'most-subscribed people' : 'most-subscribed publications';
  const win = since && since !== 'all' ? WINDOW_LABELS[since] || since : null;
  return `${head}${win ? ' ' + win : ''} · pub search`;
}

function buildSubscribedDescription(params) {
  const { since, view } = params;
  const head = view === 'people'
    ? 'people with the most subscribers across atproto publishing platforms'
    : 'most-subscribed publications across atproto publishing platforms';
  const win = since && since !== 'all' ? WINDOW_LABELS[since] || since : null;
  return `${head}${win ? ' (' + win + ')' : ''}`;
}

async function handleSubscribed(context, url) {
  const since = url.searchParams.get('since');
  const view = url.searchParams.get('view');

  // bare /subscribed → static OG is fine (and likely already cached upstream).
  if (!since && !view) return context.next();

  const title = buildSubscribedTitle({ since, view });
  const description = buildSubscribedDescription({ since, view });

  const ogImageUrl = new URL('/og-image', url.origin);
  ogImageUrl.searchParams.set('page', 'subscribed');
  if (view === 'people') ogImageUrl.searchParams.set('view', 'people');
  if (since && since !== 'all') ogImageUrl.searchParams.set('since', since);

  const response = await context.next();
  return rewriteMeta(response, { title, description, ogUrl: url.toString(), ogImageUrl: ogImageUrl.toString() });
}

// ---------- /wrapped (one identity's standing) ----------

async function resolveHandleForMeta(did) {
  if (!did) return null;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 1200);
  try {
    const res = await fetch(
      `https://typeahead.waow.tech/xrpc/app.bsky.actor.getProfiles?actors=${encodeURIComponent(did)}`,
      { signal: controller.signal },
    );
    clearTimeout(timeout);
    if (!res.ok) return null;
    const d = await res.json();
    const p = d && Array.isArray(d.profiles) ? d.profiles[0] : null;
    return p && p.handle ? p.handle : null;
  } catch {
    clearTimeout(timeout);
    return null;
  }
}

async function handleWrapped(context, url) {
  const did = url.searchParams.get('did');
  const handle = url.searchParams.get('handle');
  const actor = did || handle;

  // bare /wrapped → static OG (branded intro card) is fine.
  if (!actor) return context.next();

  // prefer a real @handle in the title; fall back to the DID stem if lookup fails.
  let resolved = handle ? handle.replace(/^@/, '') : await resolveHandleForMeta(did);
  const label = resolved ? '@' + resolved : '@' + shortDid(did);
  const title = `${label}'s long-form atmosphere · pub search`;
  const description =
    `${label}'s standing across standard.site — what they publish, who reads it, and what they recommend`;

  const ogImageUrl = new URL('/og-image', url.origin);
  ogImageUrl.searchParams.set('page', 'wrapped');
  if (did) ogImageUrl.searchParams.set('did', did);
  else if (handle) ogImageUrl.searchParams.set('handle', handle);

  const response = await context.next();
  return rewriteMeta(response, { title, description, ogUrl: url.toString(), ogImageUrl: ogImageUrl.toString() });
}

// ---------- shared rewrite ----------

function rewriteMeta(response, { title, description, ogUrl, ogImageUrl }) {
  return new HTMLRewriter()
    .on('meta[property^="og:"]', { element(el) { el.remove(); } })
    .on('meta[name^="twitter:"]', { element(el) { el.remove(); } })
    .on('title', {
      element(el) {
        if (title) el.setInnerContent(escapeAttr(title), { html: true });
      },
    })
    .on('meta[name="description"]', {
      element(el) { el.setAttribute('content', description); },
    })
    .on('head', {
      element(el) {
        el.append(`
    <meta property="og:title" content="${escapeAttr(title || 'pub search')}" />
    <meta property="og:description" content="${escapeAttr(description)}" />
    <meta property="og:url" content="${escapeAttr(ogUrl)}" />
    <meta property="og:type" content="website" />
    <meta property="og:site_name" content="pub search" />
    <meta property="og:image" content="${escapeAttr(ogImageUrl)}" />
    <meta property="og:image:width" content="1200" />
    <meta property="og:image:height" content="630" />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content="${escapeAttr(title || 'pub search')}" />
    <meta name="twitter:description" content="${escapeAttr(description)}" />
    <meta name="twitter:image" content="${escapeAttr(ogImageUrl)}" />
`, { html: true });
      },
    })
    .transform(response);
}

// ---------- entry ----------

export async function onRequest(context) {
  const url = new URL(context.request.url);
  const path = url.pathname;

  if (path === '/' || path === '/index.html') {
    return handleHome(context, url);
  }
  if (path === '/recommended' || path === '/recommended.html' || path === '/recommended/') {
    return handleRecommended(context, url);
  }
  if (path === '/subscribed' || path === '/subscribed.html' || path === '/subscribed/') {
    return handleSubscribed(context, url);
  }
  if (path === '/wrapped' || path === '/wrapped.html' || path === '/wrapped/') {
    return handleWrapped(context, url);
  }
  return context.next();
}
