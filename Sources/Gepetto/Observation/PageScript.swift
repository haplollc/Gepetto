//
//  PageScript.swift
//  Gepetto
//
//  The JavaScript side of page observation. Injected once per page as a
//  WKUserScript (document end, main frame + subframes) into a private
//  content world, `BrowserEngine.contentWorld`; the Swift side then calls
//  `window.__gepetto.snapshot(...)` and friends in that same world. Page
//  scripts share the DOM with it but not its globals, so they can neither
//  pre-empt nor rewrite the namespace.
//
//  What it does:
//   - Walks the DOM (shadow roots and same-origin iframes included), finds
//     every interactive element, and gives each a stable `data-gep-ref`
//     attribute. The ref survives across snapshots as long as the element is
//     attached, so an index the model saw a step ago still means the same
//     thing after a scroll or a minor re-render. Refs carry a per-document
//     token, so they never repeat across navigations.
//   - Builds the compact element list the model reads:
//       [12]<button>Sign in</button>
//     one line per element, nothing a small model has to parse. Password,
//     card and one-time-code values never leave the page: those fields only
//     report whether they are filled.
//   - Draws / clears "set-of-marks" badges and a highlight ring on the page
//     itself, so what the model sees and what the user sees are the same.
//   - Reports element rectangles (viewport coordinates) so the host can
//     animate a cursor to them.
//   - Waits for the page to settle: DOM mutations quiet, no pending
//     navigation, fonts/images past their first paint.
//   - Finds and dismisses cookie / consent banners.
//   - Reports what needs a person (captcha, sign-in, code, payment) while
//     that UI is on screen.
//

import Foundation

enum PageScript {

    /// Namespace every injected function lives under.
    static let namespace = "__gepetto"

    // MARK: - Source

