(() => {
  "use strict";

  const explainers = () => [...document.querySelectorAll(".motion-vote-explainer")];

  const updatePlacement = (explainer) => {
    const toggle = explainer.querySelector("[data-vote-explainer-toggle]");
    const popup = explainer.querySelector(".motion-vote-explainer__popup");
    if (!toggle || !popup) return;

    const toggleBounds = toggle.getBoundingClientRect();
    const popupHeight = popup.getBoundingClientRect().height;
    const spaceBelow = window.innerHeight - toggleBounds.bottom;
    const spaceAbove = toggleBounds.top;
    const opensUpward = popupHeight > spaceBelow && spaceAbove > spaceBelow;
    explainer.classList.toggle("motion-vote-explainer--opens-upward", opensUpward);
  };

  const close = (explainer) => {
    explainer.classList.remove("is-open");
    explainer.querySelector("[data-vote-explainer-toggle]")?.setAttribute("aria-expanded", "false");
  };

  const open = (explainer) => {
    explainers().forEach((item) => {
      if (item !== explainer) close(item);
    });
    explainer.classList.add("is-open");
    explainer.querySelector("[data-vote-explainer-toggle]")?.setAttribute("aria-expanded", "true");
    requestAnimationFrame(() => updatePlacement(explainer));
  };

  explainers().forEach((explainer) => {
    const toggle = explainer.querySelector("[data-vote-explainer-toggle]");
    if (!toggle) return;
    toggle.addEventListener("click", (event) => {
      event.preventDefault();
      if (explainer.classList.contains("is-open")) close(explainer);
      else open(explainer);
    });
    explainer.addEventListener("pointerenter", () => updatePlacement(explainer));
    explainer.addEventListener("focusin", () => updatePlacement(explainer));
  });

  document.addEventListener("pointerdown", (event) => {
    if (!event.target.closest(".motion-vote-explainer")) explainers().forEach(close);
  });

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    explainers().forEach(close);
  });

  window.addEventListener("resize", () => {
    explainers().forEach((explainer) => {
      if (explainer.matches(":hover, :focus-within") || explainer.classList.contains("is-open")) {
        updatePlacement(explainer);
      }
    });
  });
})();
