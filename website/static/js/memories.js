// Hero "how you met" rotator.
//
// Mirrors the Mantra Moment site's rotating-phrase demo: several memory
// cards are stacked in one grid cell (see .memory-stack in site.css) and this
// script cross-fades one in at a time. It pauses while the tab is hidden and
// stays put entirely when the visitor prefers reduced motion. The CSS reserves
// the height of the tallest card, so nothing shifts as cards swap.
(function () {
  "use strict";

  var INTERVAL_MS = 5000;

  var reduceMotion = window.matchMedia
    ? window.matchMedia("(prefers-reduced-motion: reduce)")
    : null;

  document.addEventListener("DOMContentLoaded", function () {
    var stack = document.querySelector("[data-memory-stack]");
    if (!stack) return;

    var cards = Array.prototype.slice.call(
      stack.querySelectorAll("[data-memory]")
    );
    if (cards.length < 2) return;

    var index = 0;
    var timer = null;

    function show(i) {
      for (var c = 0; c < cards.length; c++) {
        cards[c].classList.toggle("is-active", c === i);
      }
    }

    function advance() {
      index = (index + 1) % cards.length;
      show(index);
    }

    function start() {
      if (timer !== null) return;
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