    static let source: String = #"""
    (function () {
      if (window.__gepetto && window.__gepetto.version === 2) { return; }

      var NS = {};
      NS.version = 2;
      // Refs carry a per-document token, so ref "3" on the previous page is
      // never mistaken for ref "3" here (new-element stars, receipts).
      var docToken = Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
      var nextRef = 1;
      var refToElement = new Map();   // ref -> WeakRef(element)
      var lastIndexToRef = [];        // snapshot index -> ref
      var mutationCount = 0;
      var lastMutationAt = performance.now();

      // ---- Mutation tracking (for settle detection) ----------------------
      // Our own writes are not the page changing: the data-gep-ref attributes
      // a snapshot sets, inserting the overlay, and anything inside it.
      function onlyOverlay(nodes) {
        for (var j = 0; j < nodes.length; j++) { if (nodes[j].id !== '__gep_overlay') return false; }
        return true;
      }
      try {
        var mo = new MutationObserver(function (list) {
          for (var i = 0; i < list.length; i++) {
            var m = list[i], t = m.target;
            if (m.type === 'attributes' && m.attributeName === 'data-gep-ref') { continue; }
            if (t && t.closest && t.closest('#__gep_overlay')) { continue; }
            if (m.type === 'childList' && onlyOverlay(m.addedNodes) && onlyOverlay(m.removedNodes)) { continue; }
            mutationCount++;
            lastMutationAt = performance.now();
            return;
          }
        });
        mo.observe(document.documentElement, { childList: true, subtree: true, attributes: true, characterData: true });
      } catch (e) {}

      NS.quietMs = function () { return performance.now() - lastMutationAt; };
      NS.mutationCount = function () { return mutationCount; };

      // ---- Helpers ---------------------------------------------------------
      function isVisible(el) {
        if (!el || !el.getClientRects) return false;
        var style = el.ownerDocument.defaultView.getComputedStyle(el);
        if (!style || style.visibility === 'hidden' || style.display === 'none' || parseFloat(style.opacity || '1') === 0) return false;
        var r = el.getBoundingClientRect();
        if (r.width < 1 || r.height < 1) return false;
        return true;
      }

      function inViewport(r, margin) {
        margin = margin || 0;
        var vw = window.innerWidth, vh = window.innerHeight;
        return r.bottom >= -margin && r.top <= vh + margin && r.right >= -margin && r.left <= vw + margin;
      }

      // Flat-tree parent: into the slot a node is assigned to, and out of a
      // shadow root to its host. Node.contains and closest stop at both.
      function flatParent(n) { return n.assignedSlot || n.parentNode || n.host || null; }
      function flatParentElement(n) {
        var p = flatParent(n);
        while (p && p.nodeType !== 1) p = flatParent(p);
        return p;
      }
      function flatContains(a, b) {
        for (var n = b; n; n = flatParent(n)) { if (n === a) return true; }
        return false;
      }

      // Document.elementFromPoint answers with the shadow host for a point
      // inside an open shadow root; descend to the node really there.
      function deepHit(doc, x, y) {
        var hit = doc.elementFromPoint(x, y);
        for (var d = 0; hit && hit.shadowRoot && d < 16; d++) {
          var sr = hit.shadowRoot;
          var inner = sr.elementFromPoint ? sr.elementFromPoint(x, y) : null;
          if (!inner || inner === hit) break;
          hit = inner;
        }
        return hit;
      }

      // Where a click on `el` lands: the centre of its first fragment on
      // screen, clipped to the viewport. The bounding-box centre of a wrapped
      // inline link can sit on the text around it.
      function probePoint(el) {
        var win = el.ownerDocument.defaultView;
        var vw = win.innerWidth || 1, vh = win.innerHeight || 1;
        var rs = el.getClientRects();
        if (!rs.length) rs = [el.getBoundingClientRect()];
        for (var i = 0; i < rs.length; i++) {
          var r = rs[i];
          var l = Math.max(r.left, 0), t = Math.max(r.top, 0), rt = Math.min(r.right, vw), b = Math.min(r.bottom, vh);
          if (rt - l >= 1 && b - t >= 1) return { x: (l + rt) / 2, y: (t + b) / 2 };
        }
        return null;
      }

      // Is one of the control's labels painted where a click on it lands?
      function labelOnScreen(el) {
        var labels = el.labels || [];
        for (var i = 0; i < labels.length; i++) {
          var lab = labels[i];
          if (!isVisible(lab)) continue;
          var p = probePoint(lab);
          var h = p ? deepHit(lab.ownerDocument, p.x, p.y) : null;
          if (h && (h === lab || flatContains(lab, h))) return true;
        }
        return false;
      }

      function isCovered(el) {
        var p = probePoint(el);
        if (!p) return false;
        var hit = deepHit(el.ownerDocument, p.x, p.y);
        if (!hit) return false;
        if (hit === el || flatContains(el, hit)) return false;
        // Labels of an input count as the input.
        var lab = hit.closest ? hit.closest('label') : null;
        if (lab && (lab === el.closest('label') || lab.control === el)) return false;
        // An ancestor there means the element is not painted at that point
        // (clipped by overflow, a collapsed menu). Two exceptions: the hit
        // test looks straight through pointer-events:none, and a visually
        // hidden input (sr-only, a custom checkbox) is reached through a
        // label that is itself on screen.
        if (flatContains(hit, el)) {
          if (el.ownerDocument.defaultView.getComputedStyle(el).pointerEvents === 'none') return false;
          return !labelOnScreen(el);
        }
        return true;
      }

      function text(el, max) {
        var t = '';
        var ty = el.matches('input') ? (el.type || 'text').toLowerCase() : '';
        if (ty === 'submit' || ty === 'button' || ty === 'reset' || ty === 'image') {
          // Button-like inputs show their value (alt for image buttons); a
          // submit or reset without one shows the browser's default caption.
          // This must come before the field branch, which matches any input.
          t = el.getAttribute('aria-label') || el.value || (ty === 'image' ? el.alt : '') || el.title ||
              (ty === 'submit' ? 'Submit' : ty === 'reset' ? 'Reset' : '') || labelFor(el) || el.name || '';
        } else if (el.matches('input, textarea, select')) {
          t = el.getAttribute('aria-label') || el.placeholder || labelFor(el) || el.name || '';
        } else if (el.matches('img')) {
          t = el.alt || el.title || '';
        } else {
          t = el.getAttribute('aria-label') || el.innerText || el.textContent || el.title || '';
        }
        t = (t || '').replace(/\s+/g, ' ').trim();
        if (max && t.length > max) t = t.slice(0, max - 1) + '…';
        return t;
      }

      function labelFor(el) {
        // Labels live in the element's own tree: a shadow root has its own.
        var root = el.getRootNode ? el.getRootNode() : el.ownerDocument;
        if (!root || !root.getElementById) root = el.ownerDocument;
        if (el.id) {
          var l = root.querySelector('label[for="' + CSS.escape(el.id) + '"]');
          if (l) return (l.textContent || '').trim();
        }
        var p = el.closest('label');
        if (p) return (p.textContent || '').trim();
        var by = el.getAttribute('aria-labelledby');
        if (by) { var b = root.getElementById(by); if (b) return (b.textContent || '').trim(); }
        var td = el.closest('td');
        if (td && td.previousElementSibling) return (td.previousElementSibling.textContent || '').trim();
        return '';
      }

      var INTERACTIVE = 'a[href], button, input:not([type=hidden]), select, textarea, summary, ' +
        '[role=button], [role=link], [role=checkbox], [role=radio], [role=tab], [role=menuitem], ' +
        '[role=menuitemcheckbox], [role=menuitemradio], ' +
        '[role=option], [role=switch], [role=textbox], [role=combobox], [role=searchbox], ' +
        '[contenteditable=true], [onclick], [tabindex]:not([tabindex="-1"])';

      // Controls that are listed as one element: a node inside one is part
      // of it, not a target of its own.
      var CONTROL = 'a[href], button, summary, select, textarea, input, ' +
        '[role=button], [role=link], [role=checkbox], [role=radio], [role=switch], [role=tab], ' +
        '[role=menuitem], [role=menuitemcheckbox], [role=menuitemradio], [role=option]';

      // Is `el` inside a control that the snapshot lists? A control wrapping
      // other controls is skipped as a wrapper (see snapshot), so the nodes
      // inside it have to stand in for it.
      function insideListedControl(el) {
        for (var a = flatParentElement(el); a; a = flatParentElement(a)) {
          if (!a.matches(CONTROL)) continue;
          if (a.matches('a[href], button, input, select, textarea') || !a.querySelector(INTERACTIVE)) return true;
        }
        return false;
      }

      function isInteractive(el) {
        if (el.matches(INTERACTIVE)) return true;
        // The cursor:pointer heuristic finds div / span click handlers. The
        // cursor is inherited, so only the node that introduces it counts:
        // not its children (unless the parent wraps real controls and so is
        // not listed itself), not nodes inside a listed control, and never a
        // shape inside an <svg>.
        if (el.ownerSVGElement) return false;
        var win = el.ownerDocument.defaultView;
        if (win.getComputedStyle(el).cursor !== 'pointer') return false;
        var p = flatParentElement(el);
        if (p && win.getComputedStyle(p).cursor === 'pointer' && !p.querySelector(INTERACTIVE)) return false;
        return !insideListedControl(el);
      }

      // ARIA toggles: their state is aria-checked, whatever element carries them.
      var TOGGLE_KINDS = /^(checkbox|radio|switch|menuitemcheckbox|menuitemradio)$/;

      function kind(el) {
        var tag = el.tagName.toLowerCase();
        if (tag === 'input') {
          var t = (el.type || 'text').toLowerCase();
          if (t === 'submit' || t === 'button' || t === 'image' || t === 'reset') return 'button';
          if (t === 'checkbox' || t === 'radio') return t;
          return 'input';
        }
        // Before the button rule: <button role="switch"> is a switch.
        var role = (el.getAttribute('role') || '').toLowerCase();
        if (TOGGLE_KINDS.test(role)) return role;
        if (tag === 'textarea' || el.getAttribute('contenteditable') === 'true') return 'textarea';
        if (tag === 'select') return 'select';
        if (tag === 'a') {
          // href="#" and javascript: links run script in place; to the
          // model they are buttons, not navigation.
          var h = (el.getAttribute('href') || '').trim().toLowerCase();
          if (h === '' || h === '#' || h.indexOf('javascript:') === 0) return 'button';
          return 'link';
        }
        if (tag === 'button' || role === 'button' || el.matches('[onclick]')) return 'button';
        if (role) return role;
        return 'clickable';
      }

      // Native checkboxes and radios carry .checked; ARIA widgets say it in
      // aria-checked ("mixed" reads as not checked).
      function isChecked(el) {
        if (el.matches('input') && typeof el.checked === 'boolean') return el.checked;
        return (el.getAttribute('aria-checked') || '').toLowerCase() === 'true';
      }

      // Fields whose value never leaves the page: passwords, card data,
      // one-time codes. Deliberately broad: a false positive only hides a
      // value from the model, a false negative puts a secret in the prompt.
      function isSecretField(el) {
        if (el.matches('input') && (el.type || '').toLowerCase() === 'password') return true;
        var ac = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
        for (var i = 0; i < ac.length; i++) {
          if (/^cc-/.test(ac[i]) || /^(one-time-code|new-password|current-password)$/.test(ac[i])) return true;
        }
        // passw(or)?d also catches a password field a "show password" toggle
        // has turned into type=text.
        return /card|cvv|cvc|ssn|passcode|passw(or)?d|otp|pin\b/i.test((el.getAttribute('name') || '') + ' ' + (el.id || ''));
      }

      // The button a form submits with on Enter: its first submit button in
      // tree order (a <button> without a type is one). Shared by the
      // snapshot's submitLabel and by type / pressKey, so the label the
      // approval gate sees is the button that really gets pressed.
      function submitControl(form) {
        if (!form || !form.elements) return null;
        for (var i = 0; i < form.elements.length; i++) {
          var c = form.elements[i];
          if (c.matches('button, input') && (c.type || '').toLowerCase() === 'submit') return c;
        }
        return form.querySelector('input[type=image]');
      }

      function submitForm(form) {
        var btn = submitControl(form);
        if (btn) activate(btn); else if (form.requestSubmit) form.requestSubmit(); else form.submit();
      }

      // href of a link; on an <svg> <a> the property is an SVGAnimatedString.
      function hrefOf(el) {
        return typeof el.href === 'string' ? el.href : (el.getAttribute('href') || el.getAttribute('xlink:href') || '');
      }

      function refFor(el) {
        var existing = el.getAttribute('data-gep-ref');
        if (existing) {
          var w = refToElement.get(existing);
          if (w && w.deref && w.deref() === el) return existing;
          if (w && w.el === el) return existing;
        }
        var ref = docToken + '-' + (nextRef++);
        el.setAttribute('data-gep-ref', ref);
        try { refToElement.set(ref, new WeakRef(el)); } catch (e) { refToElement.set(ref, { el: el, deref: function () { return this.el; } }); }
        return ref;
      }

      NS.elementForRef = function (ref) {
        var w = refToElement.get(String(ref));
        var el = w ? (w.deref ? w.deref() : w.el) : null;
        if (el && el.isConnected) return el;
        // Fall back to the attribute: survives if the reference map was lost.
        return collectRoots(document).reduce(function (found, root) {
          return found || root.querySelector('[data-gep-ref="' + ref + '"]');
        }, null);
      };

      NS.elementForIndex = function (index) {
        var ref = lastIndexToRef[index];
        return ref ? NS.elementForRef(ref) : null;
      };

      // Roots: document, every open shadow root, every same-origin iframe document.
      function collectRoots(doc) {
        var roots = [doc];
        var all = doc.querySelectorAll('*');
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          if (el.shadowRoot) roots.push(el.shadowRoot);
          if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
            try { if (el.contentDocument) roots = roots.concat(collectRoots(el.contentDocument)); } catch (e) {}
          }
        }
        return roots;
      }

