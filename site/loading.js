/**
 * loading.js - portable loading state handler for dashboards
 *
 * handles cold-start backends gracefully:
 * - immediate: shows skeleton shimmer
 * - after threshold: shows "waking up" message
 * - on success: reveals content smoothly
 *
 * usage:
 *   const loader = createLoader({
 *     container: '#my-dashboard',
 *     wakeThreshold: 2000,  // ms before showing "waking up"
 *     onWake: () => {},     // optional callback when wake message shows
 *   });
 *
 *   loader.start();
 *   await fetchData();
 *   loader.done();
 */

function createLoader(opts = {}) {
  const threshold = opts.wakeThreshold || 2000;
  const onWake = opts.onWake || null;

  let wakeTimer = null;
  let wakeEl = null;
  let startTime = 0;

  function start() {
    startTime = Date.now();

    // add loading class to body for global styling hooks
    document.body.classList.add('loading');

    // schedule wake message
    wakeTimer = setTimeout(() => {
      showWakeMessage();
      if (onWake) onWake();
    }, threshold);
  }

  function showWakeMessage() {
    if (wakeEl) return;

    wakeEl = document.createElement('div');
    wakeEl.className = 'wake-message';
    wakeEl.innerHTML = '<span class="wake-dot"></span> waking up...';

    // insert at top of container or body
    const container = opts.container
      ? document.querySelector(opts.container)
      : document.body;

    if (container && container.firstChild) {
      container.insertBefore(wakeEl, container.firstChild);
    } else if (container) {
      container.appendChild(wakeEl);
    }
  }

  function done() {
    if (wakeTimer) clearTimeout(wakeTimer);

    document.body.classList.remove('loading');
    document.body.classList.add('loaded');

    if (wakeEl) {
      wakeEl.classList.add('fade-out');
      setTimeout(() => wakeEl.remove(), 300);
    }

    return Date.now() - startTime;
  }

  return { start, done };
}

// css injected once
(function injectStyles() {
  if (document.getElementById('loader-styles')) return;

  const style = document.createElement('style');
  style.id = 'loader-styles';
  style.textContent = `
    /* skeleton shimmer for loading values */
    .loading .metric-value,
    .loading .doc-count,
    .loading .pub-count {
      background: linear-gradient(90deg, #1a1a1a 25%, #252525 50%, #1a1a1a 75%);
      background-size: 200% 100%;
      animation: shimmer 1.5s infinite;
      border-radius: 3px;
      color: transparent !important;
      min-width: 3ch;
      display: inline-block;
    }

    @keyframes shimmer {
      0% { background-position: 200% 0; }
      100% { background-position: -200% 0; }
    }

    /* wake message */
    .wake-message {
      position: fixed;
      top: 1rem;
      right: 1rem;
      font-size: 11px;
      color: #666;
      background: #111;
      border: 1px solid #222;
      padding: 6px 12px;
      border-radius: 4px;
      display: flex;
      align-items: center;
      gap: 8px;
      z-index: 1000;
      animation: fade-in 0.2s ease;
    }

    .wake-dot {
      width: 6px;
      height: 6px;
      background: #4ade80;
      border-radius: 50%;
      animation: pulse-dot 1s infinite;
    }

    @keyframes pulse-dot {
      0%, 100% { opacity: 0.3; }
      50% { opacity: 1; }
    }

    @keyframes fade-in {
      from { opacity: 0; transform: translateY(-4px); }
      to { opacity: 1; transform: translateY(0); }
    }

    .wake-message.fade-out {
      animation: fade-out 0.3s ease forwards;
    }

    @keyframes fade-out {
      to { opacity: 0; transform: translateY(-4px); }
    }

    /* loaded transition */
    .loaded .metric-value,
    .loaded .doc-count,
    .loaded .pub-count {
      animation: reveal 0.3s ease;
    }

    @keyframes reveal {
      from { opacity: 0; }
      to { opacity: 1; }
    }
  `;
  document.head.appendChild(style);
})();
