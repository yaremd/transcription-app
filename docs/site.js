/* sealformac.com — the page's own behaviour. No dependencies, no network requests.
   Progressive: without this file every element is visible in its finished state.
   Motion plays once and rests; nothing loops; reduced motion gets the finished frames. */
(() => {
  const root = document.documentElement;
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const canObserve = 'IntersectionObserver' in window;
  const motion = !reduce && canObserve;
  root.classList.add('js');
  if (motion) root.classList.add('motion');

  /* Sound waves: a curve from the edge into the seal, with a sine wobble that settles. */
  function wavePath(x0, y0, cx, cy, x1, y1, amp, cycles, phase) {
    const N = 180; let d = '';
    for (let i = 0; i <= N; i++) {
      const t = i / N, u = 1 - t;
      const x = u * u * x0 + 2 * u * t * cx + t * t * x1;
      const y = u * u * y0 + 2 * u * t * cy + t * t * y1;
      const dx = 2 * u * (cx - x0) + 2 * t * (x1 - cx);
      const dy = 2 * u * (cy - y0) + 2 * t * (y1 - cy);
      const len = Math.hypot(dx, dy) || 1;
      const env = Math.sin(Math.PI * Math.min(1, t * 1.08)) * (1 - 0.5 * t);
      const off = amp * env * Math.sin(t * cycles * 2 * Math.PI + phase);
      d += (i ? 'L' : 'M') + (x - (dy / len) * off).toFixed(1) + ' ' + (y + (dx / len) * off).toFixed(1);
    }
    return d;
  }
  document.querySelectorAll('svg.waves path[data-wave]').forEach((p) => {
    p.setAttribute('d', wavePath(...p.dataset.wave.trim().split(/\s+/).map(Number)));
    try { p.style.setProperty('--len', Math.ceil(p.getTotalLength())); } catch (e) { p.style.setProperty('--len', 2000); }
  });

  /* Arriving from the app's old "pricing" link opens the answer to "Is Seal really free?". */
  const openTarget = () => {
    const el = location.hash && document.getElementById(location.hash.slice(1));
    if (el && el.tagName === 'DETAILS') el.open = true;
  };
  openTarget();
  window.addEventListener('hashchange', openTarget);

  /* The Wi-Fi test: switch it off and the transcript keeps arriving, because nothing needed the network. */
  document.querySelectorAll('[data-wifi]').forEach((box) => {
    const btn = box.querySelector('[data-wifi-toggle]'), label = box.querySelector('[data-wifi-label]');
    const lines = box.querySelector('[data-wifi-lines]'), state = box.querySelector('[data-wifi-state]');
    const script = [['Marcus', 'And for sales, could you share how other teams set up the follow-up?'], ['You', "I'll send two examples right after this call."], ['Dana', "Perfect. That's everything from our side."], ['You', 'Thanks both. The notes will be ready when we hang up.']];
    let i = 0, timer = null;
    const add = () => {
      if (i >= script.length) { clearInterval(timer); timer = null; state.textContent = 'Wi-Fi off · transcript and notes still on this Mac'; return; }
      const [who, text] = script[i++];
      const row = document.createElement('div'); row.className = 'ln new';
      const w = document.createElement('span'); w.className = 'who' + (who === 'You' ? ' you' : ''); w.textContent = who;
      const t = document.createElement('span'); t.textContent = text;
      row.append(w, t); lines.appendChild(row);
      while (lines.children.length > 5) lines.removeChild(lines.firstElementChild);
    };
    btn.addEventListener('click', () => {
      const off = btn.getAttribute('aria-pressed') !== 'true';
      btn.setAttribute('aria-pressed', String(off));
      label.textContent = off ? 'Wi-Fi off' : 'Wi-Fi on';
      if (off) { state.textContent = 'Wi-Fi off · still transcribing'; if (!timer && i < script.length) { add(); timer = setInterval(add, 1600); } }
      else { state.textContent = 'Connected · nothing is being sent'; }
    });
  });

  if (!canObserve) return;

  /* The timeline rail fills as you read: --p goes 0→1 as its section passes the middle of the screen. */
  const rails = [...document.querySelectorAll('[data-progress]')];
  if (rails.length) {
    let ticking = false;
    const update = () => {
      ticking = false;
      const mid = window.innerHeight * 0.5;
      rails.forEach((r) => {
        const box = r.getBoundingClientRect();
        r.style.setProperty('--p', Math.min(1, Math.max(0, (mid - box.top) / Math.max(1, box.height))).toFixed(4));
      });
    };
    window.addEventListener('scroll', () => { if (!ticking) { ticking = true; requestAnimationFrame(update); } }, { passive: true });
    window.addEventListener('resize', update);
    update();
  }

  if (!motion) return;

  /* Reveal on scroll, once. */
  const revealer = new IntersectionObserver((entries) => {
    entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('is-in'); revealer.unobserve(e.target); } });
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.12 });
  document.querySelectorAll('[data-reveal]').forEach((el) => revealer.observe(el));

  /* Rings, waves and the wax stamp play when they come into view. */
  document.querySelectorAll('.stamp[data-stamp]').forEach((s) => s.classList.add('armed'));
  const player = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (!e.isIntersecting) return;
      const el = e.target;
      if (el.classList.contains('stamp')) { el.classList.remove('armed'); el.classList.add('pressed'); }
      else el.classList.add('play');
      player.unobserve(el);
    });
  }, { threshold: 0.35 });
  document.querySelectorAll('.rings, .waves, .stamp[data-stamp]').forEach((el) => player.observe(el));
})();
