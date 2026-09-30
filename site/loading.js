(function() {
  if(customElements.get('pub-loading')) return;
  class PubLoading extends HTMLElement {
    connectedCallback() {
      if(this.shadowRoot) return;
      this.setAttribute('role','status');
      this.setAttribute('aria-live','polite');
      this.attachShadow({mode:'open'}).innerHTML=`
        <style>
          :host { display:inline-flex; align-items:center; gap:10px; color:inherit; font:inherit; vertical-align:middle; }
          svg { width:48px; height:36px; flex:none; overflow:visible; color:var(--text-secondary,#999); }
          .thread { fill:none; stroke:currentColor; stroke-width:.7; opacity:.3; stroke-dasharray:90; animation:thread 4s ease-in-out infinite; }
          .page { fill:var(--bg,#111); stroke:var(--ink,#89bfc7); stroke-width:1.5; transform-box:fill-box; transform-origin:center; animation:page 4s cubic-bezier(.45,0,.25,1) infinite; }
          .b { --ink:#c0a779; animation-delay:-.8s; }
          .c { --ink:#a99ac4; animation-delay:-1.6s; }
          .d { --ink:#86af9c; animation-delay:-2.4s; }
          .e { --ink:#89bfc7; animation-delay:-3.2s; }
          :host([size=large]) { flex-direction:column; gap:24px; font-size:13px; text-align:center; }
          :host([size=large]) svg { width:144px; height:108px; }
          @keyframes page { 0%,100% {transform:translateY(0) rotate(-8deg);rx:1} 35% {transform:translateY(-5px) rotate(12deg);rx:1} 65% {transform:translateY(2px) rotate(82deg);rx:4} }
          @keyframes thread {0%,100% {stroke-dashoffset:90;opacity:.15} 45%,65% {stroke-dashoffset:0;opacity:.45} }
          @media(prefers-reduced-motion:reduce) { .page,.thread {animation:none} }
        </style>
        <svg viewBox="0 0 64 48" aria-hidden="true">
          <path class="thread" d="M9 30L23 12L35 34L53 17L9 30M35 34L53 17"/>
          <rect class="page a" x="5" y="25" width="7" height="9" rx="1"/>
          <rect class="page b" x="19" y="7" width="7" height="9" rx="1"/>
          <rect class="page c" x="31" y="29" width="7" height="9" rx="1"/>
          <rect class="page d" x="49" y="12" width="7" height="9" rx="1"/>
          <rect class="page e" x="46" y="37" width="5" height="6" rx="1"/>
        </svg><span><slot>Loading…</slot></span>`;
    }
  }
  customElements.define('pub-loading',PubLoading);
})();

function createLoader(opts={}) {
  var element, started;
  return {
    start() {
      started=Date.now();
      if(element) element.remove();
      element=document.createElement('pub-loading');
      element.textContent='Gathering the latest…';
      element.style.cssText='display:flex;margin:16px 0;color:var(--text-muted,#999)';
      (document.querySelector(opts.container)||document.body).prepend(element);
    },
    done() { if(element) element.remove(); return Date.now()-started; }
  };
}
