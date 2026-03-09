import Foundation
import WebKit

@MainActor
class PPSRStealthService {
    static let shared = PPSRStealthService()

    private var userAgentIndex: Int = 0
    private var viewportIndex: Int = 0
    private var sessionSeed: UInt32 = arc4random()

    private let userAgents: [String] = [
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPad; CPU OS 18_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_7_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.7 Mobile/15E148 Safari/604.1",
    ]

    private let viewportSizes: [(width: Int, height: Int)] = [
        (390, 844), (393, 852), (414, 896),
        (375, 812), (428, 926), (430, 932),
        (320, 568), (768, 1024), (810, 1080),
    ]

    private let languages: [String] = [
        "en-AU", "en-US", "en-GB", "en-NZ", "en-CA",
    ]

    struct SessionProfile {
        let userAgent: String
        let viewport: (width: Int, height: Int)
        let language: String
        let platform: String
        let cores: Int
        let memory: Int
        let tzOffset: Int
        let tzName: String
        let seed: UInt32
        let colorDepth: Int
        let pixelRatio: Double
        let maxTouchPoints: Int
        let isMobile: Bool
    }

    func nextProfile() -> SessionProfile {
        let ua = userAgents[userAgentIndex % userAgents.count]
        userAgentIndex += 1
        let vp = viewportSizes[viewportIndex % viewportSizes.count]
        viewportIndex += 1
        let lang = languages.randomElement() ?? "en-AU"
        let seed = arc4random()

        let isMobile = ua.contains("Mobile")
        let isIPad = ua.contains("iPad")
        let platform: String
        if ua.contains("Macintosh") {
            platform = "MacIntel"
        } else if isIPad {
            platform = "iPad"
        } else {
            platform = "iPhone"
        }

        let cores = isMobile ? [4, 6].randomElement()! : [4, 8, 10].randomElement()!
        let memory = isMobile ? [4, 6].randomElement()! : [8, 16].randomElement()!

        let tzOptions: [(offset: Int, name: String)] = [
            (-600, "Australia/Sydney"),
            (-660, "Pacific/Auckland"),
            (0, "Europe/London"),
            (-480, "Asia/Singapore"),
            (-570, "Australia/Adelaide"),
            (-600, "Australia/Melbourne"),
            (-600, "Australia/Brisbane"),
        ]
        let tz = tzOptions.randomElement()!

        let colorDepth = 32
        let pixelRatio = isMobile ? [2.0, 3.0].randomElement()! : [1.0, 2.0].randomElement()!
        let maxTouchPoints = isMobile ? 5 : 0

        return SessionProfile(
            userAgent: ua,
            viewport: vp,
            language: lang,
            platform: platform,
            cores: cores,
            memory: memory,
            tzOffset: tz.offset,
            tzName: tz.name,
            seed: seed,
            colorDepth: colorDepth,
            pixelRatio: pixelRatio,
            maxTouchPoints: maxTouchPoints,
            isMobile: isMobile
        )
    }

    func nextUserAgent() -> String {
        let ua = userAgents[userAgentIndex % userAgents.count]
        userAgentIndex += 1
        return ua
    }

    func nextViewport() -> (width: Int, height: Int) {
        let vp = viewportSizes[viewportIndex % viewportSizes.count]
        viewportIndex += 1
        return vp
    }

    func randomLanguage() -> String {
        languages.randomElement() ?? "en-AU"
    }

