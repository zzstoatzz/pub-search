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
          /* nodes never move, so every edge ends exactly on a node centre; the
             only motion is a signal travelling the path a -> b -> c -> d -> e -> c */
          line { stroke:currentColor; stroke-width:1; stroke-linecap:round; }
          .web line { opacity:.22; }
          .signal line { stroke-dasharray:1; stroke-dashoffset:1; opacity:0; animation:signal 3s linear infinite; animation-delay:calc(var(--i) * .4s); }
          circle { fill:var(--ink); filter:saturate(.6) brightness(.8); transform-box:fill-box; transform-origin:center; animation:node 3s ease-out infinite; animation-delay:calc(var(--i) * .4s); }
          :host([size=large]) { flex-direction:column; gap:24px; font-size:13px; text-align:center; }
          :host([size=large]) svg { width:144px; height:108px; }
          :host([size=large]) line { stroke-width:.5; }
          @keyframes signal { 0% {stroke-dashoffset:1;opacity:.9} 13.3% {stroke-dashoffset:0;opacity:.9} 45% {stroke-dashoffset:0;opacity:.5} 70%,100% {stroke-dashoffset:0;opacity:0} }
          @keyframes node { 0% {transform:scale(1);filter:saturate(.6) brightness(.8)} 5% {transform:scale(1.45);filter:saturate(1.2) brightness(1.15)} 45% {transform:scale(1);filter:saturate(1) brightness(1)} 70%,100% {transform:scale(1);filter:saturate(.6) brightness(.8)} }
          @media(prefers-reduced-motion:reduce) { .signal line,circle {animation:none} .web line {opacity:.4} circle {filter:none} }
        </style>
        <svg viewBox="0 0 64 48" aria-hidden="true">
          <g class="web"><line x1="8" y1="30" x2="22" y2="11"/><line x1="22" y1="11" x2="35" y2="31"/><line x1="35" y1="31" x2="54" y2="15"/><line x1="54" y1="15" x2="49" y2="40"/><line x1="49" y1="40" x2="35" y2="31"/></g>
          <g class="signal"><line pathLength="1" style="--i:0" x1="8" y1="30" x2="22" y2="11"/><line pathLength="1" style="--i:1" x1="22" y1="11" x2="35" y2="31"/><line pathLength="1" style="--i:2" x1="35" y1="31" x2="54" y2="15"/><line pathLength="1" style="--i:3" x1="54" y1="15" x2="49" y2="40"/><line pathLength="1" style="--i:4" x1="49" y1="40" x2="35" y2="31"/></g>
          <circle style="--i:0;--ink:#89bfc7" cx="8" cy="30" r="3"/>
          <circle style="--i:1;--ink:#c0a779" cx="22" cy="11" r="3.6"/>
          <circle style="--i:2;--ink:#a99ac4" cx="35" cy="31" r="4.2"/>
          <circle style="--i:3;--ink:#86af9c" cx="54" cy="15" r="3.2"/>
          <circle style="--i:4;--ink:#89bfc7" cx="49" cy="40" r="2.4"/>
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
