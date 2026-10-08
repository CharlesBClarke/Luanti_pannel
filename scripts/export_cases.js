// Generates random panel libraries (same generator as the prototype's fuzz.js),
// runs the prototype's reference simulator on them, and prints the cases as a
// Lua table for tests/crosscheck.lua.
// Usage: node scripts/export_cases.js <path/to/engine.js> [seed] [trials] [ticks]
const path = require('path');
const { makeEngine, compileStatic, isInner, N } = require(path.resolve(process.argv[2]));
let seed = +(process.argv[3] || 5);
const trials = +(process.argv[4] || 10), ticks = +(process.argv[5] || 100);
const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
const KIND = { dust: 'dust', block: 'block', bulb: 'bulb', lamp: 'lamp', quartz: 'quartz' };

const cellLua = c => c.t === 'torch' ? `{kind="torch",attach=${c.a}}`
  : c.t === 'inst' ? `{kind="panel",id=${c.d},speed=${c.s}}` : `{kind="${KIND[c.t]}"}`;
const bits = a => a.map(v => (v ? 1 : 0)).join('');

const out = ['return {'];
for (let trial = 0; trial < trials; trial++) {
  const F = makeEngine();
  for (let k = 0; k < 5; k++) {
    const c = new Array(N * N).fill(null);
    for (let i = 0; i < N * N; i++) {
      if (!isInner(i)) continue;
      const r = rnd();
      if (r < 0.28) c[i] = { t: 'dust' }; else if (r < 0.38) c[i] = { t: 'block' };
      else if (r < 0.44) c[i] = { t: 'bulb' }; else if (r < 0.48) c[i] = { t: 'lamp' };
      else if (r < 0.54) c[i] = { t: 'quartz' };
      else if (r < 0.66) c[i] = { t: 'torch', a: Math.floor(rnd() * 4) };
      else if (r < 0.71 && k > 0) c[i] = { t: 'inst', d: Math.floor(rnd() * k), s: [1, 1, 1, 2, 3][Math.floor(rnd() * 5)] };
    }
    F.lib.push({ name: 'p' + k, cells: c });
  }
  out.push(` { trial=${trial}, library={`);
  F.lib.forEach((p, k) => {
    const cs = p.cells.map((c, i) => c ? `[${i}]=${cellLua(c)}` : null).filter(Boolean).join(',');
    out.push(`  [${k}]={cells={${cs}}},`);
  });
  out.push(' }, runs={');
  for (let k = 0; k < 5; k++) {
    const pins = compileStatic(F.lib[k].cells).inPins;
    const A = F.makeRefRI(k);
    let inB = new Array(32).fill(0);
    const toggles = [], expect = [];
    for (let t = 0; t < ticks; t++) {
      let tog = -1;
      if (rnd() < 0.25 && pins.length) { tog = pins[Math.floor(rnd() * pins.length)]; inB[tog] ^= 1; }
      toggles.push(tog);
      const o = F.stepRI(A, inB);
      F.evalRI(A, inB);
      expect.push(`"${bits(o)}|${bits(F.lampsOf(A))}"`);
    }
    out.push(`  {id=${k}, toggles={${toggles.join(',')}}, expect={${expect.join(',')}}},`);
  }
  out.push(' }},');
}
out.push('}');
console.log(out.join('\n'));
