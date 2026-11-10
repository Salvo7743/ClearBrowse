import Foundation

/// The script injected into every frame of every page.
///
/// tvOS never delivers touches to a web page, so the app drives pages from here: it turns the
/// cursor's position into mouse events, asks the app for a keyboard when a text field is clicked,
/// scrolls, keeps track of videos, and stands in for the Fullscreen API (which the engine can't
/// present on a TV) by telling the app which part of the page to magnify.
///
/// Commands from the app and messages between frames carry a random per-launch token that page
/// scripts never see, so a web page can't forge them.
enum PageScript {
    static func source(token: String) -> String {
        template.replacingOccurrences(of: "%TOKEN%", with: token)
    }

    private static let template = #"""
    (function () {
      'use strict';

      var TOKEN = '%TOKEN%';
      var KEY = '__cwb';
      var bridge = null;
      try { bridge = window.webkit.messageHandlers.cwb; } catch (e) {}
      if (!bridge) { return; }

      var isTop = window.top === window;
      var FRAME = Math.random().toString(36).slice(2) + Date.now().toString(36);

      function post(message) {
        try {
          message.token = TOKEN;
          message.frame = FRAME;
          message.page = String(location.href).slice(0, 2000);
          bridge.postMessage(message);
        } catch (e) {}
      }

      // ---------------------------------------------------------------- DOM helpers

      function parentOf(node) {
        if (!node) { return null; }
        if (node.parentElement) { return node.parentElement; }
        var root = node.getRootNode ? node.getRootNode() : null;
        return root && root.host ? root.host : null;
      }

      function ancestor(node, test, limit) {
        var depth = 0;
        while (node && node.nodeType === 1) {
          if (test(node)) { return node; }
          if (limit && ++depth >= limit) { return null; }
          node = parentOf(node);
        }
        return null;
      }

      function chain(node) {
        var out = [];
        while (node && node.nodeType === 1) { out.push(node); node = parentOf(node); }
        return out;
      }

      // The deepest element under a point, looking inside open shadow roots.
      function pick(doc, x, y) {
        var el = doc.elementFromPoint(x, y);
        var guard = 0;
        while (el && el.shadowRoot && guard++ < 12) {
          var inner = el.shadowRoot.elementFromPoint(x, y);
          if (!inner || inner === el) { break; }
          el = inner;
        }
        return el;
      }

      function viewportWidth() { return window.innerWidth || document.documentElement.clientWidth || 0; }
      function viewportHeight() { return window.innerHeight || document.documentElement.clientHeight || 0; }

      // ---------------------------------------------------------------- Frames

      function isFrame(el) { return !!el && (el.tagName === 'IFRAME' || el.tagName === 'FRAME'); }

      // The frame's window when it is same-origin (and so reachable directly), otherwise null.
      function innerWindow(frameEl) {
        try { return frameEl.contentDocument ? frameEl.contentWindow : null; } catch (e) { return null; }
      }

      function frameScale(frameEl, rect) {
        return {
          x: frameEl.offsetWidth ? (rect.width / frameEl.offsetWidth) || 1 : 1,
          y: frameEl.offsetHeight ? (rect.height / frameEl.offsetHeight) || 1 : 1
        };
      }

      function intoFrame(frameEl, x, y) {
        var rect = frameEl.getBoundingClientRect();
        var scale = frameScale(frameEl, rect);
        return { x: (x - rect.left) / scale.x - frameEl.clientLeft, y: (y - rect.top) / scale.y - frameEl.clientTop };
      }

      function outOfFrame(frameEl, inner) {
        var rect = frameEl.getBoundingClientRect();
        var scale = frameScale(frameEl, rect);
        return {
          x: rect.left + (inner.x + frameEl.clientLeft) * scale.x,
          y: rect.top + (inner.y + frameEl.clientTop) * scale.y,
          w: inner.w * scale.x,
          h: inner.h * scale.y
        };
      }

      function sendDown(frameEl, message) {
        try { message[KEY] = TOKEN; frameEl.contentWindow.postMessage(message, '*'); } catch (e) {}
      }

      function sendUp(message) {
        try { message[KEY] = TOKEN; window.parent.postMessage(message, '*'); } catch (e) {}
      }

      function frameFor(source) {
        var frames = document.querySelectorAll('iframe, frame');
        for (var i = 0; i < frames.length; i++) {
          try { if (frames[i].contentWindow === source) { return frames[i]; } } catch (e) {}
        }
        return null;
      }

      // ---------------------------------------------------------------- Mouse events

      function fire(w, el, type, x, y, options) {
        options = options || {};
        var init = {
          bubbles: options.bubbles !== false, cancelable: options.bubbles !== false, composed: true, view: w,
          detail: options.detail || 0, clientX: x, clientY: y, screenX: x, screenY: y,
          button: 0, buttons: options.buttons || 0, relatedTarget: options.related || null
        };
        try {
          var event;
          if (type.indexOf('pointer') === 0 && w.PointerEvent) {
            init.pointerId = 1;
            init.pointerType = 'mouse';
            init.isPrimary = true;
            event = new w.PointerEvent(type, init);
          } else {
            event = new w.MouseEvent(type, init);
          }
          return el.dispatchEvent(event);
        } catch (e) {
          return true;
        }
      }

      var hovered = null;
      var hoveredWindow = null;

      function setHover(w, el, x, y) {
        if (hovered === el) { return; }
        var previous = hovered && hovered.isConnected ? hovered : null;
        var previousWindow = hoveredWindow || w;
        hovered = el;
        hoveredWindow = el ? w : null;

        var leaving = previous ? chain(previous) : [];
        var entering = el ? chain(el) : [];
        if (previous) {
          if (isFrame(previous) && !innerWindow(previous)) { sendDown(previous, { op: 'leave' }); }
          fire(previousWindow, previous, 'pointerout', x, y, { related: el });
          fire(previousWindow, previous, 'mouseout', x, y, { related: el });
          for (var i = 0; i < leaving.length; i++) {
            if (entering.indexOf(leaving[i]) === -1) {
              fire(previousWindow, leaving[i], 'mouseleave', x, y, { bubbles: false, related: el });
            }
          }
        }
        if (el) {
          fire(w, el, 'pointerover', x, y, { related: previous });
          fire(w, el, 'mouseover', x, y, { related: previous });
          for (var j = entering.length - 1; j >= 0; j--) {
            if (leaving.indexOf(entering[j]) === -1) {
              fire(w, entering[j], 'mouseenter', x, y, { bubbles: false, related: previous });
            }
          }
        }
      }

      var TEXT_TYPES = {
        text: 1, search: 1, email: 1, url: 1, tel: 1, number: 1, password: 1,
        date: 1, time: 1, 'datetime-local': 1, month: 1, week: 1
      };

      // The text field or editable region that a click on `el` would put the caret in.
      function editableOf(el) {
        var found = ancestor(el, function (node) {
          if (node.tagName === 'TEXTAREA') { return !node.disabled && !node.readOnly; }
          if (node.tagName === 'INPUT') { return !!TEXT_TYPES[node.type] && !node.disabled && !node.readOnly; }
          return node.isContentEditable === true;
        }, 8);
        if (found && found.tagName !== 'INPUT' && found.tagName !== 'TEXTAREA') {
          var host = found;
          var up = parentOf(host);
          while (up && up.isContentEditable === true) { host = up; up = parentOf(host); }
          return host;
        }
        return found;
      }

      function cursorKind(w, el) {
        if (editableOf(el)) { return 'text'; }
        var style = null;
        try { style = w.getComputedStyle(el); } catch (e) {}
        if (style && style.cursor === 'pointer') { return 'pointer'; }
        var hit = ancestor(el, function (node) {
          var tag = node.tagName;
          if (tag === 'A') { return node.hasAttribute('href'); }
          if (tag === 'BUTTON' || tag === 'SELECT' || tag === 'SUMMARY' || tag === 'LABEL' || tag === 'VIDEO' || tag === 'INPUT') { return true; }
          var role = node.getAttribute('role');
          return role === 'button' || role === 'link' || role === 'tab' || role === 'menuitem';
        }, 5);
        return hit ? 'pointer' : 'default';
      }

      function hoverAt(w, x, y) {
        var el = pick(w.document, x, y);
        if (!el) { setHover(w, null, x, y); return 'default'; }
        if (isFrame(el)) {
          var point = intoFrame(el, x, y);
          var inner = innerWindow(el);
          if (inner) { return hoverAt(inner, point.x, point.y); }
          setHover(w, el, x, y);
          sendDown(el, { op: 'hover', x: point.x, y: point.y });
          return 'default';
        }
        setHover(w, el, x, y);
        fire(w, el, 'pointermove', x, y);
        fire(w, el, 'mousemove', x, y);
        return cursorKind(w, el);
      }

      // ---------------------------------------------------------------- Clicking

      function setNativeValue(w, el, value) {
        var proto = el.tagName === 'TEXTAREA' ? w.HTMLTextAreaElement.prototype : w.HTMLInputElement.prototype;
        var descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
        if (descriptor && descriptor.set) { descriptor.set.call(el, value); } else { el.value = value; }
      }

      function setRange(w, input, x) {
        var rect = input.getBoundingClientRect();
        if (!rect.width) { return; }
        var min = parseFloat(input.min);
        var max = parseFloat(input.max);
        if (isNaN(min)) { min = 0; }
        if (isNaN(max)) { max = 100; }
        var fraction = Math.min(1, Math.max(0, (x - rect.left) / rect.width));
        setNativeValue(w, input, String(min + (max - min) * fraction));
        input.dispatchEvent(new w.Event('input', { bubbles: true, composed: true }));
        input.dispatchEvent(new w.Event('change', { bubbles: true }));
      }

      function togglePlayback(video) {
        if (video.paused || video.ended) {
          var started = video.play();
          if (started && started.catch) { started.catch(function () {}); }
        } else {
          video.pause();
        }
      }

      function clickAt(w, x, y) {
        var el = pick(w.document, x, y);
        if (!el) { return; }
        if (isFrame(el)) {
          var point = intoFrame(el, x, y);
          var inner = innerWindow(el);
          if (inner) { clickAt(inner, point.x, point.y); } else { sendDown(el, { op: 'click', x: point.x, y: point.y }); }
          return;
        }

        setHover(w, el, x, y);
        fire(w, el, 'pointermove', x, y);
        fire(w, el, 'mousemove', x, y);
        fire(w, el, 'pointerdown', x, y, { buttons: 1, detail: 1 });
        var focusAllowed = fire(w, el, 'mousedown', x, y, { buttons: 1, detail: 1 });

        var editable = editableOf(el);
        var select = ancestor(el, function (node) { return node.tagName === 'SELECT' && !node.disabled; }, 3);
        if (focusAllowed) {
          var target = editable || select || ancestor(el, function (node) {
            return node.tabIndex >= 0 && node.tagName !== 'BODY' && node.tagName !== 'HTML';
          }, 8);
          try {
            var active = w.document.activeElement;
            if (target) { target.focus({ preventScroll: true }); }
            else if (active && active !== w.document.body && active.blur) { active.blur(); }
          } catch (e) {}
        }

        fire(w, el, 'pointerup', x, y, { detail: 1 });
        fire(w, el, 'mouseup', x, y, { detail: 1 });

        var video = el.tagName === 'VIDEO' ? el : null;
        var wasPaused = video ? video.paused : false;
        if (el.tagName === 'INPUT' && el.type === 'range' && !el.disabled) { setRange(w, el, x); }

        var clickAllowed = fire(w, el, 'click', x, y, { detail: 1 });

        // The engine's own video controls can't be reached by synthetic clicks, so a click on a
        // bare <video controls> toggles playback unless the page already did.
        if (video && video.controls && clickAllowed && video.paused === wasPaused) { togglePlayback(video); }

        if (select) { requestSelect(select); }
        else if (editable) { requestEdit(editable); }
      }

      // ---------------------------------------------------------------- Text fields and menus

      var editTarget = null;
      var selectTarget = null;

      function labelFor(el) {
        var text = el.getAttribute('placeholder') || el.getAttribute('aria-label') || el.getAttribute('title') || '';
        if (!text && el.labels && el.labels.length) { text = el.labels[0].innerText || ''; }
        if (!text) { text = el.getAttribute('name') || ''; }
        return String(text).replace(/\s+/g, ' ').trim().slice(0, 80);
      }

      function requestEdit(el) {
        editTarget = el;
        var isField = el.tagName === 'INPUT' || el.tagName === 'TEXTAREA';
        var secure = isField && el.type === 'password';
        var value = secure ? '' : String(isField ? el.value : (el.innerText || ''));
        post({
          type: 'edit',
          value: value.slice(0, 4000),
          secure: secure,
          kind: isField ? String(el.type || 'text') : 'text',
          label: labelFor(el)
        });
      }

      function pressEnter(w, el) {
        var allowed = true;
        ['keydown', 'keypress', 'keyup'].forEach(function (type) {
          var event;
          try {
            event = new w.KeyboardEvent(type, {
              bubbles: true, cancelable: true, composed: true, view: w,
              key: 'Enter', code: 'Enter', keyCode: 13, which: 13, charCode: type === 'keypress' ? 13 : 0
            });
          } catch (e) { return; }
          if (!el.dispatchEvent(event) && type !== 'keyup') { allowed = false; }
        });
        if (allowed && el.tagName === 'INPUT' && el.form) {
          try {
            if (el.form.requestSubmit) { el.form.requestSubmit(); } else { el.form.submit(); }
          } catch (e) {}
        }
      }

      function applyText(text, submit) {
        var el = editTarget;
        if (!el || !el.isConnected) { return; }
        var doc = el.ownerDocument;
        var w = doc.defaultView || window;
        var isField = el.tagName === 'INPUT' || el.tagName === 'TEXTAREA';
        try { el.focus({ preventScroll: true }); } catch (e) {}

        // insertText goes through the engine's editing code, so frameworks see ordinary input.
        var done = false;
        try {
          if (isField && el.select) { el.select(); } else { doc.execCommand('selectAll', false, null); }
          done = text.length ? doc.execCommand('insertText', false, text) : doc.execCommand('delete', false, null);
        } catch (e) {}

        if (isField) {
          if (!done || el.value !== text) {
            setNativeValue(w, el, text);
            el.dispatchEvent(new w.Event('input', { bubbles: true, composed: true }));
          }
          el.dispatchEvent(new w.Event('change', { bubbles: true }));
        } else if (!done) {
          el.textContent = text;
          el.dispatchEvent(new w.Event('input', { bubbles: true, composed: true }));
        }
        if (submit) { pressEnter(w, el); }
      }

      function requestSelect(el) {
        selectTarget = el;
        var options = [];
        for (var i = 0; i < el.options.length && options.length < 150; i++) {
          var option = el.options[i];
          var group = option.parentElement && option.parentElement.tagName === 'OPTGROUP' ? option.parentElement : null;
          if (option.disabled || option.hidden || (group && group.disabled)) { continue; }
          options.push({
            index: i,
            label: String(option.label || option.text || '').replace(/\s+/g, ' ').trim().slice(0, 80),
            selected: !!option.selected
          });
        }
        post({ type: 'select', options: options, label: labelFor(el) });
      }

      function applySelection(index) {
        var el = selectTarget;
        if (!el || !el.isConnected) { return; }
        var w = el.ownerDocument.defaultView || window;
        el.selectedIndex = index;
        el.dispatchEvent(new w.Event('input', { bubbles: true, composed: true }));
        el.dispatchEvent(new w.Event('change', { bubbles: true }));
      }

      // ---------------------------------------------------------------- Scrolling

      function canScroll(w, node, dx, dy) {
        var style;
        try { style = w.getComputedStyle(node); } catch (e) { return false; }
        var scrollable = /auto|scroll|overlay/;
        if (dy && scrollable.test(style.overflowY) && node.scrollHeight > node.clientHeight + 1) {
          if (dy > 0 ? node.scrollTop + node.clientHeight < node.scrollHeight - 1 : node.scrollTop > 0) { return true; }
        }
        if (dx && scrollable.test(style.overflowX) && node.scrollWidth > node.clientWidth + 1) {
          if (dx > 0 ? node.scrollLeft + node.clientWidth < node.scrollWidth - 1 : node.scrollLeft > 0) { return true; }
        }
        return false;
      }

      function scrollTarget(target, dx, dy) {
        try { target.scrollBy({ left: dx, top: dy, behavior: 'instant' }); } catch (e) { target.scrollBy(dx, dy); }
      }

      // Scrolls the nearest scrollable ancestor of `start`, then the page. False if nothing moved.
      function scrollFrom(w, start, dx, dy) {
        var doc = w.document;
        var node = start;
        while (node && node.nodeType === 1 && node !== doc.documentElement && node !== doc.body) {
          if (canScroll(w, node, dx, dy)) { scrollTarget(node, dx, dy); return true; }
          node = parentOf(node);
        }
        var beforeX = w.scrollX;
        var beforeY = w.scrollY;
        scrollTarget(w, dx, dy);
        if (w.scrollX !== beforeX || w.scrollY !== beforeY) { return true; }
        if (w !== window) {
          var frameEl = null;
          try { frameEl = w.frameElement; } catch (e) {}
          if (frameEl && frameEl.ownerDocument && frameEl.ownerDocument.defaultView) {
            return scrollFrom(frameEl.ownerDocument.defaultView, parentOf(frameEl), dx, dy);
          }
        }
        return false;
      }

      function scrollAt(w, x, y, dx, dy) {
        var el = pick(w.document, x, y);
        if (isFrame(el)) {
          var point = intoFrame(el, x, y);
          var inner = innerWindow(el);
          if (inner) { return scrollAt(inner, point.x, point.y, dx, dy); }
          sendDown(el, { op: 'scroll', x: point.x, y: point.y, dx: dx, dy: dy });
          return true;
        }
        return scrollFrom(w, el, dx, dy);
      }

      // ---------------------------------------------------------------- Videos

      var tracked = [];
      var reportTimer = null;
      var lastReport = '';

      function isPlaying(video) { return !video.paused && !video.ended; }

      function allVideos() {
        var list = Array.prototype.slice.call(document.querySelectorAll('video'));
        tracked = tracked.filter(function (video) { return video.isConnected; });
        tracked.forEach(function (video) { if (list.indexOf(video) === -1) { list.push(video); } });
        return list;
      }

      // The video the viewer most likely means: playing with sound first, then by size.
      function bestVideo() {
        var best = null;
        var bestScore = 0;
        var vw = viewportWidth();
        var vh = viewportHeight();
        allVideos().forEach(function (video) {
          var rect = video.getBoundingClientRect();
          if (rect.width < 120 || rect.height < 68) { return; }
          var score = rect.width * rect.height;
          var onScreen = Math.min(rect.right, vw) > Math.max(rect.left, 0) && Math.min(rect.bottom, vh) > Math.max(rect.top, 0);
          if (onScreen) { score *= 2; }
          if (isPlaying(video)) { score *= (video.muted || video.volume === 0) ? 4 : 50; }
          if (score > bestScore) { best = video; bestScore = score; }
        });
        return best;
      }

      function directSource(video) {
        var source = video ? (video.currentSrc || video.src || '') : '';
        return /^https?:/i.test(source) ? source : '';
      }

      function reportVideo() {
        if (reportTimer) { return; }
        reportTimer = setTimeout(function () {
          reportTimer = null;
          var video = bestVideo();
          var playing = !!video && isPlaying(video);
          var state = {
            type: 'video',
            has: !!video,
            playing: playing,
            audible: playing && !video.muted && video.volume > 0,
            src: directSource(video)
          };
          var key = [state.has, state.playing, state.audible, state.src].join('|');
          if (key === lastReport) { return; }
          lastReport = key;
          post(state);
        }, 150);
      }

      var MEDIA_EVENTS = ['play', 'playing', 'pause', 'ended', 'emptied', 'loadedmetadata', 'volumechange'];

      function track(video) {
        if (tracked.indexOf(video) !== -1) { return; }
        tracked.push(video);
        // Media events don't cross shadow roots, so listen on the element as well as the document.
        MEDIA_EVENTS.forEach(function (type) { video.addEventListener(type, reportVideo); });
      }

      MEDIA_EVENTS.forEach(function (type) {
        document.addEventListener(type, function (event) {
          var target = event.target;
          if (target && target.tagName === 'VIDEO') { track(target); reportVideo(); }
        }, true);
      });

      var nativePlay = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () {
        if (this.tagName === 'VIDEO') { track(this); reportVideo(); }
        return nativePlay.apply(this, arguments);
      };

      document.addEventListener('DOMContentLoaded', reportVideo);
      window.addEventListener('load', reportVideo);
      window.addEventListener('pagehide', function () {
        lastReport = '';
        post({ type: 'video', has: false, playing: false, audible: false, src: '' });
        if (theaterElement) { leaveTheater(); }
      });

      // Adaptive players fetch their playlists with script; note them so the stream can also be
      // opened in the Apple TV player.
      var seenStreams = {};
      try {
        new PerformanceObserver(function (list) {
          list.getEntries().forEach(function (entry) {
            var name = entry.name;
            if (typeof name !== 'string' || name.length > 2000 || seenStreams[name]) { return; }
            if (!/^https?:/i.test(name) || !/\.m3u8(\?|#|$)/i.test(name)) { return; }
            seenStreams[name] = true;
            post({ type: 'stream', url: name });
          });
        }).observe({ type: 'resource', buffered: true });
      } catch (e) {}

      // ---------------------------------------------------------------- Full screen ("theater")

      var theaterElement = null;
      var theaterTimer = null;
      var theaterKey = '';
      var fullscreenElement = null;
      var styled = [];

      var FULLSCREEN_STYLE = {
        'position': 'fixed', 'top': '0', 'left': '0', 'right': '0', 'bottom': '0',
        'width': '100vw', 'height': '100vh', 'max-width': 'none', 'max-height': 'none',
        'min-width': '0', 'min-height': '0', 'margin': '0', 'box-sizing': 'border-box',
        'z-index': '2147483647', 'transform': 'none', 'object-fit': 'contain', 'background-color': '#000'
      };
      // What browsers apply to the ancestors of a full-screen element so nothing clips or covers it.
      var ANCESTOR_STYLE = {
        'z-index': 'auto', 'opacity': '1', 'transform': 'none', 'filter': 'none', '-webkit-filter': 'none',
        'perspective': 'none', '-webkit-mask': 'none', 'clip-path': 'none', 'contain': 'none',
        'will-change': 'auto', 'transition': 'none'
      };

      function applyStyle(el, rules) {
        for (var name in rules) {
          try {
            styled.push({ el: el, name: name, value: el.style.getPropertyValue(name), priority: el.style.getPropertyPriority(name) });
            el.style.setProperty(name, rules[name], 'important');
          } catch (e) {}
        }
      }

      function restoreStyles() {
        for (var i = styled.length - 1; i >= 0; i--) {
          var entry = styled[i];
          try {
            if (entry.value) { entry.el.style.setProperty(entry.name, entry.value, entry.priority); }
            else { entry.el.style.removeProperty(entry.name); }
          } catch (e) {}
        }
        styled = [];
      }

      // Makes `el` fill its window the way a real full-screen request would.
      function expand(el) {
        applyStyle(el, FULLSCREEN_STYLE);
        var node = parentOf(el);
        while (node && node.nodeType === 1) {
          applyStyle(node, ANCESTOR_STYLE);
          node = parentOf(node);
        }
      }

      function centerInView(el) {
        try { el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); }
        catch (e) { try { el.scrollIntoView(); } catch (e2) {} }
      }

      // Reports where the theater element is. In a frame the rectangle is passed up, and each
      // parent adds its own offset until the top page hands it to the app.
      function reportRect(rect) {
        if (!isTop) { sendUp({ op: 'rect', x: rect.x, y: rect.y, w: rect.w, h: rect.h }); return; }
        var vw = viewportWidth();
        var vh = viewportHeight();
        if (!vw || !vh) { return; }
        var key = [rect.x, rect.y, rect.w, rect.h, vw, vh].map(function (n) { return Math.round(n); }).join(',');
        if (key === theaterKey) { return; }
        theaterKey = key;
        post({ type: 'theater', on: true, x: rect.x / vw, y: rect.y / vh, w: rect.w / vw, h: rect.h / vh });
      }

      function measure() {
        var el = theaterElement;
        if (!el || !el.isConnected) { leaveTheater(); return; }
        var box = el.getBoundingClientRect();
        var rect = { x: box.left, y: box.top, w: box.width, h: box.height };
        if (rect.w < 2 || rect.h < 2) { return; }
        if (el.tagName === 'VIDEO' && el.videoWidth > 0 && el.videoHeight > 0) {
          // Zoom to the picture, not to the black bars inside the element.
          var fit = '';
          try { fit = getComputedStyle(el).objectFit; } catch (e) {}
          if (fit === 'contain' || fit === 'scale-down' || fit === '') {
            var aspect = el.videoWidth / el.videoHeight;
            if (rect.w / rect.h > aspect) {
              var width = rect.h * aspect;
              rect.x += (rect.w - width) / 2;
              rect.w = width;
            } else {
              var height = rect.w / aspect;
              rect.y += (rect.h - height) / 2;
              rect.h = height;
            }
          }
        }
        reportRect(rect);
      }

      function enterTheater(el, expandElement) {
        if (!el || !el.isConnected) { return false; }
        if (theaterElement) { leaveTheater(); }
        theaterElement = el;
        theaterKey = '';
        if (expandElement) { expand(el); } else { centerInView(el); }
        post({ type: 'theaterOwner' });
        if (!isTop) { sendUp({ op: 'fs', on: true, expand: !!expandElement }); }
        measure();
        theaterTimer = setInterval(measure, 350);
        return true;
      }

      function leaveTheater() {
        if (!theaterElement) { return; }
        theaterElement = null;
        theaterKey = '';
        if (theaterTimer) { clearInterval(theaterTimer); theaterTimer = null; }
        restoreStyles();
        if (fullscreenElement) {
          var was = fullscreenElement;
          fullscreenElement = null;
          announceFullscreen(was, false);
        }
        if (!isTop) { sendUp({ op: 'fs', on: false }); }
        post({ type: 'theater', on: false });
      }

      // A frame below this one entered or left full screen: give its <iframe> the same treatment.
      function childFullscreen(frameEl, on, expandFrame) {
        theaterKey = '';
        restoreStyles();
        if (on) {
          if (expandFrame) { expand(frameEl); } else { centerInView(frameEl); }
        }
        if (!isTop) { sendUp({ op: 'fs', on: !!on, expand: !!expandFrame }); }
      }

      function theaterVideo() {
        var el = theaterElement;
        if (el && el.isConnected) {
          if (el.tagName === 'VIDEO') { return el; }
          var inside = el.querySelector('video');
          if (inside) { return inside; }
        }
        return bestVideo();
      }

      function media(command, value) {
        var video = theaterVideo();
        if (!video) { return false; }
        try {
          if (command === 'toggle') { togglePlayback(video); }
          else if (command === 'pause') { video.pause(); }
          else if (command === 'seek') {
            var limit = isFinite(video.duration) ? Math.max(0, video.duration - 0.5) : Infinity;
            video.currentTime = Math.max(0, Math.min(limit, video.currentTime + value));
          }
          else if (command === 'seekTo') { video.currentTime = Math.max(0, value); }
        } catch (e) {}
        return true;
      }

      function videoInfo() {
        var video = theaterVideo();
        if (!video) { return null; }
        return {
          src: directSource(video),
          time: video.currentTime || 0,
          live: !isFinite(video.duration),
          paused: !!video.paused
        };
      }

      // ---------------------------------------------------------------- Fullscreen API stand-in

      function announceFullscreen(el, entering) {
        var target = el && el.isConnected ? el : document;
        ['fullscreenchange', 'webkitfullscreenchange'].forEach(function (type) {
          try { target.dispatchEvent(new Event(type, { bubbles: true, composed: true })); } catch (e) {}
        });
        if (el && el.tagName === 'VIDEO') {
          try { el.dispatchEvent(new Event(entering ? 'webkitbeginfullscreen' : 'webkitendfullscreen')); } catch (e) {}
        }
      }

      function requestFullscreen() {
        var el = this;
        if (!el || el.nodeType !== 1) { return Promise.reject(new TypeError('Not an element')); }
        if (el === document.documentElement || el === document.body) {
          // The page already fills the screen.
          fullscreenElement = el;
          announceFullscreen(el, true);
          return Promise.resolve();
        }
        if (theaterElement) { leaveTheater(); }
        fullscreenElement = el;
        if (!enterTheater(el, true)) { fullscreenElement = null; return Promise.reject(new TypeError('Element is not in the document')); }
        announceFullscreen(el, true);
        return Promise.resolve();
      }

      function exitFullscreen() {
        if (theaterElement) {
          leaveTheater();
        } else if (fullscreenElement) {
          var was = fullscreenElement;
          fullscreenElement = null;
          announceFullscreen(was, false);
        }
        return Promise.resolve();
      }

      function define(target, name, value) {
        try { Object.defineProperty(target, name, { configurable: true, enumerable: true, writable: true, value: value }); } catch (e) {}
      }

      function defineGetter(target, name, getter) {
        try { Object.defineProperty(target, name, { configurable: true, enumerable: true, get: getter }); } catch (e) {}
      }

      ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen'].forEach(function (name) {
        define(Element.prototype, name, requestFullscreen);
      });
      ['exitFullscreen', 'webkitExitFullscreen', 'webkitCancelFullScreen'].forEach(function (name) {
        define(Document.prototype, name, exitFullscreen);
      });
      ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement'].forEach(function (name) {
        defineGetter(Document.prototype, name, function () { return fullscreenElement; });
      });
      ['fullscreenEnabled', 'webkitFullscreenEnabled'].forEach(function (name) {
        defineGetter(Document.prototype, name, function () { return true; });
      });
      ['fullscreen', 'webkitIsFullScreen'].forEach(function (name) {
        defineGetter(Document.prototype, name, function () { return !!fullscreenElement; });
      });

      if (window.HTMLVideoElement) {
        var videoProto = HTMLVideoElement.prototype;
        ['webkitEnterFullscreen', 'webkitEnterFullScreen'].forEach(function (name) {
          define(videoProto, name, function () { requestFullscreen.call(this); });
        });
        ['webkitExitFullscreen', 'webkitExitFullScreen'].forEach(function (name) {
          define(videoProto, name, function () { exitFullscreen(); });
        });
        defineGetter(videoProto, 'webkitSupportsFullscreen', function () { return true; });
        defineGetter(videoProto, 'webkitDisplayingFullscreen', function () { return fullscreenElement === this; });
        defineGetter(videoProto, 'webkitPresentationMode', function () { return fullscreenElement === this ? 'fullscreen' : 'inline'; });
        define(videoProto, 'webkitSupportsPresentationMode', function (mode) { return mode === 'fullscreen' || mode === 'inline'; });
        define(videoProto, 'webkitSetPresentationMode', function (mode) {
          if (mode === 'fullscreen') { requestFullscreen.call(this); }
          else if (fullscreenElement === this) { exitFullscreen(); }
        });
      }

      // ---------------------------------------------------------------- Messages between frames

      window.addEventListener('message', function (event) {
        var data = event.data;
        if (!data || typeof data !== 'object' || data[KEY] !== TOKEN) { return; }
        // Keep the token away from the page's own listeners.
        event.stopImmediatePropagation();

        if (!isTop && event.source === window.parent) {
          if (data.op === 'click') { clickAt(window, data.x, data.y); }
          else if (data.op === 'hover') { hoverAt(window, data.x, data.y); }
          else if (data.op === 'leave') { setHover(window, null, 0, 0); }
          else if (data.op === 'scroll') {
            if (!scrollAt(window, data.x, data.y, data.dx, data.dy)) { sendUp({ op: 'scrollup', dx: data.dx, dy: data.dy }); }
          }
          return;
        }

        var frameEl = frameFor(event.source);
        if (!frameEl) { return; }
        if (data.op === 'rect') {
          reportRect(outOfFrame(frameEl, data));
        } else if (data.op === 'scrollup') {
          if (!scrollFrom(window, parentOf(frameEl), data.dx, data.dy) && !isTop) {
            sendUp({ op: 'scrollup', dx: data.dx, dy: data.dy });
          }
        } else if (data.op === 'fs') {
          childFullscreen(frameEl, data.on, data.expand);
        }
      }, true);

      // ---------------------------------------------------------------- Commands from the app

      function command(token, op, a, b, c, d) {
        if (token !== TOKEN) { return undefined; }
        var vw = viewportWidth();
        var vh = viewportHeight();
        switch (op) {
          case 'click': clickAt(window, a * vw, b * vh); return true;
          case 'hover': return hoverAt(window, a * vw, b * vh);
          case 'leave': setHover(window, null, 0, 0); return true;
          case 'scroll': return scrollAt(window, a * vw, b * vh, c * vw, d * vh);
          case 'setText': applyText(String(a), !!b); return true;
          case 'setSelected': applySelection(a); return true;
          case 'theater':
            if (a) { return enterTheater(bestVideo(), false); }
            leaveTheater();
            return true;
          case 'media': return media(a, b);
          case 'videoInfo': return videoInfo();
        }
        return undefined;
      }

      try {
        Object.defineProperty(window, KEY, { value: command, configurable: false, enumerable: false, writable: false });
      } catch (e) {}
    })();
    """#
}
