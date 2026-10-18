import assert from 'node:assert/strict';
const { chromium, webkit } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const url = process.argv[2];
if (!url) throw new Error('Pass the stats URL; the page must have a working API.');
for (const engine of [chromium, webkit]) {
  const browser = await engine.launch();
  const page = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(url);
  const bars = page.locator('.timeline-bar');
  await bars.first().waitFor();
  const selected = page.locator('.timeline-bar[aria-pressed=true]');
  const detail = page.locator('.timeline-detail');
  const inspect = async index => {
    await bars.nth(index).scrollIntoViewIfNeeded();
    const box = await bars.nth(index).boundingBox();
    await page.touchscreen.tap(box.x + box.width / 2, box.y + box.height / 2);
    const actual = await bars.evaluateAll(nodes => nodes.findIndex(node => node.getAttribute('aria-pressed') === 'true'));
    assert.ok(Math.abs(actual - index) <= (box.width < 2 ? 1 : 0));
    const label = await selected.getAttribute('aria-label');
    assert.ok(label.includes((await detail.locator('strong').innerText()).replace(' indexed', ' documents indexed').replace(' created', ' documents created')));
  };
  const previousDay = page.getByRole('button', { name: 'Previous day' });
  await previousDay.scrollIntoViewIfNeeded();
  const scale = await page.evaluate(() => visualViewport.scale);
  const count = await bars.count();
  await previousDay.tap();
  await previousDay.tap();
  assert.equal(await bars.nth(count - 3).getAttribute('aria-pressed'), 'true');
  assert.equal(await page.evaluate(() => visualViewport.scale), scale);
  assert.equal(await previousDay.evaluate(node => getComputedStyle(node).touchAction), 'manipulation');
  assert.equal(await selected.evaluate(node => getComputedStyle(node).outlineStyle), 'none');
  for (const field of ['indexed', 'created']) {
    await page.locator(`#timeline-field [data-field=${field}]`).tap();
    await bars.first().waitFor();
    for (const range of ['7d', '30d', '90d', '1y', 'all']) {
      const response = page.waitForResponse(response => response.url().includes('/api/timeline?') && response.url().includes(`range=${range}&field=${field}`));
      await page.locator(`#timeline-range [data-range="${range}"]`).tap();
      const data = await (await response).json();
      await bars.first().waitFor();
      assert.equal(await page.locator('#timeline-range [aria-pressed=true]').getAttribute('data-range'), range);
      const labels = await bars.evaluateAll(nodes => nodes.map(node => node.getAttribute('aria-label')));
      for (const point of data.points) assert.ok(labels.some(label => label.includes(`: ${point.count.toLocaleString()} documents ${field}`)));
      const total = data.points.reduce((sum, point) => sum + point.count, 0);
      assert.ok((await page.locator('.timeline-summary').innerText()).startsWith(total.toLocaleString() + ' documents'));
      await inspect(Math.floor(await bars.count() / 2));
      const middle = await selected.getAttribute('aria-label');
      await page.getByRole('button', { name: /^Previous / }).tap();
      assert.notEqual(await selected.getAttribute('aria-label'), middle);
      await page.getByRole('button', { name: /^Next / }).tap();
      assert.equal(await selected.getAttribute('aria-label'), middle);
      await selected.focus();
      await page.keyboard.press('Home');
      assert.equal(await bars.first().getAttribute('aria-pressed'), 'true');
      await page.keyboard.press('ArrowRight');
      assert.equal(await bars.nth(1).getAttribute('aria-pressed'), 'true');
      await page.keyboard.press('End');
      assert.equal(await bars.last().getAttribute('aria-pressed'), 'true');
      assert.ok(await page.getByRole('button', { name: /^Next / }).isDisabled());
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    }
  }
  for (const width of [320, 390, 1280]) {
    await page.setViewportSize({ width, height: 844 });
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  }
  await page.evaluate(async () => {
    await Promise.all([loadTimeline('90d', 'indexed'), loadTimeline('7d', 'created')]);
  });
  assert.equal(await page.locator('#timeline-field [aria-pressed=true]').getAttribute('data-field'), 'created');
  assert.ok((await page.locator('.timeline-summary').innerText()).includes('documents created'));
  await page.evaluate(() => renderTimeline([{ date: '2026-10-01', count: 4 }, { date: '2026-10-03', count: 8 }], 'daily'));
  assert.equal(await bars.count(), 3);
  await inspect(1);
  assert.equal(await detail.locator('strong').innerText(), '0 created');
  assert.equal(await bars.nth(1).locator('span').evaluate(node => node.getBoundingClientRect().height), 0);
  await page.evaluate(() => renderTimeline([], 'daily'));
  assert.equal(await page.locator('.timeline-status').innerText(), 'No documents in this range.');
  await page.evaluate(() => {
    for (const id of ['searches', 'publications', 'embeddings']) document.getElementById(id).textContent = '1,234,567,890';
    document.getElementById('embeddings-sub').textContent = '98.7% covered · 123,456,789 pending';
    document.getElementById('relay').textContent = 'a-very-long-relay-hostname.with-several-subdomains.example.org';
  });
  for (const width of [320, 390, 1280]) {
    await page.setViewportSize({ width, height: 844 });
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    assert.ok(await page.locator('.metrics .metric-value').evaluateAll(nodes => nodes.every(node => node.scrollWidth <= node.clientWidth)));
  }
  await page.context().setOffline(true);
  await page.locator('#timeline-range [data-range="7d"]').click();
  await page.getByRole('button', { name: 'Try again' }).waitFor();
  assert.equal(await bars.count(), 0);
  await page.context().setOffline(false);
  await page.getByRole('button', { name: 'Try again' }).click();
  await bars.first().waitFor();
  assert.deepEqual(errors, []);
  console.log(`${engine.name()}: live counts, ranges, touch, keyboard, resize, offline recovery passed`);
  await browser.close();
}
