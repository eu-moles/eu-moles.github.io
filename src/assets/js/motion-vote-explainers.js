(() => {
  "use strict";

  const explainers = () => [...document.querySelectorAll(".motion-vote-explainer")];

  const syncScrollLock = () => {
    const isOpen = explainers().some((item) => item.classList.contains("is-open"));
    document.documentElement.classList.toggle("motion-vote-explainer-open", isOpen);
    document.body.classList.toggle("motion-vote-explainer-open", isOpen);
  };

  const close = (explainer) => {
    explainer.classList.remove("is-open");
    explainer.querySelector("[data-vote-explainer-toggle]")?.setAttribute("aria-expanded", "false");
    syncScrollLock();
  };

  const open = (explainer) => {
    explainers().forEach((item) => {
      if (item !== explainer) close(item);
    });
    explainer.classList.add("is-open");
    explainer.querySelector("[data-vote-explainer-toggle]")?.setAttribute("aria-expanded", "true");
    syncScrollLock();
  };

  document.addEventListener("click", (event) => {
    const toggle = event.target.closest("[data-vote-explainer-toggle]");
    if (toggle) {
      event.preventDefault();
      const explainer = toggle.closest(".motion-vote-explainer");
      if (!explainer) return;
      if (explainer.classList.contains("is-open")) close(explainer);
      else open(explainer);
      return;
    }

    const closeButton = event.target.closest("[data-vote-explainer-close]");
    if (closeButton) {
      event.preventDefault();
      const explainer = closeButton.closest(".motion-vote-explainer");
      if (explainer) close(explainer);
    }
  });

  document.addEventListener("pointerdown", (event) => {
    if (!event.target.closest(".motion-vote-explainer")) explainers().forEach(close);
  });

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    explainers().forEach(close);
  });

  window.addEventListener("resize", syncScrollLock);
})();
