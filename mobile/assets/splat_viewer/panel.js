// The panel of the page, in the app's language and colours (the texts and the theme come from the session): the
// bar with Back, the name and the count, Walk or Turn around, Reset, Turn upright, the gyroscope on phones, the
// details and the help; the lines that fade after a few seconds (FreeKC's rule); loading, the info sheet, the stick
// under the left thumb and the refusals.

const ICONS = {
  back: 'M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z',
  reset: 'M12 5V1L7 6l5 5V7c3.31 0 6 2.69 6 6s-2.69 6-6 6-6-2.69-6-6H4c0 4.42 3.58 8 8 8s8-3.58 8-8-3.58-8-8-8z',
  // A turn of 90 degrees (Material's rotate_90_degrees_ccw): the upload arrow it had read as "Upload" on a phone
  upright: 'M7.34,6.41L0.86,12.9L7.35,19.38L13.84,12.9L7.34,6.41M3.69,12.9L7.35,9.24L11,12.9L7.34,16.56L3.69,12.9M19.36,6.64C17.61,4.88 15.3,4 13,4V0.76L8.76,5L13,9.24V6C14.79,6 16.58,6.68 17.95,8.05C20.68,10.78 20.68,15.22 17.95,17.95C16.58,19.32 14.79,20 13,20C12.03,20 11.06,19.79 10.16,19.39L8.67,20.88C10,21.62 11.5,22 13,22C15.3,22 17.61,21.12 19.36,19.36C22.88,15.85 22.88,10.15 19.36,6.64Z',
  walk: 'M13.5 5.5c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zM9.8 8.9 7 23h2.1l1.8-8 2.1 2v6h2v-7.5l-2.1-2 .6-3C14.8 12 16.8 13 19 13v-2c-1.9 0-3.5-1-4.3-2.4l-1-1.6c-.4-.6-1-1-1.7-1-.3 0-.5.1-.8.1L6 8.3V13h2V9.6l1.8-.7',
  orbit: 'M12 6c-3.87 0-7 2.69-7 6h2c0-2.21 2.24-4 5-4v3l4-4-4-4v3zm7 6c0 2.21-2.24 4-5 4v-3l-4 4 4 4v-3c3.87 0 7-2.69 7-6h-2z',
  gyroscope: 'M17 1H7c-1.1 0-2 .9-2 2v18c0 1.1.9 2 2 2h10c1.1 0 2-.9 2-2V3c0-1.1-.9-2-2-2zm0 18H7V5h10v14z',
  info: 'M11 7h2v2h-2zm0 4h2v6h-2zm1-9C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8z',
  help: 'M11 18h2v-2h-2v2zm1-16C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm0-14c-2.21 0-4 1.79-4 4h2c0-1.1.9-2 2-2s2 .9 2 2c0 2-3 1.75-3 5h2c0-2.25 3-2.5 3-5 0-2.21-1.79-4-4-4z',
};

const SVG_NS = 'http://www.w3.org/2000/svg';

function icon(name) {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS(SVG_NS, 'path');
  path.setAttribute('d', ICONS[name]);
  svg.appendChild(path);
  return svg;
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) {
    node.className = className;
  }
  if (text != null) {
    node.textContent = text;
  }
  return node;
}

function button(name, label, onClick, withLabel = false) {
  const node = element('button', `tool tool-${name}`);
  node.type = 'button';
  node.title = label;
  node.setAttribute('aria-label', label);
  node.appendChild(icon(name));
  if (withLabel) {
    node.appendChild(element('span', 'tool-label', label));
  }
  node.addEventListener('click', (event) => {
    event.stopPropagation();
    onClick();
  });
  return node;
}