      function frameOffset(el) {
        // Offset of an element's frame relative to the top document.
        var x = 0, y = 0;
        var win = el.ownerDocument.defaultView;
        while (win && win !== window.top && win.frameElement) {
          var r = win.frameElement.getBoundingClientRect();
          x += r.left; y += r.top;
          win = win.parent;
        }
        return { x: x, y: y };
      }

      // ---- Snapshot --------------------------------------------------------
      // opts: { viewportOnly: bool, maxElements: int, textMax: int, includeText: bool }
      NS.snapshot = function (opts) {
        opts = opts || {};
        var maxElements = opts.maxElements || 60;
        var viewportOnly = opts.viewportOnly !== false;
        var textMax = opts.textMax || 1500;
        var elements = [];
        var seen = new Set();
        var roots = collectRoots(document);

        for (var r = 0; r < roots.length; r++) {
          var root = roots[r];
          var candidates = root.querySelectorAll ? root.querySelectorAll('*') : [];
          for (var i = 0; i < candidates.length; i++) {
            var el = candidates[i];
            if (seen.has(el)) continue;
            if (el.closest && el.closest('#__gep_overlay')) continue;
            if (!isInteractive(el)) continue;
            if (el.disabled || el.getAttribute('aria-hidden') === 'true') continue;
            // Skip a container whose only job is wrapping one interactive child.
            if (el.querySelector && el.querySelector(INTERACTIVE) && !el.matches('a[href], button, input, select, textarea')) continue;
            if (!isVisible(el)) continue;
            var rect = el.getBoundingClientRect();
            var off = frameOffset(el);
            var box = { x: rect.left + off.x, y: rect.top + off.y, w: rect.width, h: rect.height };
            var inView = inViewport({ left: box.x, top: box.y, right: box.x + box.w, bottom: box.y + box.h }, 0);
            if (viewportOnly && !inView) continue;
            // Painted over by something else (a modal, a sticky header)? Then a
            // click would land on that instead; leave it out of the list.
            if (inView && isCovered(el)) continue;
            seen.add(el);
            elements.push({ el: el, box: box, inView: inView });
          }
        }

        // Reading order: top to bottom, then left to right.
        elements.sort(function (a, b) { return (a.box.y - b.box.y) || (a.box.x - b.box.x); });
        var truncated = false;
        if (elements.length > maxElements) { elements = elements.slice(0, maxElements); truncated = true; }

        lastIndexToRef = [];
        var out = [];
        for (var k = 0; k < elements.length; k++) {
          var e = elements[k].el;
          var ref = refFor(e);
          lastIndexToRef[k] = ref;
          var kd = kind(e);
          var entry = {
            index: k, ref: ref, kind: kd, tag: e.tagName.toLowerCase(),
            text: text(e, 80),
            box: elements[k].box,
            inView: elements[k].inView
          };
          if (kd === 'input' || kd === 'textarea' || kd === 'select') {
            var raw = typeof e.value === 'string' ? e.value : '';
            entry.inputType = (e.type || '').toLowerCase();
            entry.filled = raw.length > 0;
            if (isSecretField(e)) {
              // Never copied: the model only learns whether it is filled.
              entry.secret = true;
              entry.value = '';
              if (!e.matches('input, textarea, select')) entry.text = e.getAttribute('aria-label') || '';
            } else {
              entry.value = raw.slice(0, 60);
            }
            if (e.placeholder) entry.placeholder = e.placeholder.slice(0, 60);
            if (kd === 'select') {
              entry.options = Array.prototype.slice.call(e.options || [], 0, 12).map(function (o) { return (o.text || '').trim().slice(0, 40); });
            } else {
              // What Enter in this field submits with, for the approval gate.
              var btn = submitControl(e.form || e.closest('form'));
              if (btn) entry.submitLabel = text(btn, 60);
            }
          }
          if (TOGGLE_KINDS.test(kd)) entry.checked = isChecked(e);
          if (kd === 'link') entry.href = hrefOf(e).slice(0, 200);
          out.push(entry);
        }

        var body = document.body;
        var scrollH = Math.max(body ? body.scrollHeight : 0, document.documentElement.scrollHeight);
        var pageText = '';
        if (opts.includeText !== false) {
          pageText = visibleText(textMax, viewportOnly);
        }
        return {
          url: location.href,
          title: document.title,
          elements: out,
          truncated: truncated,
          scroll: { y: window.scrollY, viewport: window.innerHeight, total: scrollH },
          text: pageText,
          readyState: document.readyState,
          mutations: mutationCount
        };
      };