    func createStealthUserScript(profile: SessionProfile) -> WKUserScript {
        let js = buildComprehensiveStealthJS(profile: profile)
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    func fingerprintJS() -> String {
        let profile = nextProfile()
        return buildComprehensiveStealthJS(profile: profile)
    }

    func buildComprehensiveStealthJSPublic(profile: SessionProfile) -> String {
        buildComprehensiveStealthJS(profile: profile)
    }

    private func buildComprehensiveStealthJS(profile: SessionProfile) -> String {
        let p = profile
        return """
        (function() {
            'use strict';
            var seed = \(p.seed);
            function mulberry32(a) {
                return function() {
                    a |= 0; a = a + 0x6D2B79F5 | 0;
                    var t = Math.imul(a ^ a >>> 15, 1 | a);
                    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
                    return ((t ^ t >>> 14) >>> 0) / 4294967296;
                }
            }
            var prng = mulberry32(seed);

            function defineP(obj, prop, val) {
                try {
                    Object.defineProperty(obj, prop, {
                        get: function() { return val; },
                        configurable: true,
                        enumerable: true
                    });
                } catch(e) {}
            }

            // === NAVIGATOR SPOOFING ===
            defineP(navigator, 'webdriver', false);
            defineP(navigator, 'language', '\(p.language)');
            defineP(navigator, 'languages', Object.freeze(['\(p.language)', 'en']));
            defineP(navigator, 'platform', '\(p.platform)');
            defineP(navigator, 'hardwareConcurrency', \(p.cores));
            defineP(navigator, 'deviceMemory', \(p.memory));
            defineP(navigator, 'maxTouchPoints', \(p.maxTouchPoints));
            defineP(navigator, 'vendor', 'Apple Computer, Inc.');
            defineP(navigator, 'appVersion', navigator.userAgent.replace('Mozilla/', ''));
            defineP(navigator, 'productSub', '20030107');
            defineP(navigator, 'doNotTrack', null);

            // === CONNECTION API ===
            try {
                if (navigator.connection) {
                    defineP(navigator.connection, 'effectiveType', '\(p.isMobile ? "4g" : "4g")');
                    defineP(navigator.connection, 'downlink', \(p.isMobile ? [5.0, 10.0, 15.0, 20.0].randomElement()! : [50.0, 80.0, 100.0].randomElement()!));
                    defineP(navigator.connection, 'rtt', \(p.isMobile ? [50, 75, 100].randomElement()! : [20, 30, 50].randomElement()!));
                    defineP(navigator.connection, 'saveData', false);
                }
            } catch(e) {}

            // === PLUGINS & MIME TYPES (Safari-like) ===
            try {
                var fakePlugins = [];
                var fakeMimeTypes = [];
                defineP(navigator, 'plugins', Object.create(PluginArray.prototype, {
                    length: { get: function() { return fakePlugins.length; } },
                    item: { value: function(i) { return fakePlugins[i] || null; } },
                    namedItem: { value: function(n) { return null; } },
                    refresh: { value: function() {} }
                }));
                defineP(navigator, 'mimeTypes', Object.create(MimeTypeArray.prototype, {
                    length: { get: function() { return fakeMimeTypes.length; } },
                    item: { value: function(i) { return fakeMimeTypes[i] || null; } },
                    namedItem: { value: function(n) { return null; } }
                }));
            } catch(e) {}

            // === PERMISSIONS API SPOOF ===
            try {
                var origQuery = Permissions.prototype.query;
                Permissions.prototype.query = function(desc) {
                    if (desc && desc.name === 'notifications') {
                        return Promise.resolve({ state: 'prompt', onchange: null });
                    }
                    return origQuery.apply(this, arguments);
                };
            } catch(e) {}

            // === SCREEN & WINDOW ===
            try {
                defineP(screen, 'width', \(p.viewport.width));
                defineP(screen, 'height', \(p.viewport.height));
                defineP(screen, 'availWidth', \(p.viewport.width));
                defineP(screen, 'availHeight', \(p.viewport.height));
                defineP(screen, 'colorDepth', \(p.colorDepth));
                defineP(screen, 'pixelDepth', \(p.colorDepth));
            } catch(e) {}
            try {
                defineP(window, 'devicePixelRatio', \(p.pixelRatio));
                defineP(window, 'innerWidth', \(p.viewport.width));
                defineP(window, 'innerHeight', \(p.viewport.height));
                defineP(window, 'outerWidth', \(p.viewport.width));
                defineP(window, 'outerHeight', \(p.viewport.height));
            } catch(e) {}

            // === TIMEZONE SPOOFING ===
            try {
                var origDateTZO = Date.prototype.getTimezoneOffset;
                Date.prototype.getTimezoneOffset = function() { return \(p.tzOffset); };

                var origResolvedOptions = Intl.DateTimeFormat.prototype.resolvedOptions;
                Intl.DateTimeFormat.prototype.resolvedOptions = function() {
                    var result = origResolvedOptions.call(this);
                    result.timeZone = '\(p.tzName)';
                    return result;
                };
            } catch(e) {}

            // === CANVAS FINGERPRINT (SEEDED DETERMINISTIC NOISE) ===
            try {
                var origToDataURL = HTMLCanvasElement.prototype.toDataURL;
                var origToBlob = HTMLCanvasElement.prototype.toBlob;
                var origGetImageData = CanvasRenderingContext2D.prototype.getImageData;

                function addCanvasNoise(canvas) {
                    try {
                        var ctx = canvas.getContext('2d');
                        if (!ctx) return;
                        var w = Math.min(canvas.width, 16);
                        var h = Math.min(canvas.height, 16);
                        var imageData = CanvasRenderingContext2D.prototype.getImageData.call(ctx, 0, 0, w, h);
                        var data = imageData.data;
                        for (var i = 0; i < data.length; i += 4) {
                            var noise = ((prng() * 4) | 0) - 2;
                            data[i] = Math.max(0, Math.min(255, data[i] + noise));
                            data[i+1] = Math.max(0, Math.min(255, data[i+1] + noise));
                            data[i+2] = Math.max(0, Math.min(255, data[i+2] + noise));
                        }
                        ctx.putImageData(imageData, 0, 0);
                    } catch(e) {}
                }

                HTMLCanvasElement.prototype.toDataURL = function() {
                    addCanvasNoise(this);
                    return origToDataURL.apply(this, arguments);
                };

                HTMLCanvasElement.prototype.toBlob = function() {
                    addCanvasNoise(this);
                    return origToBlob.apply(this, arguments);
                };

                CanvasRenderingContext2D.prototype.getImageData = function(sx, sy, sw, sh) {
                    var imageData = origGetImageData.call(this, sx, sy, sw, sh);
                    var data = imageData.data;
                    for (var i = 0; i < Math.min(data.length, 256); i += 4) {
                        var n = ((prng() * 3) | 0) - 1;
                        data[i] = Math.max(0, Math.min(255, data[i] + n));
                    }
                    return imageData;
                };
            } catch(e) {}

            // === WEBGL DEEP SPOOFING ===
            try {
                var webglVendors = ['Apple Inc.'];
                var webglRenderers = ['Apple GPU'];
                var gpuVendor = webglVendors[0];
                var gpuRenderer = webglRenderers[0];

                function patchWebGLContext(proto) {
                    var origGetParameter = proto.getParameter;
                    var origGetExtension = proto.getExtension;
                    var origGetShaderPrecisionFormat = proto.getShaderPrecisionFormat;

                    proto.getParameter = function(param) {
                        if (param === 37445) return gpuVendor;
                        if (param === 37446) return gpuRenderer;
                        if (param === 7937) return 'WebGL 1.0 (OpenGL ES 2.0 Chromium)';
                        if (param === 7936) return 'WebKit';
                        if (param === 7938) return 'WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0 Chromium)';
                        if (param === 3379) return 16384;
                        if (param === 3386) {
                            var arr = new Float32Array(2);
                            arr[0] = 1; arr[1] = 1;
                            return arr;
                        }
                        if (param === 34076) return 16384;
                        if (param === 34024) return 16384;
                        if (param === 36349) return 1024;
                        if (param === 34921) return 16;
                        if (param === 36347) return 1024;
                        return origGetParameter.apply(this, arguments);
                    };

                    proto.getExtension = function(name) {
                        if (name === 'WEBGL_debug_renderer_info') {
                            return { UNMASKED_VENDOR_WEBGL: 37445, UNMASKED_RENDERER_WEBGL: 37446 };
                        }
                        return origGetExtension.apply(this, arguments);
                    };

                    proto.getShaderPrecisionFormat = function() {
                        var result = origGetShaderPrecisionFormat.apply(this, arguments);
                        if (result) {
                            return {
                                rangeMin: result.rangeMin || 127,
                                rangeMax: result.rangeMax || 127,
                                precision: result.precision || 23
                            };
                        }
                        return result;
                    };
                }

                if (typeof WebGLRenderingContext !== 'undefined') {
                    patchWebGLContext(WebGLRenderingContext.prototype);
                }
                if (typeof WebGL2RenderingContext !== 'undefined') {
                    patchWebGLContext(WebGL2RenderingContext.prototype);
                }
            } catch(e) {}

            // === AUDIO CONTEXT FINGERPRINT ===
            try {
                var origCreateOscillator = (window.OfflineAudioContext || window.webkitOfflineAudioContext || function(){}).prototype.createOscillator;
                var origStartRendering = (window.OfflineAudioContext || window.webkitOfflineAudioContext || function(){}).prototype.startRendering;

                if (window.OfflineAudioContext || window.webkitOfflineAudioContext) {
                    var AudioCtx = window.OfflineAudioContext || window.webkitOfflineAudioContext;
                    var origACProto = AudioCtx.prototype;
                    var origSR = origACProto.startRendering;

                    origACProto.startRendering = function() {
                        var self = this;
                        var origPromise = origSR.apply(this, arguments);
                        if (origPromise && origPromise.then) {
                            return origPromise.then(function(buffer) {
                                try {
                                    var channelData = buffer.getChannelData(0);
                                    for (var i = 0; i < Math.min(channelData.length, 1000); i++) {
                                        channelData[i] += (prng() - 0.5) * 0.0001;
                                    }
                                } catch(e) {}
                                return buffer;
                            });
                        }
                        return origPromise;
                    };
                }

                if (window.AudioContext || window.webkitAudioContext) {
                    var RealAC = window.AudioContext || window.webkitAudioContext;
                    var origCreateAnalyser = RealAC.prototype.createAnalyser;
                    RealAC.prototype.createAnalyser = function() {
                        var analyser = origCreateAnalyser.apply(this, arguments);
                        var origGetFloatFreq = analyser.getFloatFrequencyData;
                        var origGetByteFreq = analyser.getByteFrequencyData;
                        analyser.getFloatFrequencyData = function(arr) {
                            origGetFloatFreq.call(this, arr);
                            for (var i = 0; i < Math.min(arr.length, 128); i++) {
                                arr[i] += (prng() - 0.5) * 0.01;
                            }
                        };
                        analyser.getByteFrequencyData = function(arr) {
                            origGetByteFreq.call(this, arr);
                            for (var i = 0; i < Math.min(arr.length, 128); i++) {
                                arr[i] = Math.max(0, Math.min(255, arr[i] + ((prng() * 2) | 0) - 1));
                            }
                        };
                        return analyser;
                    };
                }
            } catch(e) {}

            // === WEBRTC LEAK PREVENTION ===
            try {
                var origRTC = window.RTCPeerConnection || window.webkitRTCPeerConnection || window.mozRTCPeerConnection;
                if (origRTC) {
                    var ProxiedRTC = function(config, constraints) {
                        if (config && config.iceServers) {
                            config.iceServers = config.iceServers.map(function(s) {
                                if (s.urls) {
                                    var urls = Array.isArray(s.urls) ? s.urls : [s.urls];
                                    s.urls = urls.filter(function(u) { return u.indexOf('stun:') !== 0; });
                                }
                                return s;
                            });
                        }
                        return new origRTC(config, constraints);
                    };
                    ProxiedRTC.prototype = origRTC.prototype;
                    ProxiedRTC.generateCertificate = origRTC.generateCertificate;
                    window.RTCPeerConnection = ProxiedRTC;
                    if (window.webkitRTCPeerConnection) window.webkitRTCPeerConnection = ProxiedRTC;
                }
            } catch(e) {}

            // === CLIENT RECTS NOISE ===
            try {
                var origGetBCR = Element.prototype.getBoundingClientRect;
                var origGetCR = Element.prototype.getClientRects;
                var noiseAmount = 0.00001 + prng() * 0.00005;

                Element.prototype.getBoundingClientRect = function() {
                    var rect = origGetBCR.apply(this, arguments);
                    var nr = (prng() - 0.5) * noiseAmount;
                    return new DOMRect(
                        rect.x + nr, rect.y + nr,
                        rect.width + nr, rect.height + nr
                    );
                };

                Element.prototype.getClientRects = function() {
                    var rects = origGetCR.apply(this, arguments);
                    var result = [];
                    for (var i = 0; i < rects.length; i++) {
                        var r = rects[i];
                        var nr2 = (prng() - 0.5) * noiseAmount;
                        result.push(new DOMRect(r.x + nr2, r.y + nr2, r.width + nr2, r.height + nr2));
                    }
                    return result;
                };
            } catch(e) {}

            // === HIGH-RES TIMER NOISE ===
            try {
                var origNow = Performance.prototype.now;
                Performance.prototype.now = function() {
                    var t = origNow.call(this);
                    return t + (prng() * 0.1);
                };
            } catch(e) {}

            // === BATTERY API ===
            try {
                if (navigator.getBattery) {
                    var fakeBattery = {
                        charging: true,
                        chargingTime: Infinity,
                        dischargingTime: Infinity,
                        level: 0.85 + prng() * 0.14,
                        addEventListener: function() {},
                        removeEventListener: function() {},
                        dispatchEvent: function() { return true; }
                    };
                    defineP(fakeBattery, 'onchargingchange', null);
                    defineP(fakeBattery, 'onchargingtimechange', null);
                    defineP(fakeBattery, 'ondischargingtimechange', null);
                    defineP(fakeBattery, 'onlevelchange', null);
                    navigator.getBattery = function() { return Promise.resolve(fakeBattery); };
                }
            } catch(e) {}

            // === MEDIA DEVICES ===
            try {
                if (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
                    var origEnum = navigator.mediaDevices.enumerateDevices.bind(navigator.mediaDevices);
                    navigator.mediaDevices.enumerateDevices = function() {
                        return origEnum().then(function(devices) {
                            return devices.map(function(d, idx) {
                                return {
                                    deviceId: d.deviceId || '',
                                    groupId: d.groupId || '',
                                    kind: d.kind,
                                    label: ''
                                };
                            });
                        });
                    };
                }
            } catch(e) {}

            // === SPEECH SYNTHESIS ===
            try {
                if (window.speechSynthesis) {
                    var origGetVoices = speechSynthesis.getVoices;
                    speechSynthesis.getVoices = function() {
                        var voices = origGetVoices.call(this);
                        if (voices.length === 0) return voices;
                        return voices.slice(0, Math.min(voices.length, 20 + ((prng() * 10) | 0)));
                    };
                }
            } catch(e) {}

            // === STORAGE ESTIMATION (prevent incognito detection) ===
            try {
                if (navigator.storage && navigator.storage.estimate) {
                    navigator.storage.estimate = function() {
                        return Promise.resolve({ quota: 2147483648, usage: 0, usageDetails: {} });
                    };
                }
            } catch(e) {}

            // === PROTECT OVERRIDES FROM toString() DETECTION ===
            try {
                var nativeToString = Function.prototype.toString;
                var spoofedFns = new Set();

                function markNative(fn, name) {
                    spoofedFns.add(fn);
                }

                Function.prototype.toString = function() {
                    if (spoofedFns.has(this)) {
                        return 'function ' + (this.name || '') + '() { [native code] }';
                    }
                    return nativeToString.call(this);
                };
                markNative(Function.prototype.toString, 'toString');

                markNative(HTMLCanvasElement.prototype.toDataURL, 'toDataURL');
                markNative(HTMLCanvasElement.prototype.toBlob, 'toBlob');
                markNative(CanvasRenderingContext2D.prototype.getImageData, 'getImageData');
                markNative(Element.prototype.getBoundingClientRect, 'getBoundingClientRect');
                markNative(Element.prototype.getClientRects, 'getClientRects');
                markNative(Performance.prototype.now, 'now');
                markNative(Date.prototype.getTimezoneOffset, 'getTimezoneOffset');
                if (window.RTCPeerConnection) markNative(window.RTCPeerConnection, 'RTCPeerConnection');
                if (navigator.getBattery) markNative(navigator.getBattery, 'getBattery');
                if (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
                    markNative(navigator.mediaDevices.enumerateDevices, 'enumerateDevices');
                }
            } catch(e) {}

            // === PREVENT AUTOMATION DETECTION FLAGS ===
            try {
                delete window.__nightmare;
                delete window._phantom;
                delete window.callPhantom;
                delete window.__selenium_evaluate;
                delete window.__selenium_unwrapped;
                delete window.__webdriver_evaluate;
                delete window.__driver_evaluate;
                delete window.__webdriver_unwrapped;
                delete window.__driver_unwrapped;
                delete window.__lastWatirAlert;
                delete window.__lastWatirConfirm;
                delete window.__lastWatirPrompt;
                delete window._Selenium_IDE_Recorder;
                delete window._WEBDRIVER_ELEM_CACHE;
                delete window.ChromeDriverw;
                delete document.__webdriver_script_fn;
                delete document.$chrome_asyncScriptInfo;
                delete document.$cdc_asdjflasutopfhvcZLmcfl_;
            } catch(e) {}

            try {
                if (window.chrome === undefined && navigator.userAgent.indexOf('Chrome') !== -1) {
                    window.chrome = { runtime: {}, loadTimes: function(){}, csi: function(){} };
                }
            } catch(e) {}

            // === IFRAME CONTENTWINDOW PROTECTION ===
            try {
                var origContentWindow = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'contentWindow');
                if (origContentWindow && origContentWindow.get) {
                    Object.defineProperty(HTMLIFrameElement.prototype, 'contentWindow', {
                        get: function() {
                            var w = origContentWindow.get.call(this);
                            if (w) {
                                try { defineP(w.navigator, 'webdriver', false); } catch(e) {}
                            }
                            return w;
                        }
                    });
                }
            } catch(e) {}

        })();
        """
    }
}