/** The panel of [session] in [root]; [actions] are back, reset, upright, mode, gyroscope, info, help */
export function createPanel(root, session, actions) {
  const t = session.texts;
  document.documentElement.lang = session.locale;
  document.documentElement.classList.toggle('light', session.theme.dark === false);
  if (session.theme.primary) {
    document.documentElement.style.setProperty('--primary', session.theme.primary);
  }
  document.title = session.scene.name;

  const bar = element('header', 'bar');
  bar.appendChild(button('back', t.back ?? 'Back', actions.back));
  const titles = element('div', 'titles');
  titles.appendChild(element('div', 'title', session.scene.name));
  const count = element('div', 'subtitle', t.countLine ?? '');
  titles.appendChild(count);
  if (session.scene.reduced && t.reducedLine) {
    titles.appendChild(element('div', 'subtitle', t.reducedLine));
  }
  bar.appendChild(titles);
  const tools = element('div', 'tools');
  const mode = button('walk', t.modeWalk ?? 'Walk', actions.mode, true);
  tools.appendChild(mode);
  tools.appendChild(button('reset', t.reset ?? 'Reset', actions.reset));
  tools.appendChild(button('upright', t.upright ?? 'Turn upright', actions.upright));
  let gyro = null;
  if (session.gyroscope) {
    gyro = button('gyroscope', t.gyroscope ?? 'Gyroscope', actions.gyroscope);
    tools.appendChild(gyro);
  }
  tools.appendChild(button('info', t.info ?? 'Info', actions.info));
  tools.appendChild(button('help', t.helpLabel ?? 'Help', actions.help));
  bar.appendChild(tools);
  root.appendChild(bar);

  const line = element('div', 'line');
  line.setAttribute('role', 'status');
  root.appendChild(line);

  const sheet = element('div', 'sheet hidden');
  root.appendChild(sheet);

  const stickBase = element('div', 'stick hidden');
  const stickKnob = element('div', 'knob');
  stickBase.appendChild(stickKnob);
  root.appendChild(stickBase);

  const loading = element('div', 'loading hidden');
  const loadingText = element('div', 'loading-text', t.loading ?? '');
  const bar2 = element('div', 'progress');
  const fill = element('div', 'progress-fill');
  bar2.appendChild(fill);
  loading.appendChild(loadingText);
  loading.appendChild(bar2);
  root.appendChild(loading);

  let lineTimer = null;
  let barTimer = null;
  let barShown = true;

  const panel = {
    /** [text] at the bottom, faded after [seconds] */
    say(text, seconds = 5) {
      if (!text) {
        return;
      }
      clearTimeout(lineTimer);
      line.textContent = text;
      line.classList.add('shown');
      lineTimer = setTimeout(() => line.classList.remove('shown'), seconds * 1000);
    },
    setMode(walk) {
      const label = walk ? t.modeWalk ?? 'Walk' : t.modeOrbit ?? 'Turn around';
      mode.replaceChildren(icon(walk ? 'walk' : 'orbit'), element('span', 'tool-label', label));
      mode.title = label;
      mode.setAttribute('aria-label', label);
    },
    setGyroscope(on) {
      gyro?.classList.toggle('on', on);
    },
    setCount(text) {
      count.textContent = text;
    },
    showLoading(share) {
      loading.classList.remove('hidden');
      fill.style.width = `${Math.round(Math.min(1, Math.max(0, share)) * 100)}%`;
    },
    hideLoading() {
      loading.classList.add('hidden');
    },
    /** A refusal or a failure that ends the viewing: the text and Back */
    showError(text) {
      loading.classList.add('hidden');
      sheet.replaceChildren(element('p', 'error', text));
      const back = element('button', 'sheet-button', t.back ?? 'Back');
      back.type = 'button';
      back.addEventListener('click', actions.back);
      sheet.appendChild(back);
      sheet.classList.remove('hidden');
      panel.showBar(true);
    },
    /** The info sheet or the help, [lines] of text; closed by a second press, Esc or a tap */
    toggleSheet(lines) {
      if (!sheet.classList.contains('hidden')) {
        sheet.classList.add('hidden');
        return false;
      }
      sheet.replaceChildren(...lines.filter(Boolean).map((text) => element('p', null, text)));
      sheet.classList.remove('hidden');
      return true;
    },
    hideSheet() {
      const shown = !sheet.classList.contains('hidden');
      sheet.classList.add('hidden');
      return shown;
    },
    /** Shows or hides the bar; on a computer it comes back with the mouse and fades after 3 s of rest */
    showBar(shown) {
      barShown = shown;
      bar.classList.toggle('hidden', !shown);
    },
    toggleBar() {
      panel.showBar(!barShown);
    },
    wake() {
      panel.showBar(true);
      clearTimeout(barTimer);
      barTimer = setTimeout(() => {
        if (sheet.classList.contains('hidden')) {
          panel.showBar(false);
        }
      }, 3000);
    },
    stick(state) {
      if (!state) {
        stickBase.classList.add('hidden');
        return;
      }
      stickBase.classList.remove('hidden');
      stickBase.style.left = `${state.cx}px`;
      stickBase.style.top = `${state.cy}px`;
      stickKnob.style.transform = `translate(${state.x * 100}%, ${state.y * 100}%)`;
    },
  };
  return panel;
}
