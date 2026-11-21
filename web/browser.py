"""Drive the user's running Firefox over WebDriver BiDi.

Firefox must be started with `--marionette --remote-debugging-port 9222` (see `firefox-bonsai`).
Pages are read as text with numbered interactive elements; clicks and typing are sent
as real input events, so sites treat them like the user's own.
"""
import atexit
import json
import socket
import time

from websockets.sync.client import connect

MARIONETTE_PORT = 2828  # BiDi runs on the --remote-debugging-port; Marionette reports its URL
PAGE_CHARS = 20000

# Walks the visible DOM and returns readable text where links, buttons and fields
# are tagged [n]. The numbers are stored as data-bonsai-id for later clicks.
SNAPSHOT_JS = r"""() => {
  document.querySelectorAll('[data-bonsai-id]').forEach(e => e.removeAttribute('data-bonsai-id'));
  const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','SVG','HEAD','IFRAME']);
  const BLOCK = /^(ADDRESS|ARTICLE|ASIDE|BLOCKQUOTE|DIV|DL|DT|DD|FIELDSET|FIGURE|FOOTER|FORM|H[1-6]|HEADER|HR|LI|MAIN|NAV|OL|P|PRE|SECTION|TABLE|TR|UL|BR)$/;
  const ROLES = new Set(['button','link','tab','menuitem','checkbox','radio','option','switch','combobox','textbox','searchbox']);
  let n = 0, out = [];
  const visible = e => {
    const s = getComputedStyle(e);
    if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') return false;
    const r = e.getBoundingClientRect();
    return r.width > 0 || r.height > 0 || s.display === 'contents';
  };
  const interactive = e => {
    const t = e.tagName;
    if (t === 'A' && e.hasAttribute('href')) return true;
    if (['BUTTON','SELECT','TEXTAREA','SUMMARY'].includes(t)) return true;
    if (t === 'INPUT' && e.type !== 'hidden') return true;
    if (ROLES.has(e.getAttribute('role'))) return true;
    return e.isContentEditable && !e.parentElement?.isContentEditable;
  };
  const label = e => {
    const t = e.tagName, type = (e.type || '').toLowerCase();
    let txt = (e.getAttribute('aria-label') || e.innerText || e.value || e.placeholder || e.title || e.alt || '').trim();
    if (!txt) { const img = e.querySelector('img[alt]'); if (img) txt = img.alt; }
    txt = txt.replace(/\s+/g, ' ').slice(0, 100);
    if (t === 'A') return `link "${txt}"`;
    if (t === 'INPUT' && ['checkbox','radio'].includes(type)) return `${type}${e.checked ? ' (checked)' : ''} "${txt || e.name}"`;
    if (t === 'INPUT' || t === 'TEXTAREA' || e.isContentEditable) {
      const ph = e.placeholder || e.getAttribute('aria-label') || e.name || '';
      const v = (e.value ?? e.innerText ?? '').slice(0, 80);
      return `${type === 'submit' || type === 'button' ? 'button' : 'text field'} "${ph}"${v && type !== 'password' ? ` value="${v}"` : ''}`;
    }
    if (t === 'SELECT') return `dropdown "${e.options[e.selectedIndex]?.text || ''}" options: ${[...e.options].map(o => o.text).slice(0, 15).join(' | ')}`;
    return `${e.getAttribute('role') || 'button'} "${txt}"`;
  };
  const walk = node => {
    if (node.nodeType === 3) { const t = node.textContent.replace(/\s+/g, ' '); if (t.trim()) out.push(t); return; }
    if (node.nodeType !== 1 || SKIP.has(node.tagName.toUpperCase()) || !visible(node)) return;
    const block = BLOCK.test(node.tagName);
    if (block) out.push('\n');
    if (interactive(node)) {
      node.setAttribute('data-bonsai-id', ++n);
      out.push(` [${n}] ${label(node)} `);
    } else {
      if (/^H[1-6]$/.test(node.tagName)) out.push('#'.repeat(+node.tagName[1]) + ' ');
      for (const c of node.childNodes) walk(c);
      if (node.shadowRoot) for (const c of node.shadowRoot.childNodes) walk(c);
    }
    if (block) out.push('\n');
  };
  walk(document.body);
  const text = out.join('').replace(/[ \t]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  const pct = Math.round(100 * scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight));
  return JSON.stringify({title: document.title, url: location.href, scroll: pct, text});
}"""


