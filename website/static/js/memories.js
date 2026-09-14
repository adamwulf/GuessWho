// Hero memory and screenshot rotator.
//
// Mirrors the Mantra Moment site's rotating-phrase demo: several memory
// cards and phone screenshots are stacked in grid cells and cross-fade in
// sync. The rotation pauses while the tab is hidden and stays put entirely
// when the visitor prefers reduced motion. CSS reserves the full dimensions,
// so nothing shifts as items swap.
(function () {
  "use strict";

  var INTERVAL_MS = 5000;

  var reduceMotion = window.matchMedia
    ? window.matchMedia("(prefers-reduced-motion: reduce)")
    : null;

  document.addEventListener("DOMContentLoaded", function () {
    var memoryStack = document.querySelector("[data-memory-stack]");
    var screenshotStack = document.querySelector("[data-hero-slideshow]");
    if (!memoryStack && !screenshotStack) return;

    var cards = memoryStack
      ? Array.prototype.slice.call(memoryStack.querySelectorAll("[data-memory]"))
      : [];
    var screenshots = screenshotStack
      ? Array.prototype.slice.call(screenshotStack.querySelectorAll("[data-hero-shot]"))
      : [];
    var itemCount = Math.max(cards.length, screenshots.length);
    if (itemCount < 2) return;

    var index = 0;
    var timer = null;

    function show(i) {
      for (var c = 0; c < cards.length; c++) {
        cards[c].classList.toggle("is-active", c === i % cards.length);
      }
      for (var s = 0; s < screenshots.length; s++) {
        var isActive = s === i % screenshots.length;
        screenshots[s].classList.toggle("is-active", isActive);
        screenshots[s].setAttribute("aria-hidden", isActive ? "false" : "true");
      }
    }

    function advance() {
      index = (index + 1) % itemCount;
      show(index);
    }

    function start() {
      if (timer !== null) return;
      if (document.hidden) return;
      if (reduceMotion && reduceMotion.matches) return;
      timer = window.setInterval(advance, INTERVAL_MS);
    }

    function stop() {
      if (timer === null) return;
      window.clearInterval(timer);
      timer = null;
    }

    show(0);
    start();

    // Pause when the tab is not visible; resume when it returns.
    document.addEventListener("visibilitychange", function () {
      if (document.hidden) {
        stop();
      } else {
        start();
      }
    });

    // Respond live if the visitor toggles the reduced-motion setting.
    if (reduceMotion) {
      var onChange = function () {
        if (reduceMotion.matches) {
          stop();
          show(0);
          index = 0;
        } else {
          start();
        }
      };
      if (reduceMotion.addEventListener) {
        reduceMotion.addEventListener("change", onChange);
      } else if (reduceMotion.addListener) {
        reduceMotion.addListener(onChange);
      }
    }
  });
})();
