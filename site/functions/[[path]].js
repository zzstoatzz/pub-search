// dynamic OG tags for link previews
const DATE_PRESET_LABELS = { week: 'last week', month: 'last month', year: 'last year' };

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

function buildTitle(params) {
  const parts = [];

  if (params.q) parts.push(`"${params.q}"`);
  if (params.tag) parts.push(`#${params.tag}`);

  let suffix = '';
  const modifiers = [];
  if (params.platform) modifiers.push(`on ${params.platform}`);
  if (params.since) {
    const preset = presetFromSince(params.since);
    const label = preset ? DATE_PRESET_LABELS[preset] : params.since;
    modifiers.push(label);
  }
  if (modifiers.length > 0) suffix = ` ${modifiers.join(', ')}`;

  if (parts.length === 0 && suffix) {
    return `search${suffix} - pub search`;
  }
  if (parts.length === 0) return null; // no params, skip rewrite

  return `${parts.join(' in ')}${suffix} - pub search`;
}

function buildDescription(params) {
  const parts = [];

  if (params.q) parts.push(`search results for "${params.q}"`);
  else if (params.tag) parts.push(`documents tagged #${params.tag}`);
  else parts.push('search results');

  if (params.platform) parts.push(`on ${params.platform}`);
  if (params.since) {
    const preset = presetFromSince(params.since);
    const label = preset ? DATE_PRESET_LABELS[preset] : params.since;
    parts.push(label);
  }

  return parts.join(', ');
}

function escapeAttr(str) {
  return str
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

export async function onRequest(context) {
  const url = new URL(context.request.url);
  const q = url.searchParams.get('q');
  const tag = url.searchParams.get('tag');
  const platform = url.searchParams.get('platform');
  const since = url.searchParams.get('since');
  const mode = url.searchParams.get('mode');

  // if no search params, pass through (static tags in index.html are fine)
  if (!q && !tag && !platform && !since) {
    return context.next();
  }

  const title = buildTitle({ q, tag, platform, since });
  const description = buildDescription({ q, tag, platform, since });

  // build og:image URL with same search params
  const ogImageUrl = new URL('/og-image', url.origin);
  if (q) ogImageUrl.searchParams.set('q', q);
  if (tag) ogImageUrl.searchParams.set('tag', tag);
  if (platform) ogImageUrl.searchParams.set('platform', platform);
  if (since) ogImageUrl.searchParams.set('since', since);
  if (mode) ogImageUrl.searchParams.set('mode', mode);

  const ogUrl = url.toString();

  const response = await context.next();

  return new HTMLRewriter()
    // remove existing OG/twitter meta tags
    .on('meta[property^="og:"]', { element(el) { el.remove(); } })
    .on('meta[name^="twitter:"]', { element(el) { el.remove(); } })
    // update <title>
    .on('title', {
      element(el) {
        if (title) el.setInnerContent(escapeAttr(title), { html: true });
      }
    })
    // update description meta
    .on('meta[name="description"]', {
      element(el) {
        el.setAttribute('content', description);
      }
    })
    // inject new OG tags before </head>
    .on('head', {
      element(el) {
        el.append(`
    <meta property="og:title" content="${escapeAttr(title || 'pub search')}" />
    <meta property="og:description" content="${escapeAttr(description)}" />
    <meta property="og:url" content="${escapeAttr(ogUrl)}" />
    <meta property="og:type" content="website" />
    <meta property="og:site_name" content="pub search" />
    <meta property="og:image" content="${escapeAttr(ogImageUrl.toString())}" />
    <meta property="og:image:width" content="1200" />
    <meta property="og:image:height" content="630" />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content="${escapeAttr(title || 'pub search')}" />
    <meta name="twitter:description" content="${escapeAttr(description)}" />
    <meta name="twitter:image" content="${escapeAttr(ogImageUrl.toString())}" />
`, { html: true });
      }
    })
    .transform(response);
}
