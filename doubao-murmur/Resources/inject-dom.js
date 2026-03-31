// inject-dom.js
// Injected at document end for DOM interaction helpers.
(function() {
    'use strict';

    window.__doubaoMurmur = {
        clickAsrButton: function() {
            var btn = document.querySelector('[data-testid="asr_btn"]');
            if (!btn) {
                // Fallback: try finding by aria-label or icon patterns
                btn = document.querySelector('[data-testid*="asr"]');
            }
            if (btn) {
                console.log('[doubao-murmur] Clicking ASR button:', btn.tagName, btn.className);
                // Use full mouse event sequence to properly trigger React event handlers
                var rect = btn.getBoundingClientRect();
                var cx = rect.left + rect.width / 2;
                var cy = rect.top + rect.height / 2;
                var eventOpts = {
                    bubbles: true,
                    cancelable: true,
                    view: window,
                    clientX: cx,
                    clientY: cy
                };
                btn.dispatchEvent(new PointerEvent('pointerdown', eventOpts));
                btn.dispatchEvent(new MouseEvent('mousedown', eventOpts));
                btn.dispatchEvent(new PointerEvent('pointerup', eventOpts));
                btn.dispatchEvent(new MouseEvent('mouseup', eventOpts));
                btn.dispatchEvent(new MouseEvent('click', eventOpts));
                return true;
            }
            console.warn('[doubao-murmur] ASR button not found. Available data-testid elements:',
                Array.from(document.querySelectorAll('[data-testid]')).map(function(el) {
                    return el.getAttribute('data-testid');
                }).join(', ')
            );
            return false;
        },

        getAsrButtonState: function() {
            var btn = document.querySelector('[data-testid="asr_btn"]');
            if (btn) {
                return btn.getAttribute('data-state') || 'unknown';
            }
            return 'not_found';
        },

        isLoginButtonPresent: function() {
            return !!document.querySelector('button[data-testid="to_login_button"]');
        },

        isAsrButtonPresent: function() {
            return !!document.querySelector('[data-testid="asr_btn"]');
        },

        // Click the break button that appears after ASR finishes
        // (when doubao tries to send text to LLM and the request is blocked/pending)
        clickBreakButton: function() {
            var btn = document.querySelector('[data-testid="chat_input_local_break_button"]');
            if (btn) {
                console.log('[doubao-murmur] Clicking break button to interrupt pending request');
                var rect = btn.getBoundingClientRect();
                var cx = rect.left + rect.width / 2;
                var cy = rect.top + rect.height / 2;
                var eventOpts = {
                    bubbles: true,
                    cancelable: true,
                    view: window,
                    clientX: cx,
                    clientY: cy
                };
                btn.dispatchEvent(new PointerEvent('pointerdown', eventOpts));
                btn.dispatchEvent(new MouseEvent('mousedown', eventOpts));
                btn.dispatchEvent(new PointerEvent('pointerup', eventOpts));
                btn.dispatchEvent(new MouseEvent('mouseup', eventOpts));
                btn.dispatchEvent(new MouseEvent('click', eventOpts));
                return true;
            }
            return false;
        }
    };
})();
