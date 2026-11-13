/* Seal · Sealed Glass — shared behaviour. No dependencies.
   Everything here is progressive: without JS (or with reduced motion) every element is
   already visible in its finished state. Motion plays once and rests; nothing loops. */
(() => {
  const root = document.documentElement;
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const canObserve = 'IntersectionObserver' in window;
  const motion = !reduce && canObserve;
  root.classList.add('js');
  if (motion) root.classList.add('motion');

  /* ---- sound waves: a curve from the edge into the seal, with a sine wobble that settles ---- */
  const NS = 'http://www.w3.org/2000/svg';
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
    const v = p.dataset.wave.trim().split(/\s+/).map(Number);
    p.setAttribute('d', wavePath(...v));
    try { p.style.setProperty('--len', Math.ceil(p.getTotalLength())); } catch (e) { p.style.setProperty('--len', 2000); }
  });

  if (!canObserve) return;

  /* ---- scroll stories and rails work with or without motion; only their transitions are motion ---- */
  setupStories();
  setupRails();
  if (!motion) return;

  /* ---- reveal on scroll (once) ---- */
  const revealer = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (!e.isIntersecting) return;
      e.target.classList.add('is-in');
      revealer.unobserve(e.target);
    });
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.12 });
  document.querySelectorAll('[data-reveal]').forEach((el) => revealer.observe(el));

  /* ---- things that play when they come into view: rings, waves, stamps ---- */
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
  document.querySelectorAll('.rings, .waves, .stamp[data-stamp], [data-play]').forEach((el) => player.observe(el));

  /* ---- scroll stories: the step crossing the middle of the screen picks the panel ---- */
  function setupStories() { document.querySelectorAll('[data-story]').forEach((story) => {
    const steps = [...story.querySelectorAll('[data-step]')];
    const panels = [...story.querySelectorAll('[data-panel]')];
    const set = (i) => {
      story.dataset.active = i;
      panels.forEach((p) => p.classList.toggle('is-active', p.dataset.panel === String(i)));
      steps.forEach((s) => s.classList.toggle('is-active', s.dataset.step === String(i)));
    };
    set(steps[0] ? steps[0].dataset.step : 0);
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => { if (e.isIntersecting) set(e.target.dataset.step); });
    }, { rootMargin: '-48% 0px -48% 0px', threshold: 0 });
    steps.forEach((s) => io.observe(s));
  }); }

  /* ---- progress rails: --p goes 0→1 as the rail's section scrolls past the middle ---- */
  function setupRails() { const rails = [...document.querySelectorAll('[data-progress]')];
  if (rails.length) {
    let ticking = false;
    const update = () => {
      ticking = false;
      const mid = window.innerHeight * 0.5;
      rails.forEach((r) => {
        const box = r.getBoundingClientRect();
        const p = Math.min(1, Math.max(0, (mid - box.top) / Math.max(1, box.height)));
        r.style.setProperty('--p', p.toFixed(4));
      });
    };
    window.addEventListener('scroll', () => { if (!ticking) { ticking = true; requestAnimationFrame(update); } }, { passive: true });
    window.addEventListener('resize', update);
    update();
  } }
})();

/* ---- the update-email form is a prototype here: it never sends ---- */
document.querySelectorAll('form[data-prototype]').forEach((f) => {
  f.addEventListener('submit', (e) => {
    e.preventDefault();
    const out = f.parentElement.querySelector('[data-form-note]');
    if (out) out.textContent = 'Prototype: nothing was sent. On the live site this signs you up for release emails.';
  });
});
