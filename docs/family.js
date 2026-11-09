/* site-kit v1.0.3 — generated from github.com/turlamai/site-kit; do not edit per-site. */
/* ============================================================
   site-kit family.js — shared engine for jrtx.site family sites
   Single source of truth: github.com/turlamai/site-kit
   Three engines, zero dependencies:
     1. Theme   — follow system, manual override persisted per-site
     2. I18N    — follow browser locale, manual override persisted,
                  dictionaries supplied by the page (zh is canonical)
     3. Download— robust platform detection + release-asset resolver

   Page contract (see template/index.html):
     <html data-kit-id="<site-id>">
     <script type="application/json" id="kit-i18n">{ "zh": {...}, "en": {...} }</script>
     <script type="application/json" id="kit-download">{...}</script>   (optional)
     <script src="family.js" defer></script>
   ============================================================ */
(function () {
    'use strict';

    var docEl = document.documentElement;
    var siteId = docEl.dataset.kitId || 'site';
    // Per-site storage keys follow the site id; a site may carry forward its
    // historical keys via data-kit-theme-key / data-kit-lang-key.
    var THEME_KEY = docEl.dataset.kitThemeKey || siteId + '-theme';
    var LANG_KEY = docEl.dataset.kitLangKey || siteId + '-lang-override-v2';

    function readJSON(id) {
        var el = document.getElementById(id);
        if (!el) return null;
        try { return JSON.parse(el.textContent); } catch (e) { return null; }
    }
    function storageGet(key) {
        try { return localStorage.getItem(key); } catch (e) { return null; }
    }
    function storageSet(key, value) {
        try { localStorage.setItem(key, value); } catch (e) { /* private mode */ }
    }

    /* ================= 1. Theme ================= */
    var Theme = (function () {
        var systemDark = window.matchMedia
            && window.matchMedia('(prefers-color-scheme: dark)').matches;

        function current() {
            return docEl.dataset.theme === 'dark' ? 'dark' : 'light';
        }
        function apply(theme) {
            docEl.dataset.theme = theme;
            var btn = document.querySelector('.kit-theme-toggle');
            if (btn) {
                btn.setAttribute('aria-pressed', theme === 'dark' ? 'true' : 'false');
                btn.setAttribute('title', theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme');
            }
        }
        function toggle() {
            var next = current() === 'dark' ? 'light' : 'dark';
            storageSet(THEME_KEY, next);
            apply(next);
        }
        function bind() {
            apply(docEl.dataset.theme === 'dark' ? 'dark' : 'light');
            var btn = document.querySelector('.kit-theme-toggle');
            if (btn) btn.addEventListener('click', toggle);
            // System scheme changes only matter when the user has not chosen.
            if (window.matchMedia) {
                var mq = window.matchMedia('(prefers-color-scheme: dark)');
                var onSystem = function (e) {
                    if (!storageGet(THEME_KEY)) apply(e.matches ? 'dark' : 'light');
                };
                if (mq.addEventListener) mq.addEventListener('change', onSystem);
                else if (mq.addListener) mq.addListener(onSystem);
            }
        }
        return { bind: bind, toggle: toggle, apply: apply };
    })();

    /* ================= 2. I18N ================= */
    var I18N = (function () {
        var dicts = readJSON('kit-i18n') || { zh: {}, en: {} };
        // Pages without a dictionary keep their own i18n machinery; the
        // engine must stay fully inert so it never clobbers their text.
        var hasDict = document.getElementById('kit-i18n') !== null;
        var lang = null;

        function detect() {
            var override = storageGet(LANG_KEY);
            if (override === 'zh' || override === 'en') return override;
            var nav = (navigator.language || navigator.userLanguage || 'zh').toLowerCase();
            return nav.indexOf('zh') === 0 ? 'zh' : 'en';
        }
        function t(key) {
            var d = dicts[lang] || {};
            var v = d[key];
            if (v === undefined) v = (dicts.en || {})[key];
            if (v === undefined) v = (dicts.zh || {})[key];
            return v === undefined ? key : v;
        }
        function apply() {
            if (!hasDict) return;
            document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
            // Per-language document title and description (dict key "__meta__").
            var meta = dicts.__meta__ || null;
            if (meta) {
                var m = meta[lang];
                if (m) {
                    if (m.title) document.title = m.title;
                    if (m.description) {
                        var md = document.querySelector('meta[name="description"]');
                        if (md) md.setAttribute('content', m.description);
                    }
                }
            }
            // data-lang-block="zh|en": show only in that language.
            var blocks = document.querySelectorAll('[data-lang-block]');
            for (var b = 0; b < blocks.length; b++) {
                var want = blocks[b].getAttribute('data-lang-block') === lang;
                if (want) blocks[b].removeAttribute('hidden');
                else blocks[b].setAttribute('hidden', '');
            }
            // data-en-href / data-zh-href: per-language link targets.
            var hrefs = document.querySelectorAll('[data-en-href],[data-zh-href]');
            for (var h = 0; h < hrefs.length; h++) {
                var v = hrefs[h].getAttribute('data-' + lang + '-href');
                if (v) hrefs[h].setAttribute('href', v);
            }
            var nodes = document.querySelectorAll('[data-i18n]');
            for (var i = 0; i < nodes.length; i++) {
                var value = t(nodes[i].getAttribute('data-i18n'));
                nodes[i].textContent = value;
            }
            var phNodes = document.querySelectorAll('[data-i18n-placeholder]');
            for (var q = 0; q < phNodes.length; q++) {
                var pv = t(phNodes[q].getAttribute('data-i18n-placeholder'));
                if (pv) phNodes[q].setAttribute('placeholder', pv);
            }
            var attrNodes = document.querySelectorAll('[data-i18n-attr]');
            for (var j = 0; j < attrNodes.length; j++) {
                var attrs = (attrNodes[j].getAttribute('data-i18n-attr') || '').split(',');
                for (var k = 0; k < attrs.length; k++) {
                    var name = attrs[k].trim();
                    if (!name) continue;
                    var v = t(attrNodes[j].getAttribute('data-i18n-key') || attrNodes[j].getAttribute('data-i18n') || '');
                    if (v) attrNodes[j].setAttribute(name, v);
                }
            }
            updateLangUI();
        }
        function setLang(next) {
            if (!hasDict || (next !== 'zh' && next !== 'en')) return;
            lang = next;
            storageSet(LANG_KEY, next);
            apply();
            Download.refreshLabels();
            document.dispatchEvent(new CustomEvent('kit:langchange', { detail: { lang: lang } }));
        }
        function updateLangUI() {
            var wrap = document.querySelector('.kit-lang');
            if (!wrap) return;
            wrap.querySelectorAll('[data-kit-lang]').forEach(function (b) {
                b.setAttribute('aria-current', b.dataset.kitLang === lang ? 'true' : 'false');
            });
            var label = wrap.querySelector('.kit-lang-current');
            if (label) label.textContent = lang === 'zh' ? '简体中文' : 'English';
        }
        function bind() {
            if (!hasDict) return;
            lang = detect();
            apply();
            var wrap = document.querySelector('.kit-lang');
            if (wrap) {
                wrap.querySelectorAll('[data-kit-lang]').forEach(function (b) {
                    b.addEventListener('click', function () {
                        setLang(b.dataset.kitLang);
                        wrap.classList.remove('kit-open');
                        if (b.closest('.kit-lang-btn')) return;
                        var btn = wrap.querySelector('.kit-lang-btn');
                        if (btn) btn.setAttribute('aria-expanded', 'false');
                    });
                });
                var btn = wrap.querySelector('.kit-lang-btn');
                if (btn) {
                    btn.addEventListener('click', function (e) {
                        e.stopPropagation();
                        var open = wrap.classList.toggle('kit-open');
                        btn.setAttribute('aria-expanded', open ? 'true' : 'false');
                    });
                }
            }
            document.addEventListener('click', function (e) {
                if (wrap && !wrap.contains(e.target)) wrap.classList.remove('kit-open');
            });
            if (typeof navigator !== 'undefined' && 'languagechange' in window) {
                window.addEventListener('languagechange', function () {
                    if (!storageGet(LANG_KEY)) { lang = detect(); apply(); Download.refreshLabels(); }
                });
            }
        }
        return { bind: bind, setLang: setLang, t: t, get lang() { return lang; } };
    })();

    /* ================= 3. Download resolver ================= */
    /* Config (id="kit-download"):
         { "repo": "turlamai/<name>",
           "assets": { "mac": "<name>-{v}-macos-{arch}.dmg", ... },
           "archMap": { "linux": { "x64": "x86_64", "arm64": "aarch64" } } }
       Patterns may use {v} (version, no leading v) and {arch}.
       Policy: Windows UA always wins; unknown OS never defaults to mac —
       the CTA falls back to the Releases page instead of the wrong package. */
    var Download = (function () {
        var config = readJSON('kit-download');
        var resolved = { mac: null, win: null, linux: null };
        var arch = { mac: 'arm64', win: 'x64', linux: 'x64' };
        var os = null;
        var VER_RE = /^v?\d+\.\d+\.\d+$/;

        function detectOS(ua) {
            if (/Windows NT|Windows Phone|Windows CE/i.test(ua)) return 'win';
            if (/Macintosh|Mac OS X|MacPPC/i.test(ua)) return 'mac';
            if (/CrOS|X11|Linux(?!.*Android)/i.test(ua)) return 'linux';
            return null; // mobile or unknown: desktop packages do not apply
        }
        function detectLinuxArch(ua) {
            return /aarch64|arm64|armv8/i.test(ua) ? 'arm64' : 'x64';
        }
        function detectMacArch(ua) {
            if (/aarch64|arm64/i.test(ua)) return 'arm64';
            // WebGL renderer: Apple Silicon GPUs report Apple GPUs; Intel Macs do not.
            try {
                var canvas = document.createElement('canvas');
                var gl = canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
                if (gl) {
                    var ext = gl.getExtension('WEBGL_debug_renderer_info');
                    var renderer = ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : '';
                    if (/Apple\s?M|Apple GPU/i.test(renderer)) return 'arm64';
                    if (/Intel|AMD|NVIDIA/i.test(renderer)) return 'x64';
                }
            } catch (e) { /* headless or blocked */ }
            return null;
        }

        function assetName(platform, version) {
            var pattern = config.assets[platform];
            if (!pattern) return null;
            var a = arch[platform];
            if (config.archMap && config.archMap[platform] && config.archMap[platform][a]) {
                a = config.archMap[platform][a];
            }
            return pattern.replace('{v}', version).replace('{arch}', a);
        }

        function render() {
            var page = 'https://github.com/' + config.repo + '/releases/latest';
            var primary = document.querySelector('a[data-kit-dl-primary]');
            if (primary) primary.href = os ? (resolved[os] || page) : page;
            document.querySelectorAll('[data-kit-dl]').forEach(function (a) {
                var p = a.dataset.kitDl;
                a.href = resolved[p] || page;
            });
            var note = document.querySelector('[data-kit-dl-note]');
            if (note && !os) note.classList.remove('kit-hidden');
        }
        function renderLabels() {
            if (!config) return;
            var primary = document.querySelector('[data-kit-dl-primary] .kit-dl-label');
            if (primary) {
                primary.textContent = I18N.t(os ? 'dl.' + os : 'dl.generic');
            }
            document.querySelectorAll('.kit-dl-menu [data-kit-dl-os]').forEach(function (el) {
                var p = el.closest('[data-kit-dl]').dataset.kitDl;
                el.textContent = I18N.t('dl.' + p);
            });
        }

        function resolveFromRelease(data) {
            var tag = data && data.tag_name;
            if (!tag || data.draft || data.prerelease || !VER_RE.test(tag)) return false;
            var version = tag.replace(/^v/, '');
            var assets = data.assets || [];
            var any = false;
            ['mac', 'win', 'linux'].forEach(function (p) {
                if (!config.assets[p]) return;
                var name = assetName(p, version);
                var hit = assets.some(function (a) {
                    return a.name === name && a.size > 0;
                });
                if (hit) {
                    resolved[p] = 'https://github.com/' + config.repo +
                        '/releases/download/' + tag + '/' + name;
                    any = true;
                }
            });
            return any;
        }

        function bind() {
            if (!config) return;
            var ua = navigator.userAgent;
            os = detectOS(ua);
            if (os === 'linux') arch.linux = detectLinuxArch(ua);
            if (os === 'mac') { var m = detectMacArch(ua); if (m) arch.mac = m; }

            renderLabels();
            render();

            // High-entropy client hints refine the architecture (Chromium).
            if (navigator.userAgentData && navigator.userAgentData.getHighEntropyValues) {
                navigator.userAgentData.getHighEntropyValues(['architecture'])
                    .then(function (h) {
                        if (!h || !h.architecture) return;
                        var a = h.architecture === 'arm' ? 'arm64'
                            : (h.architecture === 'x86' ? 'x64' : null);
                        if (a && a !== arch[os]) { arch[os] = a; resolved = { mac: null, win: null, linux: null }; render(); fetchRelease(); }
                    })
                    .catch(function () { });
            }

            var caret = document.querySelector('.kit-dl-caret');
            var wrap = document.querySelector('.kit-dl');
            if (caret && wrap) {
                caret.addEventListener('click', function (e) {
                    e.stopPropagation();
                    var open = wrap.classList.toggle('kit-open');
                    caret.setAttribute('aria-expanded', open ? 'true' : 'false');
                });
                document.addEventListener('click', function (e) {
                    if (!wrap.contains(e.target)) {
                        wrap.classList.remove('kit-open');
                        caret.setAttribute('aria-expanded', 'false');
                    }
                });
                document.addEventListener('keydown', function (e) {
                    if (e.key === 'Escape') {
                        wrap.classList.remove('kit-open');
                        caret.setAttribute('aria-expanded', 'false');
                    }
                });
            }

            fetchRelease();
        }

        function fetchRelease() {
            if (!config) return;
            var ctrl = ('AbortController' in window) ? new AbortController() : null;
            var opts = { headers: { 'Accept': 'application/vnd.github+json' }, cache: 'no-store' };
            if (ctrl) {
                opts.signal = ctrl.signal;
                setTimeout(function () { ctrl.abort(); }, 5000);
            }
            fetch('https://api.github.com/repos/' + config.repo + '/releases/latest', opts)
                .then(function (r) { if (!r.ok) throw new Error('release lookup ' + r.status); return r.json(); })
                .then(function (data) {
                    if (resolveFromRelease(data)) render();
                    document.dispatchEvent(new CustomEvent('kit:download-resolved', {
                        detail: { os: os, arch: arch, resolved: resolved }
                    }));
                })
                .catch(function () { /* Releases page remains the safe fallback. */ });
        }

        return { bind: bind, refreshLabels: renderLabels };
    })();

    /* ================= Bootstrap ================= */
    function init() {
        Theme.bind();
        I18N.bind();
        Download.bind();
        docEl.dataset.kitReady = 'true';
    }
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    window.KIT = {
        Theme: Theme,
        I18N: I18N,
        Download: Download,
        t: I18N.t,
        setLang: I18N.setLang
    };
})();