      // Depth-first walk in document order that also enters open shadow
      // roots and visible same-origin frames where they sit in the page.
      // `visit` returns false to skip a node's subtree.
      function walk(node, visit) {
        var kids = node.childNodes;
        for (var i = 0; i < kids.length; i++) {
          var c = kids[i];
          if (visit(c) === false || c.nodeType !== 1) continue;
          if (c.shadowRoot) walk(c.shadowRoot, visit);
          if (c.tagName === 'IFRAME' || c.tagName === 'FRAME') {
            var d = null;
            try { d = c.contentDocument; } catch (e) {}
            if (d && isVisible(c)) walk(d, visit);
          }
          walk(c, visit);
        }
      }

      // Visible text, viewport-first: the text of elements whose boxes touch the
      // viewport, in reading order, with shadow roots and same-origin frames
      // read where they sit; falls back to innerText when that is empty. A
      // secret textarea's contents are left out like its value.
      var TEXT_SKIP = 'script, style, noscript, template, head, #__gep_overlay';
      function visibleText(max, viewportOnly) {
        var out = [];
        var total = 0;
        walk(document.body || document.documentElement, function (n) {
          if (total >= max) return false;
          if (n.nodeType === 1) return !n.matches(TEXT_SKIP) && !(n.matches('textarea') && isSecretField(n));
          if (n.nodeType !== 3) return false;
          var t = n.nodeValue.replace(/\s+/g, ' ').trim();
          if (!t) return false;
          var p = n.parentElement || (n.parentNode && n.parentNode.host) || null;
          if (!p || !isVisible(p)) return false;
          // Light-DOM text that a shadow tree does not slot is never painted.
          if (p.shadowRoot && !n.assignedSlot) return false;
          if (viewportOnly) {
            var r = p.getBoundingClientRect(), off = frameOffset(p);
            if (!inViewport({ left: r.left + off.x, top: r.top + off.y, right: r.right + off.x, bottom: r.bottom + off.y }, 40)) return false;
          }
          out.push(t); total += t.length + 1;
          return false;
        });
        var s = out.join(' ');
        if (!s && document.body) s = (document.body.innerText || '').replace(/\s+/g, ' ').trim();
        return s.length > max ? s.slice(0, max - 1) + '…' : s;
      }

      // ---- Element actions ------------------------------------------------
      function resolve(target) {
        var el = null;
        if (typeof target === 'number') el = NS.elementForIndex(target);
        else if (typeof target === 'string' && /^\d+$/.test(target)) el = NS.elementForIndex(parseInt(target, 10));
        else if (typeof target === 'string') el = document.querySelector(target);
        return el;
      }

      NS.rect = function (target) {
        var el = resolve(target);
        if (!el) return null;
        var r = el.getBoundingClientRect(); var off = frameOffset(el);
        return { x: r.left + off.x, y: r.top + off.y, w: r.width, h: r.height };
      };

      NS.scrollIntoView = function (target) {
        var el = resolve(target);
        if (!el) return false;
        el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
        return true;
      };

      // click() exists on HTMLElement only; an SVG (or MathML) node listed
      // through role / tabindex / onclick would throw. A synthetic click runs
      // the same listeners and the nearest ancestor's activation behaviour.
      function activate(el, opts) {
        if (typeof el.click === 'function') { el.click(); return; }
        el.dispatchEvent(new MouseEvent('click', Object.assign({ bubbles: true, cancelable: true, composed: true }, opts || {})));
      }