class Firefox:
    def __init__(self):
        self.ws = None
        self.mn = None
        self.next_id = 0
        self.tab = None  # browsing context the model is working in

    # --- protocol ---------------------------------------------------------------
    def _connect(self):
        # The session is opened over Marionette and held by that socket: if this process
        # dies, Firefox sees the socket close and ends the session. (A session made with
        # BiDi's session.new outlives its client and blocks new ones until Firefox restarts.)
        self.close()
        self.mn = socket.create_connection(("127.0.0.1", MARIONETTE_PORT), timeout=10)
        self.mn_buf = b""
        self._mn_read()  # hello
        # "ignore" keeps the session from auto-dismissing the user's own alerts and dialogs.
        caps = self._mn("WebDriver:NewSession", {"webSocketUrl": True, "unhandledPromptBehavior": "ignore"})
        self.ws = connect(caps["capabilities"]["webSocketUrl"], max_size=None, open_timeout=5)

    def _mn_read(self):
        # Marionette frames are "<length>:<json>"
        while b":" not in self.mn_buf:
            self.mn_buf += self.mn.recv(65536)
        n, rest = self.mn_buf.split(b":", 1)
        while len(rest) < int(n):
            rest += self.mn.recv(65536)
        self.mn_buf = rest[int(n):]
        return json.loads(rest[:int(n)])

    def _mn(self, name: str, params: dict):
        self.next_id += 1
        body = json.dumps([0, self.next_id, name, params]).encode()
        self.mn.sendall(str(len(body)).encode() + b":" + body)
        _, _, err, result = self._mn_read()
        if err:
            raise RuntimeError(f"{err.get('error')}: {err.get('message')}")
        return result

    def close(self):
        for conn in (self.ws, self.mn):
            try:
                conn and conn.close()
            except Exception:
                pass
        self.ws = self.mn = None

    def _send(self, method: str, params: dict):
        self.next_id += 1
        self.ws.send(json.dumps({"id": self.next_id, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv(timeout=60))
            if msg.get("id") != self.next_id:
                continue  # events
            if msg.get("type") == "error":
                raise RuntimeError(f"{msg.get('error')}: {msg.get('message')}")
            return msg["result"]

    def cmd(self, method: str, params: dict):
        if self.ws is None:
            self._connect()
        try:
            return self._send(method, params)
        except Exception as e:
            if "ConnectionClosed" not in type(e).__name__ and not isinstance(e, OSError):
                raise
            self._connect()  # Firefox restarted or the session dropped
            return self._send(method, params)

    def js(self, fn: str, *args, tab=None):
        res = self.cmd("script.callFunction", {
            "functionDeclaration": fn, "awaitPromise": True, "userActivation": True,
            "target": {"context": tab or self.current_tab()},
            "arguments": [{"type": "string", "value": str(a)} for a in args]})
        if res.get("type") == "exception":
            raise RuntimeError(res["exceptionDetails"].get("text", "script error"))
        return res["result"]

    # --- tabs -------------------------------------------------------------------
    def tabs(self) -> list[dict]:
        tree = self.cmd("browsingContext.getTree", {"maxDepth": 0})["contexts"]
        out = []
        for c in tree:
            try:
                state = self.js("() => document.visibilityState + '|' + document.title", tab=c["context"])["value"]
            except Exception:
                state = "hidden|"
            vis, title = state.split("|", 1)
            out.append({"id": c["context"], "url": c["url"], "title": title, "visible": vis == "visible"})
        return out

    def current_tab(self) -> str:
        if self.tab:
            ids = [c["context"] for c in self.cmd("browsingContext.getTree", {"maxDepth": 0})["contexts"]]
            if self.tab in ids:
                return self.tab
        tabs = self.tabs()
        if not tabs:
            raise RuntimeError("Firefox has no open tabs")
        self.tab = next((t["id"] for t in tabs if t["visible"]), tabs[0]["id"])
        return self.tab

    def element(self, n: int) -> dict:
        res = self.js("n => document.querySelector(`[data-bonsai-id=\"${n}\"]`)", n)
        if res.get("type") != "node":
            raise RuntimeError(f"No element [{n}] on the page. Read the page again to get fresh numbers.")
        return {"sharedId": res["sharedId"]}

    def settle(self):
        time.sleep(0.8)
        try:
            self.js("() => new Promise(r => document.readyState === 'complete' ? r() : addEventListener('load', r, {once: true}))")
        except Exception:
            pass


# --- tools exposed to the model -------------------------------------------------
ff = Firefox()
atexit.register(ff.close)


def browser_tabs() -> str:
    cur = ff.current_tab()
    return "\n".join(f"{i}. {'(current) ' if t['id'] == cur else ''}{t['title'] or '(untitled)'}\n   {t['url']}"
                     for i, t in enumerate(ff.tabs(), 1))


def browser_read() -> str:
    page = json.loads(ff.js(SNAPSHOT_JS)["value"])
    text = page["text"]
    more = f"\n\n[...page truncated at {PAGE_CHARS} chars; scroll down and read again for more]" if len(text) > PAGE_CHARS else ""
    return f"{page['title']}\n{page['url']}\n(scrolled {page['scroll']}%)\n\n{text[:PAGE_CHARS]}{more}"


def browser_open(url: str, new_tab: bool = False) -> str:
    if not url.startswith(("http://", "https://", "about:", "file:")):
        url = "https://" + url
    if new_tab:
        ff.tab = ff.cmd("browsingContext.create", {"type": "tab"})["context"]
    ff.cmd("browsingContext.navigate", {"context": ff.current_tab(), "url": url, "wait": "complete"})
    ff.cmd("browsingContext.activate", {"context": ff.tab})
    return browser_read()


def browser_click(element: int) -> str:
    el = ff.element(int(element))
    ff.js("n => document.querySelector(`[data-bonsai-id=\"${n}\"]`).scrollIntoView({block: 'center'})", element)
    ff.cmd("input.performActions", {"context": ff.current_tab(), "actions": [{
        "type": "pointer", "id": "mouse", "actions": [
            {"type": "pointerMove", "x": 0, "y": 0, "origin": {"type": "element", "element": el}},
            {"type": "pointerDown", "button": 0}, {"type": "pointerUp", "button": 0}]}]})
    ff.settle()
    return browser_read()


def browser_type(element: int, text: str, submit: bool = False) -> str:
    ff.element(int(element))
    # Focus and select existing content so typing replaces it.
    ff.js("""n => { const e = document.querySelector(`[data-bonsai-id="${n}"]`);
        e.scrollIntoView({block: 'center'}); e.focus();
        if (e.select) e.select(); else document.execCommand('selectAll'); }""", element)
    keys = []
    for ch in text + ("" if submit else ""):
        keys += [{"type": "keyDown", "value": ch}, {"type": "keyUp", "value": ch}]
    ff.cmd("input.performActions", {"context": ff.current_tab(), "actions": [{"type": "key", "id": "kbd", "actions": keys}]})
    ff.settle()
    return browser_read()


def browser_select(element: int, option: str) -> str:
    ff.element(int(element))
    ok = ff.js("""(n, opt) => { const e = document.querySelector(`[data-bonsai-id="${n}"]`);
        const o = [...e.options].find(o => o.text.trim() === opt || o.value === opt); if (!o) return false;
        e.value = o.value; e.dispatchEvent(new Event('input', {bubbles: true}));
        e.dispatchEvent(new Event('change', {bubbles: true})); return true; }""", element, option)
    if not ok.get("value"):
        return f"Option '{option}' not found in dropdown [{element}]."
    ff.settle()
    return browser_read()


def browser_scroll(direction: str = "down") -> str:
    dy = {"down": "innerHeight * 0.85", "up": "-innerHeight * 0.85", "top": "-1e9", "bottom": "1e9"}.get(direction, "innerHeight * 0.85")
    ff.js(f"() => scrollBy(0, {dy})")
    time.sleep(0.4)
    return browser_read()


def browser_back() -> str:
    ff.cmd("browsingContext.traverseHistory", {"context": ff.current_tab(), "delta": -1})
    ff.settle()
    return browser_read()


def browser_switch_tab(tab: int) -> str:
    tabs = ff.tabs()
    if not 1 <= int(tab) <= len(tabs):
        return f"No tab {tab}. There are {len(tabs)} tabs."
    ff.tab = tabs[int(tab) - 1]["id"]
    ff.cmd("browsingContext.activate", {"context": ff.tab})
    return browser_read()


def available() -> bool:
    try:
        socket.create_connection(("127.0.0.1", MARIONETTE_PORT), timeout=1).close()
        return True
    except OSError:
        return False


def _fn(name, desc, props=None, required=()):
    return {"type": "function", "function": {"name": name, "description": desc, "parameters": {
        "type": "object", "properties": props or {}, "required": list(required)}}}


EL = {"element": {"type": "integer", "description": "The [n] number from the last page read"}}
TOOLS = [
    _fn("browser_tabs", "List the tabs open in the user's Firefox."),
    _fn("browser_read", "Read the current tab of the user's Firefox as text. Links, buttons and fields are numbered [n]."),
    _fn("browser_open", "Open a URL in the user's Firefox (current tab, or a new tab).",
        {"url": {"type": "string"}, "new_tab": {"type": "boolean"}}, ["url"]),
    _fn("browser_click", "Click element [n] on the current page.", EL, ["element"]),
    _fn("browser_type", "Type text into field [n], replacing what is there. submit=true presses Enter after.",
        {**EL, "text": {"type": "string"}, "submit": {"type": "boolean"}}, ["element", "text"]),
    _fn("browser_select", "Choose an option in dropdown [n].", {**EL, "option": {"type": "string"}}, ["element", "option"]),
    _fn("browser_scroll", "Scroll the current page.",
        {"direction": {"type": "string", "enum": ["down", "up", "top", "bottom"]}}, ["direction"]),
    _fn("browser_back", "Go back in the current tab."),
    _fn("browser_switch_tab", "Switch to tab number t from browser_tabs.", {"tab": {"type": "integer"}}, ["tab"]),
]
FUNCS = {t["function"]["name"]: globals()[t["function"]["name"]] for t in TOOLS}
# Reading needs no confirmation; anything that changes the page asks first.
READ_ONLY = {"browser_tabs", "browser_read", "browser_scroll", "browser_switch_tab"}
