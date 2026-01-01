export async function onRequest(context) {
  const url = new URL(context.request.url);
  const query = url.searchParams.get('q');

  // if no query param, just serve the static file
  if (!query) {
    return context.next();
  }

  // fetch the original HTML
  const response = await context.next();
  let html = await response.text();

  // build OG meta tags
  const title = `"${query}" - leaflet search`;
  const description = `search results for "${query}" on leaflet`;
  const ogUrl = url.toString();

  // remove existing OG tags
  html = html.replace(/<meta property="og:[^"]*"[^>]*>/g, '');
  html = html.replace(/<meta name="twitter:[^"]*"[^>]*>/g, '');

  const ogTags = `
    <meta property="og:title" content="${escapeHtml(title)}" />
    <meta property="og:description" content="${escapeHtml(description)}" />
    <meta property="og:url" content="${escapeHtml(ogUrl)}" />
    <meta property="og:type" content="website" />
    <meta name="twitter:card" content="summary" />
    <meta name="twitter:title" content="${escapeHtml(title)}" />
    <meta name="twitter:description" content="${escapeHtml(description)}" />
  `;

  // inject OG tags into <head>
  const modifiedHtml = html.replace('</head>', `${ogTags}</head>`);

  return new Response(modifiedHtml, {
    headers: {
      'content-type': 'text/html;charset=UTF-8',
    },
  });
}

function escapeHtml(str) {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
