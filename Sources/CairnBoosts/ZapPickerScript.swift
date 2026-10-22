import Foundation

/// JavaScript for Zap: the user hovers and clicks an element; the page script publishes a selector in `window.__cairnZap`.
public enum ZapPickerScript {
    /// Pure selector builder, `selectorBuilder(element, isUnique)`; emits only the `ZapSelector` grammar.
    public static let selectorBuilder = """
    function selectorBuilder(el, isUnique) {
        var safeId = /^[A-Za-z0-9_:.\\-]{1,100}$/, safeClass = /^[A-Za-z_][A-Za-z0-9_-]{0,100}$/;
        var parts = [];
        var node = el;
        while (node && node.nodeType === 1) {
            var tag = node.tagName.toLowerCase();
            if (!/^[a-z][a-z0-9-]*$/.test(tag)) { return null; }
            var part = tag;
            if (node.id && safeId.test(node.id)) {
                part = tag + '[id="' + node.id + '"]';
                parts.unshift(part);
                if (isUnique(parts.join(' > '))) { return parts.join(' > '); }
                node = node.parentElement;
                continue;
            }
            var cls = (node.classList ? Array.prototype.slice.call(node.classList) : []).filter(function (c) { return safeClass.test(c); }).slice(0, 2);
            if (cls.length) { part += '.' + cls.join('.'); }
            var parent = node.parentElement;
            if (parent) {
                var same = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === node.tagName; });
                if (same.length > 1) { part += ':nth-of-type(' + (same.indexOf(node) + 1) + ')'; }
            }
            parts.unshift(part);
            if (isUnique(parts.join(' > '))) { return parts.join(' > '); }
            if (tag === 'html') { break; }
            node = parent;
        }
        var full = parts.join(' > ');
        return full.length <= 512 ? full : null;
    }
    """

    /// Installs a hover outline and a one-shot click capture, then stores the selector in `window.__cairnZap`.
    public static let pickerSource = """
    (function () {
        "use strict";
        if (window.__cairnZapActive) { return; }
        window.__cairnZapActive = true;
        window.__cairnZap = null;
        \(selectorBuilder)
        var outlined = null, previous = "";
        function clear() { if (outlined) { outlined.style.outline = previous; outlined = null; } }
        function over(event) {
            clear();
            outlined = event.target; previous = outlined.style.outline;
            outlined.style.outline = "2px solid #ff3b30";
        }
        function finish(value) {
            clear();
            document.removeEventListener("mouseover", over, true);
            document.removeEventListener("click", click, true);
            document.removeEventListener("keydown", key, true);
            window.__cairnZapActive = false;
            window.__cairnZap = value;
        }
        function click(event) {
            event.preventDefault(); event.stopPropagation();
            var selector = selectorBuilder(event.target, function (s) {
                try { return document.querySelectorAll(s).length === 1; } catch (e) { return false; }
            });
            finish(selector || "");
        }
        function key(event) { if (event.key === "Escape") { finish(""); } }
        document.addEventListener("mouseover", over, true);
        document.addEventListener("click", click, true);
        document.addEventListener("keydown", key, true);
    })();
    """

    /// Reads and clears the published selector; evaluates to `null` while the picker is still waiting.
    public static let pollSource = "(function(){var v=window.__cairnZap;if(v===null||v===undefined){return null;}window.__cairnZap=null;return v;})()"
}
