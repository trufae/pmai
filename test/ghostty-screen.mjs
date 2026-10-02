// Headless Ghostty adapter for repl-reflow-smoke.py. No browser or app UI.
import { readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const packagePath = resolve(process.argv[2]);
const { Ghostty } = await import(pathToFileURL(resolve(packagePath, 'dist/ghostty-web.js')));
const wasm = readFileSync(resolve(packagePath, 'ghostty-vt.wasm'));
const ghostty = await Ghostty.load(`data:application/wasm;base64,${wasm.toString('base64')}`);
const terminal = ghostty.createTerminal(160, 40, { scrollbackLimit: 10000 });
const lineText = cells => cells.map(cell =>
  cell.codepoint ? String.fromCodePoint(cell.codepoint) : ' ').join('').trimEnd();
const isStatus = cells => cells.some(cell =>
  cell.bg_r === 18 && cell.bg_g === 52 && cell.bg_b === 86);

for await (const line of createInterface({ input: process.stdin })) {
  const event = JSON.parse(line);
  if (event.write) terminal.write(Buffer.from(event.write, 'base64'));
  if (event.resize) terminal.resize(...event.resize);
  terminal.update();
  const screen = Array.from({ length: terminal.rows }, (_, i) => terminal.getLine(i));
  const history = Array.from({ length: terminal.getScrollbackLength() },
    (_, i) => terminal.getScrollbackLine(i));
  console.log(JSON.stringify({
    screen: screen.map(lineText),
    history: history.map(lineText),
    statusRows: screen.flatMap((cells, i) => isStatus(cells) ? [i] : []),
    statusHistory: history.flatMap((cells, i) => isStatus(cells) ? [i] : []),
    wraps: terminal.getMode(7),
  }));
}
terminal.free();
