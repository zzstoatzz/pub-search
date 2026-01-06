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
    /* skeleton shimmer - subtle pulse */
    .loading .metric-value,
    .loading .doc-count,
    .loading .pub-count {
      color: #333 !important;
      animation: dim-pulse 2s ease-in-out infinite;
    }

    @keyframes dim-pulse {
      0%, 100% { opacity: 0.3; }
      50% { opacity: 0.6; }
    }

    /* wake message - terminal style, ephemeral */
    .wake-message {
      position: fixed;
      bottom: 1rem;
      left: 1rem;
      font-family: monospace;
      font-size: 11px;
      color: #444;
      z-index: 1000;
      animation: fade-in 0.5s ease;
    }

    .wake-message::before {
      content: '>';
      margin-right: 6px;
      opacity: 0.5;
    }

    .wake-dot {
      display: inline-block;
      width: 4px;
      height: 4px;
      background: #555;
      border-radius: 50%;
      margin-left: 4px;
      animation: blink 1s step-end infinite;
    }

    @keyframes blink {
      0%, 100% { opacity: 1; }
      50% { opacity: 0; }
    }

    @keyframes fade-in {
      from { opacity: 0; }
      to { opacity: 1; }
    }

    .wake-message.fade-out {
      animation: fade-out 0.5s ease forwards;
    }

    @keyframes fade-out {
      to { opacity: 0; }
    }

    /* loaded transition */
    .loaded .metric-value,
    .loaded .doc-count,
    .loaded .pub-count {
      animation: none;
    }
  `;
  document.head.appendChild(style);
})();
