// inject-websocket.js
// Injected at document start to monkey-patch WebSocket and fetch for ASR + login detection.
(function() {
    'use strict';

    // --- Page Visibility API override ---
    // Prevent the page from knowing it's hidden so that media capture
    // (getUserMedia) and JS timers keep running normally in the background.
    Object.defineProperty(document, 'visibilityState', {
        get: function() { return 'visible'; },
        configurable: true
    });
    Object.defineProperty(document, 'hidden', {
        get: function() { return false; },
        configurable: true
    });
    // Suppress visibilitychange events so page logic never enters a "hidden" branch
    document.addEventListener('visibilitychange', function(e) {
        e.stopImmediatePropagation();
    }, true);

    // --- Fetch interception: detect profile API for login status ---
    const OriginalFetch = window.fetch;
    window.fetch = function() {
        const url = arguments[0];
        const urlStr = (typeof url === 'string') ? url : (url && url.url) || '';

        const promise = OriginalFetch.apply(this, arguments);

        if (urlStr.includes('/alice/profile/self')) {
            promise.then(function(response) {
                const cloned = response.clone();
                cloned.json().then(function(data) {
                    if (data && data.code === 0 && data.data && data.data.profile_brief) {
                        window.webkit.messageHandlers.asrHandler.postMessage({
                            type: 'login',
                            status: 'loggedIn',
                            nickname: data.data.profile_brief.nickname || ''
                        });
                    } else {
                        window.webkit.messageHandlers.asrHandler.postMessage({
                            type: 'login',
                            status: 'notLoggedIn'
                        });
                    }
                }).catch(function() {
                    window.webkit.messageHandlers.asrHandler.postMessage({
                        type: 'login',
                        status: 'notLoggedIn'
                    });
                });
            }).catch(function() {
                // Network error — can't determine login
            });
        }

        return promise;
    };

    // --- XHR interception: fallback for profile API ---
    const OriginalXHROpen = XMLHttpRequest.prototype.open;
    const OriginalXHRSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(method, url) {
        this.__doubaoMurmurUrl = url;
        return OriginalXHROpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function() {
        if (this.__doubaoMurmurUrl && this.__doubaoMurmurUrl.includes('/alice/profile/self')) {
            this.addEventListener('load', function() {
                try {
                    var data = JSON.parse(this.responseText);
                    if (data && data.code === 0 && data.data && data.data.profile_brief) {
                        window.webkit.messageHandlers.asrHandler.postMessage({
                            type: 'login',
                            status: 'loggedIn',
                            nickname: data.data.profile_brief.nickname || ''
                        });
                    }
                } catch(e) {}
            });
        }
        return OriginalXHRSend.apply(this, arguments);
    };

    // --- WebSocket interception: ASR messages ---
    const OriginalWebSocket = window.WebSocket;
    const ASR_URL_PATTERN = 'samantha/audio/asr';

    window.WebSocket = function(url, protocols) {
        console.log('[doubao-murmur] WebSocket constructor called:', typeof url === 'string' ? url.substring(0, 120) : url);
        const ws = protocols
            ? new OriginalWebSocket(url, protocols)
            : new OriginalWebSocket(url);

        if (typeof url === 'string' && url.includes(ASR_URL_PATTERN)) {
            console.log('[doubao-murmur] ASR WebSocket intercepted:', url);

            try {
                window.webkit.messageHandlers.asrHandler.postMessage({
                    type: 'debug',
                    text: 'ASR WebSocket intercepted: ' + url.substring(0, 120)
                });
            } catch(e) {}

            ws.addEventListener('message', function(event) {
                try {
                    const data = JSON.parse(event.data);
                    if (data.event === 'result' && data.result && data.result.Text) {
                        window.webkit.messageHandlers.asrHandler.postMessage({
                            type: 'result',
                            text: data.result.Text
                        });
                    } else if (data.event === 'finish') {
                        window.webkit.messageHandlers.asrHandler.postMessage({
                            type: 'finish'
                        });
                    }
                } catch (e) {
                    // Not JSON or parse error, ignore
                }
            });

            ws.addEventListener('close', function(event) {
                console.log('[doubao-murmur] ASR WebSocket closed:', event.code);
                window.webkit.messageHandlers.asrHandler.postMessage({
                    type: 'close',
                    code: event.code
                });
            });

            ws.addEventListener('error', function(event) {
                console.log('[doubao-murmur] ASR WebSocket error');
                window.webkit.messageHandlers.asrHandler.postMessage({
                    type: 'error'
                });
            });

            ws.addEventListener('open', function(event) {
                console.log('[doubao-murmur] ASR WebSocket opened');
                window.webkit.messageHandlers.asrHandler.postMessage({
                    type: 'open'
                });
            });
        }

        return ws;
    };

    // Preserve prototype chain
    window.WebSocket.prototype = OriginalWebSocket.prototype;
    window.WebSocket.CONNECTING = OriginalWebSocket.CONNECTING;
    window.WebSocket.OPEN = OriginalWebSocket.OPEN;
    window.WebSocket.CLOSING = OriginalWebSocket.CLOSING;
    window.WebSocket.CLOSED = OriginalWebSocket.CLOSED;
})();