      NS.click = function (target) {
        var el = resolve(target);
        if (!el) return { ok: false, error: 'no element for ' + target };
        el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
        var r = el.getBoundingClientRect();
        var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
        var before = location.href;
        try {
          var opts = { bubbles: true, cancelable: true, composed: true, clientX: cx, clientY: cy, view: el.ownerDocument.defaultView };
          el.dispatchEvent(new PointerEvent('pointerdown', opts));
          el.dispatchEvent(new MouseEvent('mousedown', opts));
          if (el.focus) el.focus({ preventScroll: true });
          el.dispatchEvent(new PointerEvent('pointerup', opts));
          el.dispatchEvent(new MouseEvent('mouseup', opts));
          activate(el, opts);
        } catch (e) { return { ok: false, error: String(e) }; }
        return { ok: true, text: text(el, 60), kind: kind(el), urlBefore: before };
      };

      // Set a field's value the way a user would: focus, select all, input events,
      // React/Vue-compatible native setter. `submit` presses Enter afterwards.
      NS.type = function (target, value, submit) {
        var el = resolve(target);
        if (!el) return { ok: false, error: 'no element for ' + target };
        el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
        if (el.focus) el.focus({ preventScroll: true });
        var tag = el.tagName.toLowerCase();
        if (el.getAttribute('contenteditable') === 'true') {
          el.textContent = value;
          el.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' }));
        } else if (tag === 'select') {
          return NS.select(target, value);
        } else {
          var proto = tag === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          var setter = Object.getOwnPropertyDescriptor(proto, 'value');
          function setValue(v) { if (setter && setter.set) setter.set.call(el, v); else el.value = v; }
          // Clear, then type one character at a time so key handlers,
          // autocomplete lists and framework state see ordinary keystrokes.
          setValue('');
          el.dispatchEvent(new Event('input', { bubbles: true }));
          var chars = Array.from(String(value));
          if (chars.length <= 120) {
            for (var ci = 0; ci < chars.length; ci++) {
              var ch = chars[ci];
              var kopt = { bubbles: true, cancelable: true, key: ch, code: ch === ' ' ? 'Space' : 'Key' + ch.toUpperCase(), charCode: ch.charCodeAt(0), keyCode: ch.charCodeAt(0), which: ch.charCodeAt(0) };
              if (!el.dispatchEvent(new KeyboardEvent('keydown', kopt))) continue;
              el.dispatchEvent(new KeyboardEvent('keypress', kopt));
              setValue((el.value || '') + ch);
              el.dispatchEvent(new InputEvent('input', { bubbles: true, data: ch, inputType: 'insertText' }));
              el.dispatchEvent(new KeyboardEvent('keyup', kopt));
            }
          }
          if (el.value !== value) {
            setValue(value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
          }
          el.dispatchEvent(new Event('change', { bubbles: true }));
        }
        if (submit) {
          var kopts = { bubbles: true, cancelable: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13 };
          var prevented = !el.dispatchEvent(new KeyboardEvent('keydown', kopts));
          el.dispatchEvent(new KeyboardEvent('keypress', kopts));
          el.dispatchEvent(new KeyboardEvent('keyup', kopts));
          if (!prevented && el.form) submitForm(el.form);
        }
        var shown = el.value !== undefined ? el.value : el.textContent || '';
        return { ok: true, value: isSecretField(el) ? '' : String(shown).slice(0, 60), label: text(el, 40) };
      };

      NS.select = function (target, value) {
        var el = resolve(target);
        if (!el || el.tagName.toLowerCase() !== 'select') return { ok: false, error: 'not a select' };
        var want = String(value).trim().toLowerCase();
        var hit = null;
        for (var i = 0; i < el.options.length; i++) {
          var o = el.options[i];
          if (o.value.toLowerCase() === want || (o.text || '').trim().toLowerCase() === want) { hit = o; break; }
        }
        if (!hit) for (var j = 0; j < el.options.length; j++) {
          if ((el.options[j].text || '').toLowerCase().indexOf(want) !== -1) { hit = el.options[j]; break; }
        }
        if (!hit) return { ok: false, error: 'no option matching "' + value + '"', options: Array.prototype.map.call(el.options, function (o) { return o.text; }).slice(0, 12) };
        el.value = hit.value;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return { ok: true, selected: hit.text };
      };

      NS.setChecked = function (target, checked) {
        var el = resolve(target);
        if (!el) return { ok: false, error: 'no element' };
        var want = !!checked;
        if (isChecked(el) === want) return { ok: true, checked: want, state: 'already ' + (want ? 'checked' : 'unchecked') };
        try { activate(el); } catch (e) { return { ok: false, error: String(e) }; }
        // A native input flips at once. An ARIA widget may re-render after
        // this returns, so its state is not insisted on here.
        if (el.matches('input') && typeof el.checked === 'boolean' && el.checked !== want) {
          return { ok: false, checked: el.checked,
                   error: (el.type === 'radio' && !want) ? 'a radio button cannot be unchecked; pick another option' : 'the page kept it ' + (el.checked ? 'checked' : 'unchecked') };
        }
        return { ok: true, checked: isChecked(el), state: 'clicked' };
      };

      // The element that really has focus: document.activeElement stops at
      // a shadow host or an <iframe>, so descend through open shadow roots
      // and same-origin frames.
      function deepActive() {
        var a = document.activeElement;
        for (var d = 0; a && d < 32; d++) {
          var inner = null;
          try {
            if (a.shadowRoot && a.shadowRoot.activeElement) inner = a.shadowRoot.activeElement;
            else if (a.contentDocument && a.contentDocument.activeElement) inner = a.contentDocument.activeElement;
          } catch (e) {}
          if (!inner || inner === a) break;
          a = inner;
        }
        return a || document.body;
      }

      // Visible, focusable elements in tab order: positive tabindex first,
      // then document order, through shadow roots and frames (frames are
      // entered, not focused as a whole).
      var FOCUSABLE = 'a[href], area[href], button, input:not([type=hidden]), select, textarea, summary, ' +
        '[contenteditable=""], [contenteditable=true], [tabindex]';
      function focusables() {
        var out = [];
        walk(document, function (n) {
          if (n.nodeType !== 1 || n.id === '__gep_overlay') return false;
          if (n.matches(FOCUSABLE) && !n.matches('iframe, frame') && !n.disabled && n.tabIndex >= 0 && isVisible(n)) out.push(n);
          return true;
        });
        out.sort(function (a, b) { return (a.tabIndex > 0 ? a.tabIndex : 1e9) - (b.tabIndex > 0 ? b.tabIndex : 1e9); });
        return out;
      }

      NS.pressKey = function (key) {
        var el = deepActive();
        var map = { Enter: 13, Escape: 27, Tab: 9, Backspace: 8, ArrowDown: 40, ArrowUp: 38, ArrowLeft: 37, ArrowRight: 39, Space: 32 };
        var code = map[key] || 0;
        var opts = { bubbles: true, cancelable: true, key: key === 'Space' ? ' ' : key, code: key, keyCode: code, which: code };
        var prevented = !el.dispatchEvent(new KeyboardEvent('keydown', opts));
        if (key === 'Tab') {
          // A synthetic Tab moves nothing by itself: move focus the way the
          // browser would, then let keyup land on the new element.
          var next = el;
          if (!prevented) {
            var list = focusables();
            if (list.length) {
              list[(list.indexOf(el) + 1) % list.length].focus();
              next = deepActive();
            }
          }
          next.dispatchEvent(new KeyboardEvent('keyup', opts));
          return { ok: true, target: el.tagName.toLowerCase(), focused: text(next, 40) };
        }
        el.dispatchEvent(new KeyboardEvent('keypress', opts));
        el.dispatchEvent(new KeyboardEvent('keyup', opts));
        if (key === 'Enter' && !prevented && el.form) submitForm(el.form);
        if (key === 'Escape') { if (el.blur) el.blur(); }
        return { ok: true, target: el.tagName.toLowerCase() };
      };

      // A container that scrolls vertically and is a main panel (at least
      // 40% of the viewport tall, not a code block); with a direction, only
      // one that can still move that way.
      function isScroller(el, dy) {
        var cs = el.ownerDocument.defaultView.getComputedStyle(el);
        if (cs.overflowY !== 'auto' && cs.overflowY !== 'scroll') return false;
        if (el.scrollHeight <= el.clientHeight + 10) return false;
        if (el.getBoundingClientRect().height <= window.innerHeight * 0.4) return false;
        if (!dy) return true;
        return dy > 0 ? el.scrollTop + el.clientHeight < el.scrollHeight - 2 : el.scrollTop > 0;
      }

      // The container a finger at the viewport centre would scroll.
      function scrollerAtCentre(dy) {
        var n = deepHit(document, window.innerWidth / 2, window.innerHeight / 2);
        for (; n && n !== document.documentElement; n = flatParentElement(n)) {
          if (isScroller(n, dy)) return n;
        }
        return null;
      }

      function largestScroller(dy) {
        var best = null, bestArea = 0;
        var all = document.querySelectorAll('main, [role=main], section, article, div, ul, ol');
        for (var i = 0; i < all.length; i++) {
          if (!isScroller(all[i], dy)) continue;
          var r = all[i].getBoundingClientRect();
          if (r.width * r.height > bestArea) { best = all[i]; bestArea = r.width * r.height; }
        }
        return best;
      }

      // Scroll the window; when it cannot move, the panel that holds the
      // content. Both edges are reported either way.
      NS.scrollBy = function (dy) {
        var se = document.scrollingElement || document.documentElement;
        var max = se.scrollHeight - window.innerHeight;
        var before = window.scrollY;
        window.scrollBy({ top: dy, left: 0, behavior: 'instant' });
        var c = null;
        if (window.scrollY === before) {
          // A window that scrolls but is already at that edge hands over only
          // to a panel under the viewport centre that can still move, never to
          // some unrelated div. A window that cannot scroll at all (app layouts
          // with a fixed body) means a container holds the content: prefer the
          // one under the centre, then the largest, then one stuck at its edge
          // so that edge is reported.
          c = max > 2 ? scrollerAtCentre(dy)
                      : (scrollerAtCentre(dy) || largestScroller(dy) || scrollerAtCentre(0) || largestScroller(0));
        }
        if (!c) {
          return { ok: true, y: window.scrollY, container: false, atBottom: window.scrollY >= max - 2, atTop: window.scrollY <= 0 };
        }
        c.scrollBy({ top: dy, left: 0, behavior: 'instant' });
        return { ok: true, y: c.scrollTop, container: true, atTop: c.scrollTop <= 0, atBottom: c.scrollTop + c.clientHeight >= c.scrollHeight - 2 };
      };

      // ---- Settle / readiness --------------------------------------------
      NS.isSettled = function (quietMs) {
        quietMs = quietMs || 300;
        if (document.readyState !== 'complete' && document.readyState !== 'interactive') return false;
        return NS.quietMs() >= quietMs;
      };

      // ---- Cookie / consent banners -------------------------------------
      // A button is pressed only inside a consent host: an element whose text
      // mentions cookies / consent / privacy / GDPR and that is either a
      // dialog or banner, or a container whose id / class names a cookie or
      // consent manager. Nothing outside one is ever touched, so a generic
      // Continue / OK / Close elsewhere is safe. Inside a plain dialog or
      // banner only cookie-specific choices count (a terms dialog's "I agree"
      // is not ours to press); the plain words need the manager's own
      // container. A host holding a sign-in, card or text field, or a price,
      // is not a consent banner whatever it says. Accept / Agree / Allow all
      // wins over the other choices.
      var CONSENT_CHOICE = /^(accept (all|cookies|all cookies)|accept (and|&) close|allow (all|cookies|all cookies)|consent|reject( all)?( cookies)?|only necessary|necessary only|decline( all)?|no thanks|do not consent|continue without accepting|(dis)?agree (and|&) close)$/i;
      var CONSENT_PLAIN = /^(accept|agree( and continue)?|i agree|i accept|got it|ok(ay)?|continue|close)$/i;
      // "Privacy Policy" / "Cookie Policy" links sit in every terms dialog;
      // they alone do not make one a consent banner.
      var CONSENT_WORDS = /cookie(?!\s+policy)|consent|gdpr|privacy(?!\s+(policy|notice|statement))/i;
      var NOT_CONSENT = 'input[type=password], input[type=email], input[type=tel], input[type=text], input:not([type]), ' +
        'input[autocomplete*="cc-" i], textarea';
      var PRICE = /[$€£¥]\s?\d|\d[.,]\d{2}\s?(usd|eur|gbp)\b/i;

      // id / class / aria-label of a cookie or consent manager. "cmp-" is
      // left out: Adobe Experience Manager prefixes every component with it.
      function isConsentManager(n) {
        var s = (n.id || '') + ' ' + (typeof n.className === 'string' ? n.className : '') + ' ' + (n.getAttribute('aria-label') || '');
        return /cookie|consent|gdpr|cmp(?!-)/i.test(s);
      }
      function isDialogOrBanner(n) {
        if (n.matches('[role=dialog], [role=alertdialog], [aria-modal=true], [role=banner]')) return true;
        return /banner/i.test((n.id || '') + ' ' + (typeof n.className === 'string' ? n.className : ''));
      }

      // 0: not inside a consent host; 1: inside a dialog / banner about
      // consent; 2: inside a consent manager's own container. The nearest
      // host that talks about consent decides whether a form disqualifies it.
      function consentLevel(b, textCache) {
        var level = 0;
        for (var n = flatParentElement(b); n; n = flatParentElement(n)) {
          var doc = n.ownerDocument;
          if (n === doc.body || n === doc.documentElement) break;
          var manager = isConsentManager(n);
          if (!manager && !isDialogOrBanner(n)) continue;
          var t = textCache.get(n);
          if (t === undefined) { t = (n.innerText || '').slice(0, 1500); textCache.set(n, t); }
          if (!CONSENT_WORDS.test(t)) continue;
          if (n.querySelector(NOT_CONSENT) || PRICE.test(t)) break;
          if (manager) return 2;
          level = 1;
        }
        return level;
      }

      function consentRank(t) {
        if (/not consent|without accepting|disagree/i.test(t)) return 2;
        if (/accept|agree|allow|consent/i.test(t)) return 0;
        if (/^(got it|ok(ay)?)$/i.test(t)) return 1;
        if (/reject|necessary|decline|no thanks/i.test(t)) return 2;
        if (/^continue$/i.test(t)) return 3;
        return 4;
      }

      NS.dismissConsent = function () {
        var roots = collectRoots(document);
        var textCache = new Map();
        var picks = [];
        for (var r = 0; r < roots.length; r++) {
          var buttons = roots[r].querySelectorAll ? roots[r].querySelectorAll('button, a[href], [role=button], input[type=button], input[type=submit]') : [];
          for (var i = 0; i < buttons.length; i++) {
            var b = buttons[i];
            if (!isVisible(b)) continue;
            var t = text(b, 40).replace(/[\s!.]+$/, '');
            var choice = CONSENT_CHOICE.test(t);
            if (!choice && !CONSENT_PLAIN.test(t)) continue;
            var level = consentLevel(b, textCache);
            if (level === 0 || (!choice && level < 2)) continue;
            picks.push({ el: b, t: t, rank: consentRank(t) });
          }
        }
        if (!picks.length) return { dismissed: false };
        picks.sort(function (a, b) { return a.rank - b.rank; });
        try { activate(picks[0].el); } catch (e) { return { dismissed: false, error: String(e) }; }
        return { dismissed: true, clicked: picks[0].t };
      };

      // ---- Human-needed detection ----------------------------------------
      // A blocker counts only while its UI is on screen: a captcha widget, a
      // password field (login), a one-time-code field (two_factor), a card
      // number field or hosted card frame (payment). Structural markers stay
      // on a page whatever the person does (a reCAPTCHA v3 script or badge,
      // Stripe's hidden controller frames, a hidden login form, a "Sign in"
      // link, the word captcha in a script, prose about codes), so they never
      // count: reporting them would hand the page over on every step.
      function findAll(roots, sel) {
        var out = [];
        for (var r = 0; r < roots.length; r++) {
          var list = roots[r].querySelectorAll ? roots[r].querySelectorAll(sel) : [];
          for (var i = 0; i < list.length; i++) out.push(list[i]);
        }
        return out;
      }

      // Visible, at least `minH` px tall, and touching the viewport.
      function onScreen(el, minH) {
        if (!isVisible(el)) return false;
        var r = el.getBoundingClientRect(), off = frameOffset(el);
        if (r.height < minH) return false;
        return inViewport({ left: r.left + off.x, top: r.top + off.y, right: r.right + off.x, bottom: r.bottom + off.y }, 0);
      }

      function autocompleteTokens(el) { return (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/); }
      function nameAndId(el) { return (el.getAttribute('name') || '') + ' ' + (el.id || ''); }

      // Captcha: a reCAPTCHA checkbox or challenge popup, an hCaptcha or
      // Turnstile frame, a widget box with something rendered in it, or
      // Cloudflare's challenge page. The invisible reCAPTCHA badge and
      // size=invisible frames are markers, not widgets. A solved widget keeps
      // showing its ticked box, so one whose response field holds a token is
      // done.
      var CAPTCHA_SRC = /\/recaptcha\/(api2|enterprise)\/(anchor|bframe)|hcaptcha\.com|challenges\.cloudflare\.com/i;
      var CAPTCHA_BOX = '.g-recaptcha, .h-captcha, .cf-turnstile, #challenge-stage, #challenge-running, #cf-challenge-running, #turnstile-wrapper';
      function captchaSolved(el) {
        var scope = el.closest('.g-recaptcha, .h-captcha, .cf-turnstile, form') || el.ownerDocument;
        var fields = scope.querySelectorAll('textarea[name="g-recaptcha-response"], textarea[name="h-captcha-response"], input[name="cf-turnstile-response"]');
        for (var i = 0; i < fields.length; i++) { if (fields[i].value) return true; }
        return false;
      }
      function captchaOnScreen(roots) {
        var frames = findAll(roots, 'iframe');
        for (var i = 0; i < frames.length; i++) {
          var f = frames[i], src = f.getAttribute('src') || '';
          var box = f.closest(CAPTCHA_BOX);
          if (!CAPTCHA_SRC.test(src) && !box) continue;
          if (f.closest('.grecaptcha-badge') || /size=invisible|checkbox-invisible/i.test(src)) continue;
          if ((box && box.getAttribute('data-size') === 'invisible') || !onScreen(f, 40)) continue;
          // The challenge popup is on screen only while it is asking.
          if (/\/bframe/i.test(src) || !captchaSolved(f)) return true;
        }
        var boxes = findAll(roots, CAPTCHA_BOX);
        for (var j = 0; j < boxes.length; j++) {
          var b = boxes[j];
          // Invisible reCAPTCHA puts .g-recaptcha on the submit button itself.
          if (b.matches('button, a, input, [role=button]') || b.getAttribute('data-size') === 'invisible') continue;
          if (onScreen(b, 40) && !captchaSolved(b)) return true;
        }
        return false;
      }

      // A one-time-code field: autocomplete=one-time-code, or a name / id
      // that says otp / totp / mfa / 2fa. Prose about codes never counts.
      function isCodeField(el) {
        if (autocompleteTokens(el).indexOf('one-time-code') !== -1) return true;
        return /(^|[^a-z])(otp|totp|otc|mfa|2fa|tfa)/i.test(nameAndId(el));
      }
      function isCardNumberField(el) {
        if (autocompleteTokens(el).indexOf('cc-number') !== -1) return true;
        return /card.?(number|num|no)|ccnum|cc.?number/i.test(nameAndId(el));
      }
      // Hosted card fields (Stripe, Braintree, Adyen, Checkout.com, ...) live in
      // frames; Stripe's controller and metrics frames are hidden and 0x0.
      function isCardFrame(f) {
        var s = (f.getAttribute('name') || '') + ' ' + (f.getAttribute('title') || '') + ' ' + (f.getAttribute('src') || '');
        return /card|braintree-hosted-field|securedfields|elements-inner-payment|payment input/i.test(s) && !/controller|metrics/i.test(s);
      }

      NS.blockers = function () {
        var roots = collectRoots(document);
        function any(list, minH, test) {
          for (var i = 0; i < list.length; i++) { if ((!test || test(list[i])) && onScreen(list[i], minH)) return true; }
          return false;
        }
        var inputs = findAll(roots, 'input:not([type=hidden])');
        var out = [];
        if (captchaOnScreen(roots)) out.push('captcha');
        if (any(findAll(roots, 'input[type=password]'), 1)) out.push('login');
        if (any(inputs, 1, isCodeField)) out.push('two_factor');
        if (any(inputs, 1, isCardNumberField) || any(findAll(roots, 'iframe'), 16, isCardFrame)) out.push('payment');
        return out;
      };

      // ---- Overlay: set-of-marks badges + highlight ring ----------------
      function overlay() {
        var o = document.getElementById('__gep_overlay');
        if (o) return o;
        o = document.createElement('div');
        o.id = '__gep_overlay';
        o.setAttribute('aria-hidden', 'true');
        o.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483646;font-family:-apple-system,system-ui,sans-serif;';
        (document.body || document.documentElement).appendChild(o);
        return o;
      }

      NS.showMarks = function (accent) {
        accent = accent || '#111111';
        var o = overlay();
        o.innerHTML = '';
        for (var i = 0; i < lastIndexToRef.length; i++) {
          var el = NS.elementForRef(lastIndexToRef[i]);
          if (!el) continue;
          var r = el.getBoundingClientRect(); var off = frameOffset(el);
          if (r.width < 1 || r.height < 1) continue;
          // A small translucent badge in the element's corner; no box around
          // the element, so the page stays readable.
          var tag = document.createElement('div');
          tag.textContent = String(i);
          tag.style.cssText = 'position:absolute;left:' + (r.left + off.x - 2) + 'px;top:' + (r.top + off.y - 2) + 'px;' +
            'background:' + accent + ';color:#fff;opacity:.82;font-size:9px;font-weight:600;line-height:14px;padding:0 4px;border-radius:7px;' +
            'box-shadow:0 0 0 1px rgba(255,255,255,.9);white-space:nowrap;font-variant-numeric:tabular-nums;';
          o.appendChild(tag);
        }
        return lastIndexToRef.length;
      };

      NS.hideMarks = function () { var o = document.getElementById('__gep_overlay'); if (o) o.innerHTML = ''; return true; };

      NS.highlight = function (target, accent, label) {
        accent = accent || '#111111';
        var el = resolve(target);
        if (!el) return false;
        var o = overlay();
        var r = el.getBoundingClientRect(); var off = frameOffset(el);
        // One thin ring that settles onto the element. The label is spoken
        // by the panel's thought line, not painted on the page.
        var ring = document.createElement('div');
        ring.className = '__gep_ring';
        ring.style.cssText = 'position:absolute;left:' + (r.left + off.x - 4) + 'px;top:' + (r.top + off.y - 4) + 'px;width:' + (r.width + 8) + 'px;height:' + (r.height + 8) + 'px;' +
          'border:2px solid ' + accent + ';border-radius:8px;box-sizing:border-box;' +
          'box-shadow:0 0 0 1px rgba(255,255,255,.9), 0 0 0 6px rgba(0,0,0,.08);' +
          'opacity:0;transform:scale(1.06);transition:opacity .22s ease, transform .3s cubic-bezier(.2,.8,.2,1);';
        var olds = o.querySelectorAll('.__gep_ring'); for (var i = 0; i < olds.length; i++) olds[i].remove();
        o.appendChild(ring);
        requestAnimationFrame(function () { ring.style.opacity = '1'; ring.style.transform = 'none'; });
        return true;
      };

      NS.clearHighlight = function () {
        var o = document.getElementById('__gep_overlay'); if (!o) return;
        var olds = o.querySelectorAll('.__gep_ring'); for (var i = 0; i < olds.length; i++) olds[i].remove();
      };

      window.__gepetto = NS;
    })();
    """#
}
