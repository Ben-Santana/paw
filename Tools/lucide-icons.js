// Converts lucide-react icon nodes into SVG path data for Swift.
const fs = require('fs'), path = require('path');
const [dir, out] = process.argv.slice(2);
const names = 'arrow-left arrow-right arrow-up arrow-down rotate-3d move-3d house briefcase code-xml music gamepad-2 camera pen-tool globe star heart monitor headphones earth layers app-window list bell clipboard-copy vibrate hourglass plus chevron-right chevron-down check x clock-3 workflow hand ellipsis play trash-2 pencil circle circle-dot spline copy dumbbell layout-grid skip-forward rotate-ccw square settings audio-waveform calendar-days book-open search timer flame trending-up activity chevron-left chevron-up qr-code share minus info terminal keyboard chart-line presentation graduation-cap message-circle mail mic video tv palette plane car bike footprints coffee moon sun leaf paw-print rocket chef-hat pause link clipboard-paste bell-ring list-checks ear'.split(' ');
const n = v => +v;
function toPath(tag, a) {
  switch (tag) {
    case 'path': return a.d;
    case 'line': return `M${a.x1} ${a.y1}L${a.x2} ${a.y2}`;
    case 'polyline': case 'polygon': { const p = a.points.trim().split(/[\s,]+/); let d = `M${p[0]} ${p[1]}`; for (let i = 2; i < p.length; i += 2) d += `L${p[i]} ${p[i+1]}`; return tag === 'polygon' ? d + 'Z' : d; }
    case 'circle': { const cx = n(a.cx), cy = n(a.cy), r = n(a.r); return `M${cx - r} ${cy}A${r} ${r} 0 1 0 ${cx + r} ${cy}A${r} ${r} 0 1 0 ${cx - r} ${cy}Z`; }
    case 'ellipse': { const cx = n(a.cx), cy = n(a.cy), rx = n(a.rx), ry = n(a.ry); return `M${cx - rx} ${cy}A${rx} ${ry} 0 1 0 ${cx + rx} ${cy}A${rx} ${ry} 0 1 0 ${cx - rx} ${cy}Z`; }
    case 'rect': { const x = n(a.x||0), y = n(a.y||0), w = n(a.width), h = n(a.height); let r = n(a.rx ?? a.ry ?? 0); r = Math.min(r, w/2, h/2);
      if (!r) return `M${x} ${y}H${x+w}V${y+h}H${x}Z`;
      return `M${x+r} ${y}H${x+w-r}A${r} ${r} 0 0 1 ${x+w} ${y+r}V${y+h-r}A${r} ${r} 0 0 1 ${x+w-r} ${y+h}H${x+r}A${r} ${r} 0 0 1 ${x} ${y+h-r}V${y+r}A${r} ${r} 0 0 1 ${x+r} ${y}Z`; }
    default: throw new Error('Unsupported ' + tag);
  }
}
const camel = s => s.replace(/-(\w)/g, (_, c) => c.toUpperCase()).replace(/^(\d)/, '_$1');
let swift = '// Generated from lucide-react 0.468.0 (ISC License), the icon set the Mac app uses.\n// Each icon is SVG path data in a 24×24 box, stroked at 1.5 with round caps and joins.\n// Regenerate with: node Tools/lucide-icons.js <mac app>/node_modules/lucide-react/dist/esm/icons Shared/LucideData.swift\n\nenum LucideData {\n';
for (const name of names) {
  const src = fs.readFileSync(path.join(dir, name + '.js'), 'utf8');
  const literal = src.slice(src.indexOf('[', src.indexOf('createLucideIcon(')), src.lastIndexOf(']') + 1);
  const nodes = Function('return ' + literal)();
  const paths = nodes.map(([tag, attrs]) => toPath(tag, attrs));
  swift += `    static let ${camel(name)} = [${paths.map(p => JSON.stringify(p)).join(', ')}]\n`;
}
fs.writeFileSync(out, swift + '}\n');
console.log('wrote', names.length, 'icons');
