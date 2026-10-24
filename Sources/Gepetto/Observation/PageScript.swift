//
//  PageScript.swift
//  Gepetto
//
//  The JavaScript side of page observation. Injected once per page as a
//  WKUserScript (document end, main frame + subframes); the Swift side then
//  calls `window.__gepetto.snapshot(...)` and friends through
//  `evaluateJavaScript`.
//
//  What it does:
//   - Walks the DOM (shadow roots and same-origin iframes included), finds
//     every interactive element, and gives each a stable `data-gep-ref`
//     attribute. The ref survives across snapshots as long as the element is
//     attached, so an index the model saw a step ago still means the same
//     thing after a scroll or a minor re-render.
//   - Builds the compact element list the model reads:
//       [12]<button>Sign in</button>
//     one line per element, nothing a small model has to parse.
//   - Draws / clears "set-of-marks" badges and a highlight ring on the page
//     itself, so what the model sees and what the user sees are the same.
//   - Reports element rectangles (viewport coordinates) so the host can
//     animate a cursor to them.
//   - Waits for the page to settle: DOM mutations quiet, no pending
//     navigation, fonts/images past their first paint.
//   - Finds and dismisses cookie / consent banners.
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
      var nextRef = 1;
      var refToElement = new Map();   // ref -> WeakRef(element)
      var lastIndexToRef = [];        // snapshot index -> ref
      var mutationCount = 0;
      var lastMutationAt = performance.now();

      // ---- Mutation tracking (for settle detection) ----------------------
      try {
        var mo = new MutationObserver(function (list) {
          // Ignore our own overlay changes.
          for (var i = 0; i < list.length; i++) {
            var t = list[i].target;
            if (t && t.closest && t.closest('#__gep_overlay')) { continue; }
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

      function isCovered(el, rect) {
        var doc = el.ownerDocument;
        var cx = Math.min(Math.max(rect.left + rect.width / 2, 0), (doc.defaultView.innerWidth || 1) - 1);
        var cy = Math.min(Math.max(rect.top + rect.height / 2, 0), (doc.defaultView.innerHeight || 1) - 1);
        var hit = doc.elementFromPoint(cx, cy);
        if (!hit) return false;
        if (hit === el || el.contains(hit) || hit.contains(el)) return false;
        // Labels and wrappers of inputs count as the input.
        if (hit.closest && (hit.closest('label') === el.closest('label')) && el.closest('label')) return false;
        return true;
      }

      function text(el, max) {
        var t = '';
        if (el.matches('input, textarea, select')) {
          t = el.getAttribute('aria-label') || el.placeholder || labelFor(el) || el.name || '';
        } else if (el.matches('img')) {
          t = el.alt || el.title || '';
        } else {
          t = el.getAttribute('aria-label') || el.innerText || el.textContent || el.title || '';
          if (!t && el.matches('input[type=submit], input[type=button]')) t = el.value || '';
        }
        t = (t || '').replace(/\s+/g, ' ').trim();
        if (max && t.length > max) t = t.slice(0, max - 1) + '…';
        return t;
      }

      function labelFor(el) {
        if (el.id) {
          var l = el.ownerDocument.querySelector('label[for="' + CSS.escape(el.id) + '"]');
          if (l) return (l.textContent || '').trim();
        }
        var p = el.closest('label');
        if (p) return (p.textContent || '').trim();
        var by = el.getAttribute('aria-labelledby');
        if (by) { var b = el.ownerDocument.getElementById(by); if (b) return (b.textContent || '').trim(); }
        var td = el.closest('td');
        if (td && td.previousElementSibling) return (td.previousElementSibling.textContent || '').trim();
        return '';
      }

      var INTERACTIVE = 'a[href], button, input:not([type=hidden]), select, textarea, summary, ' +
        '[role=button], [role=link], [role=checkbox], [role=radio], [role=tab], [role=menuitem], ' +
        '[role=option], [role=switch], [role=textbox], [role=combobox], [role=searchbox], ' +
        '[contenteditable=true], [onclick], [tabindex]:not([tabindex="-1"])';

      function isInteractive(el) {
        if (el.matches(INTERACTIVE)) return true;
        var cs = el.ownerDocument.defaultView.getComputedStyle(el);
        return cs.cursor === 'pointer' && el.children.length < 4;
      }

      function kind(el) {
        var tag = el.tagName.toLowerCase();
        if (tag === 'input') {
          var t = (el.type || 'text').toLowerCase();
          if (t === 'submit' || t === 'button' || t === 'image' || t === 'reset') return 'button';
          if (t === 'checkbox' || t === 'radio') return t;
          return 'input';
        }
        if (tag === 'textarea' || el.getAttribute('contenteditable') === 'true') return 'textarea';
        if (tag === 'select') return 'select';
        if (tag === 'a') return 'link';
        if (tag === 'button' || el.getAttribute('role') === 'button' || el.matches('[onclick]')) return 'button';
        var role = el.getAttribute('role');
        if (role) return role;
        return 'clickable';
      }

      function refFor(el) {
        var existing = el.getAttribute('data-gep-ref');
        if (existing) {
          var w = refToElement.get(existing);
          if (w && w.deref && w.deref() === el) return existing;
          if (w && w.el === el) return existing;
        }
        var ref = String(nextRef++);
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
            if (inView && isCovered(el, rect)) continue;
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
            entry.value = (e.value || '').slice(0, 60);
            entry.inputType = (e.type || '').toLowerCase();
            if (e.placeholder) entry.placeholder = e.placeholder.slice(0, 60);
            if (kd === 'select') {
              entry.options = Array.prototype.slice.call(e.options || [], 0, 12).map(function (o) { return (o.text || '').trim().slice(0, 40); });
            }
          }
          if (kd === 'checkbox' || kd === 'radio') entry.checked = !!e.checked;
          if (kd === 'link') entry.href = (e.href || '').slice(0, 200);
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

      // Visible text, viewport-first: the text of elements whose boxes touch the
      // viewport, in reading order; falls back to innerText when that is empty.
      function visibleText(max, viewportOnly) {
        var out = [];
        var total = 0;
        var walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT, {
          acceptNode: function (n) {
            var p = n.parentElement;
            if (!p) return NodeFilter.FILTER_REJECT;
            if (p.closest('script, style, noscript, template, #__gep_overlay')) return NodeFilter.FILTER_REJECT;
            var t = n.nodeValue.replace(/\s+/g, ' ').trim();
            if (!t) return NodeFilter.FILTER_REJECT;
            if (!isVisible(p)) return NodeFilter.FILTER_REJECT;
            if (viewportOnly) {
              var r = p.getBoundingClientRect();
              if (!inViewport(r, 40)) return NodeFilter.FILTER_REJECT;
            }
            return NodeFilter.FILTER_ACCEPT;
          }
        });
        var n;
        while ((n = walker.nextNode()) && total < max) {
          var t = n.nodeValue.replace(/\s+/g, ' ').trim();
          out.push(t); total += t.length + 1;
        }
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
          el.click();
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
          if (!prevented && el.form) {
            var btn = el.form.querySelector('input[type=submit], button[type=submit], button:not([type])');
            if (btn) btn.click(); else if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
          }
        }
        return { ok: true, value: (el.value !== undefined ? el.value : el.textContent || '').slice(0, 60), label: text(el, 40) };
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
        if (!!el.checked !== !!checked) el.click();
        return { ok: true, checked: !!el.checked };
      };

      NS.pressKey = function (key) {
        var el = document.activeElement || document.body;
        var map = { Enter: 13, Escape: 27, Tab: 9, Backspace: 8, ArrowDown: 40, ArrowUp: 38, ArrowLeft: 37, ArrowRight: 39, Space: 32 };
        var code = map[key] || 0;
        var opts = { bubbles: true, cancelable: true, key: key === 'Space' ? ' ' : key, code: key, keyCode: code, which: code };
        var prevented = !el.dispatchEvent(new KeyboardEvent('keydown', opts));
        el.dispatchEvent(new KeyboardEvent('keypress', opts));
        el.dispatchEvent(new KeyboardEvent('keyup', opts));
        if (key === 'Enter' && !prevented && el.form) {
          var btn = el.form.querySelector('input[type=submit], button[type=submit], button:not([type])');
          if (btn) btn.click(); else if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
        }
        if (key === 'Escape') { if (el.blur) el.blur(); }
        return { ok: true, target: el.tagName.toLowerCase() };
      };

      NS.scrollBy = function (dy) {
        var before = window.scrollY;
        window.scrollBy({ top: dy, left: 0, behavior: 'instant' });
        // Pages that scroll an inner container instead of the window.
        if (window.scrollY === before) {
          var candidates = document.querySelectorAll('main, [role=main], .scroll, [style*="overflow"], div');
          for (var i = 0; i < candidates.length; i++) {
            var c = candidates[i];
            var cs = getComputedStyle(c);
            if ((cs.overflowY === 'auto' || cs.overflowY === 'scroll') && c.scrollHeight > c.clientHeight + 10 && c.getBoundingClientRect().height > window.innerHeight * 0.4) {
              c.scrollBy({ top: dy, behavior: 'instant' });
              return { ok: true, y: c.scrollTop, container: true, atBottom: c.scrollTop + c.clientHeight >= c.scrollHeight - 2 };
            }
          }
        }
        var max = Math.max(document.body ? document.body.scrollHeight : 0, document.documentElement.scrollHeight) - window.innerHeight;
        return { ok: true, y: window.scrollY, container: false, atBottom: window.scrollY >= max - 2, atTop: window.scrollY <= 0 };
      };

      // ---- Settle / readiness --------------------------------------------
      NS.isSettled = function (quietMs) {
        quietMs = quietMs || 300;
        if (document.readyState !== 'complete' && document.readyState !== 'interactive') return false;
        return NS.quietMs() >= quietMs;
      };

      // ---- Cookie / consent banners -------------------------------------
      var CONSENT_TEXT = /^(accept( all)?( cookies)?|agree( and continue)?|i agree|allow all|got it|ok(ay)?|continue|close|reject all|only necessary|necessary only|decline|no thanks)$/i;
      NS.dismissConsent = function () {
        var roots = collectRoots(document);
        var picks = [];
        for (var r = 0; r < roots.length; r++) {
          var buttons = roots[r].querySelectorAll ? roots[r].querySelectorAll('button, a[href], [role=button], input[type=button], input[type=submit]') : [];
          for (var i = 0; i < buttons.length; i++) {
            var b = buttons[i];
            if (!isVisible(b)) continue;
            var t = text(b, 40);
            if (!CONSENT_TEXT.test(t)) continue;
            // Only inside something that looks like a banner / dialog.
            var host = b.closest('[id*=cookie i], [class*=cookie i], [id*=consent i], [class*=consent i], [aria-label*=cookie i], [role=dialog], [aria-modal=true], [class*=banner i], [id*=gdpr i], [class*=gdpr i]');
            if (!host) continue;
            picks.push({ el: b, t: t, accept: /accept|agree|allow|got it|ok/i.test(t) });
          }
        }
        if (!picks.length) return { dismissed: false };
        picks.sort(function (a, b) { return (b.accept ? 1 : 0) - (a.accept ? 1 : 0); });
        picks[0].el.click();
        return { dismissed: true, clicked: picks[0].t };
      };

      // ---- Human-needed detection ----------------------------------------
      NS.blockers = function () {
        var out = [];
        var html = document.documentElement.outerHTML.slice(0, 200000).toLowerCase();
        if (/recaptcha|hcaptcha|cf-turnstile|captcha|verify you are human|are you a robot|cf-challenge|challenge-platform/.test(html)) out.push('captcha');
        if (document.querySelector('input[type=password]') && isVisible(document.querySelector('input[type=password]'))) out.push('login');
        if (/\b(2fa|two-factor|verification code|one-time code|authenticator app)\b/.test((document.body && document.body.innerText || '').toLowerCase().slice(0, 20000))) out.push('two_factor');
        if (document.querySelector('input[autocomplete="cc-number"], input[name*="cardnumber" i], iframe[src*="stripe" i], iframe[name*="braintree" i]')) out.push('payment');
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
